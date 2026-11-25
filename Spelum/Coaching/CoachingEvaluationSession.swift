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

nonisolated struct CoachingTaskEvaluationSummary: Equatable, Sendable {
    static let requiredCaseCount = 20
    static let qualificationUsefulThreshold = 16

    let task: CoachingTaskKind
    let totalCases: Int
    let ratedCases: Int
    let authoredUsefulCount: Int
    let modelUsefulCount: Int
    let modelFallbackCount: Int
    let modelInventedMeasurementCount: Int
    let modelAlteredQuoteCount: Int
    let modelUnsupportedSpeakerCount: Int
    let modelPreferredCount: Int
    let authoredPreferredCount: Int
    let tieCount: Int
    let neitherCount: Int
    let coldLatencyMilliseconds: Double?
    let warmMedianLatencyMilliseconds: Double?
    let warmMinLatencyMilliseconds: Double?
    let warmMaxLatencyMilliseconds: Double?
    let meanRepeatSimilarity: Double?
    let meanRepeatTechniqueAgreement: Double?
    let isSimulator: Bool

    var totalModelSafetyViolations: Int {
        modelInventedMeasurementCount + modelAlteredQuoteCount + modelUnsupportedSpeakerCount
    }

    var offersPracticalBenefit: Bool {
        modelPreferredCount > authoredPreferredCount
    }

    var isQualifiedForShipping: Bool {
        !isSimulator &&
            totalCases >= Self.requiredCaseCount &&
            ratedCases == totalCases &&
            modelUsefulCount >= Self.qualificationUsefulThreshold &&
            totalModelSafetyViolations == 0 &&
            offersPracticalBenefit
    }

    var decisionHeadline: String {
        if isQualifiedForShipping {
            return "Qualified for On-Device Generation (Physical Device Verified)"
        }
        if isSimulator {
            return "Keep Authored Baseline (Simulator Cannot Qualify Model)"
        }
        if ratedCases < totalCases {
            return "Keep Authored Baseline (\(ratedCases)/\(totalCases) Cases Rated)"
        }
        if totalModelSafetyViolations > 0 {
            return "Keep Authored Baseline (\(totalModelSafetyViolations) Safety Violation(s))"
        }
        if modelUsefulCount < Self.qualificationUsefulThreshold {
            return "Keep Authored Baseline (\(modelUsefulCount)/\(totalCases) Useful; Need 16+)"
        }
        return "Keep Authored Baseline (No Practical Benefit Over Authored)"
    }
}

