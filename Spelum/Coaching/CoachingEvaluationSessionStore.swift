import Foundation
import UIKit

nonisolated struct CoachingDeviceEnvironment: Codable, Equatable, Hashable, Sendable {
    let osDescription: String
    let deviceModel: String
    let isSimulator: Bool

    @MainActor
    static func current() -> CoachingDeviceEnvironment {
        let device = UIDevice.current
        #if targetEnvironment(simulator)
        let isSim = true
        #else
        let isSim = false
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return CoachingDeviceEnvironment(
            osDescription: "\(device.systemName) \(device.systemVersion)",
            deviceModel: machine,
            isSimulator: isSim
        )
    }
}

nonisolated enum DeterministicUUID {
    static func fromString(_ input: String) -> UUID {
        let hex = CoachingFingerprint.sha256Hex(input)
        let bytes = Array(hex.prefix(32))
        let formatted = [
            String(bytes[0..<8]),
            String(bytes[8..<12]),
            "4" + String(bytes[13..<16]),
            "8" + String(bytes[17..<20]),
            String(bytes[20..<32])
        ].joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}

nonisolated struct SeededRandomGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var zValue = state
        zValue = (zValue ^ (zValue >> 30)) &* 0xBF58_476D_1CE4_E5B9
        zValue = (zValue ^ (zValue >> 27)) &* 0x94D0_49BB_1331_11EB
        return zValue ^ (zValue >> 31)
    }
}

nonisolated enum CoachingEvaluationRepeatMetrics {
    static func summarize(
        id: String,
        caseTitle: String,
        suggestions: [CoachingSuggestion],
        latencies: [Double]
    ) -> RepeatVariationResult {
        let successful = suggestions.filter { $0.origin == .onDeviceModel }
        let fallbackCount = suggestions.count - successful.count
        let normalizedActions = successful.map {
            $0.displayedAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let uniqueActions = Set(normalizedActions).count

        guard successful.count >= 2 else {
            return RepeatVariationResult(
                id: id,
                caseTitle: caseTitle,
                trialCount: suggestions.count,
                successfulTrialCount: successful.count,
                uniqueActionCount: uniqueActions,
                techniqueAgreementRate: nil,
                meanTokenOverlapSimilarity: nil,
                trialLatenciesMilliseconds: latencies,
                fallbackCount: fallbackCount
            )
        }

        let techKeys = successful.map { $0.isAbstention ? "abstain" : ($0.techniqueID ?? "none") }
        let dominantCount = Dictionary(grouping: techKeys, by: { $0 }).values.map(\.count).max() ?? 0
        let agreementRate = Double(dominantCount) / Double(successful.count)

        var pairwiseSimilarities: [Double] = []
        for idxA in 0..<successful.count {
            for idxB in (idxA + 1)..<successful.count {
                pairwiseSimilarities.append(
                    tokenJaccardSimilarity(
                        successful[idxA].displayedAction,
                        successful[idxB].displayedAction
                    )
                )
            }
        }
        let meanSimilarity = pairwiseSimilarities.reduce(0, +) / Double(pairwiseSimilarities.count)

        return RepeatVariationResult(
            id: id,
            caseTitle: caseTitle,
            trialCount: suggestions.count,
            successfulTrialCount: successful.count,
            uniqueActionCount: uniqueActions,
            techniqueAgreementRate: agreementRate,
            meanTokenOverlapSimilarity: meanSimilarity,
            trialLatenciesMilliseconds: latencies,
            fallbackCount: fallbackCount
        )
    }

    static func tokenJaccardSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = normalizedTokens(lhs)
        let rhsTokens = normalizedTokens(rhs)
        if lhsTokens.isEmpty && rhsTokens.isEmpty {
            return 1.0
        }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    private static func normalizedTokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let cleaned = lowered.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : Character(" ")
        }
        return Set(String(cleaned).split(separator: " ").map(String.init))
    }
}

actor CoachingEvaluationProcessState {
    static let shared = CoachingEvaluationProcessState()

    private var hasExecutedOnDeviceInference = false

    func consumeFreshLaunchIfAvailable(modelAvailable: Bool) -> Bool {
        guard modelAvailable else { return false }
        if hasExecutedOnDeviceInference {
            return false
        }
        hasExecutedOnDeviceInference = true
        return true
    }

    func resetForTesting() {
        hasExecutedOnDeviceInference = false
    }
}

@MainActor
final class CoachingEvaluationSessionStore {
    static let directoryName = "CoachingEvaluations"

    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? AttemptStore.defaultStorageRootURL()
    }

    func save(_ session: CoachingEvaluationSession) throws {
        let dir = try prepareDirectory()
        let fileURL = dir.appendingPathComponent("\(session.task.rawValue)-latest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    func loadLatest(for task: CoachingTaskKind) -> CoachingEvaluationSession? {
        let dir = rootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        let fileURL = dir.appendingPathComponent("\(task.rawValue)-latest.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CoachingEvaluationSession.self, from: data)
    }

    func clear(for task: CoachingTaskKind) throws {
        let dir = rootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        let fileURL = dir.appendingPathComponent("\(task.rawValue)-latest.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func prepareDirectory() throws -> URL {
        let dir = rootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = dir
        try? mutableURL.setResourceValues(values)
        return dir
    }
}