nonisolated struct CoachingEvaluationSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let task: CoachingTaskKind
    let datasetVersion: String
    let promptVersion: String
    let createdAt: Date
    var updatedAt: Date
    var environment: CoachingDeviceEnvironment
    let modelAvailability: CoachingModelAvailability
    var isUnblinded: Bool
    let coldLatencyMilliseconds: Double?
    let warmLatenciesMilliseconds: [Double]
    let repeatVariationResults: [RepeatVariationResult]
    var entries: [BlindedEvaluationEntry]

    func summary() -> CoachingTaskEvaluationSummary {
        var tally = EvaluationTally()
        for entry in entries {
            tally.record(entry)
        }

        let sortedWarm = warmLatenciesMilliseconds.sorted()
        let warmMedian: Double? = sortedWarm.isEmpty ? nil : sortedWarm[sortedWarm.count / 2]
        let meanRepeatSim: Double? = repeatVariationResults.isEmpty
            ? nil
            : repeatVariationResults.map(\.meanTokenOverlapSimilarity).reduce(0, +)
                / Double(repeatVariationResults.count)
        let meanRepeatTech: Double? = repeatVariationResults.isEmpty
            ? nil
            : repeatVariationResults.map(\.techniqueAgreementRate).reduce(0, +)
                / Double(repeatVariationResults.count)

        return CoachingTaskEvaluationSummary(
            task: task,
            totalCases: entries.count,
            ratedCases: tally.rated,
            authoredUsefulCount: tally.authoredUseful,
            modelUsefulCount: tally.modelUseful,
            modelFallbackCount: tally.modelFallbacks,
            modelInventedMeasurementCount: tally.inventedMeasurements,
            modelAlteredQuoteCount: tally.alteredQuotes,
            modelUnsupportedSpeakerCount: tally.unsupportedSpeakers,
            modelPreferredCount: tally.modelPreferred,
            authoredPreferredCount: tally.authoredPreferred,
            tieCount: tally.ties,
            neitherCount: tally.neithers,
            coldLatencyMilliseconds: coldLatencyMilliseconds,
            warmMedianLatencyMilliseconds: warmMedian,
            warmMinLatencyMilliseconds: sortedWarm.first,
            warmMaxLatencyMilliseconds: sortedWarm.last,
            meanRepeatSimilarity: meanRepeatSim,
            meanRepeatTechniqueAgreement: meanRepeatTech,
            isSimulator: environment.isSimulator
        )
    }

    func markdownReport() -> String {
        let stats = summary()
        let coldText = stats.coldLatencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "N/A"
        let warmMedText = stats.warmMedianLatencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "N/A"
        let repeatSimText = stats.meanRepeatSimilarity.map { String(format: "%.0f%%", $0 * 100) } ?? "N/A"
        let repeatTechText = stats.meanRepeatTechniqueAgreement.map { String(format: "%.0f%%", $0 * 100) } ?? "N/A"
        let deviceKind = environment.isSimulator ? "Simulator" : "Physical Device"
        let safetyLine = "\(stats.totalModelSafetyViolations) " +
            "(invented=\(stats.modelInventedMeasurementCount), " +
            "alteredQuote=\(stats.modelAlteredQuoteCount), " +
            "speaker=\(stats.modelUnsupportedSpeakerCount))"
        return """
        # Spelum Blinded Coach Evaluation — \(task.displayName)
        - Decision: \(stats.decisionHeadline)
        - Environment: \(environment.osDescription) (\(environment.deviceModel), \(deviceKind))
        - On-Device Model Availability: \(modelAvailability.shortStatusLabel)
        - Dataset: \(datasetVersion) | Prompt: \(promptVersion)
        - Rated: \(stats.ratedCases)/\(stats.totalCases)
        - Useful: On-Device \(stats.modelUsefulCount)/\(stats.totalCases) vs Authored \(stats.authoredUsefulCount)/\(stats.totalCases)
        - Preferences: On-Device \(stats.modelPreferredCount) | Authored \(stats.authoredPreferredCount) | Tie \(stats.tieCount) | Neither \(stats.neitherCount)
        - Safety Violations (On-Device): \(safetyLine)
        - Model Fallbacks to Authored: \(stats.modelFallbackCount)/\(stats.totalCases)
        - Latency: Cold \(coldText) | Warm Median \(warmMedText)
        - Repeated Variation: Technique Agreement \(repeatTechText) | Mean Token Similarity \(repeatSimText)
        """
    }
}

private nonisolated struct EvaluationTally {
    var rated = 0
    var authoredUseful = 0
    var modelUseful = 0
    var modelFallbacks = 0
    var inventedMeasurements = 0
    var alteredQuotes = 0
    var unsupportedSpeakers = 0
    var modelPreferred = 0
    var authoredPreferred = 0
    var ties = 0
    var neithers = 0

    mutating func record(_ entry: BlindedEvaluationEntry) {
        if entry.modelFellBackToAuthored {
            modelFallbacks += 1
        }
        guard let rating = entry.rating else { return }
        rated += 1
        let modelIsA = entry.optionASource == .onDeviceModel
        if modelIsA ? rating.optionAUseful : rating.optionBUseful { modelUseful += 1 }
        if modelIsA ? rating.optionBUseful : rating.optionAUseful { authoredUseful += 1 }
        recordSafetyIssues(modelIsA ? rating.optionASafetyIssues : rating.optionBSafetyIssues)
        recordPreference(rating.preference, modelIsA: modelIsA)
    }

    private mutating func recordSafetyIssues(_ issues: Set<EvaluationSafetyIssue>) {
        if issues.contains(.inventedMeasurement) { inventedMeasurements += 1 }
        if issues.contains(.alteredQuote) { alteredQuotes += 1 }
        if issues.contains(.unsupportedSpeakerJudgment) { unsupportedSpeakers += 1 }
    }

    private mutating func recordPreference(_ preference: BlindedPreference, modelIsA: Bool) {
        switch preference {
        case .optionA:
            if modelIsA { modelPreferred += 1 } else { authoredPreferred += 1 }
        case .optionB:
            if modelIsA { authoredPreferred += 1 } else { modelPreferred += 1 }
        case .tie:
            ties += 1
        case .neither:
            neithers += 1
        }
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

    func clear(for task: CoachingTaskKind) {
        let dir = rootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        let fileURL = dir.appendingPathComponent("\(task.rawValue)-latest.json")
        try? FileManager.default.removeItem(at: fileURL)
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
