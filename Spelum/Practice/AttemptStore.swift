import AVFoundation
import Foundation
import SwiftData

@MainActor
protocol AudioFileInspecting {
    func playableDuration(at url: URL) -> TimeInterval?
}

@MainActor
struct AVAudioFileInspector: AudioFileInspecting {
    func playableDuration(at url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            return nil
        }
        guard let player = try? AVAudioPlayer(contentsOf: url),
              player.duration.isFinite,
              player.duration > 0 else {
            return nil
        }
        return player.duration
    }
}

@MainActor
final class AttemptStore {
    static let takesSubdirectoryName = "Takes"
    static let pendingSavesSubdirectoryName = "PendingSaves"

    let modelContext: ModelContext
    let storageRootURL: URL
    private let audioInspector: any AudioFileInspecting
    private let saveContext: (ModelContext) throws -> Void

    init(
        modelContext: ModelContext,
        storageRootURL: URL? = nil,
        audioInspector: (any AudioFileInspecting)? = nil,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.storageRootURL = storageRootURL ?? Self.defaultStorageRootURL()
        self.audioInspector = audioInspector ?? AVAudioFileInspector()
        self.saveContext = saveContext
    }

    static func defaultStorageRootURL() -> URL {
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appendingPathComponent("Spelum", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("Spelum", isDirectory: true)
    }

    static func opaqueRelativeAudioPath(for attemptID: UUID, fileExtension: String = "m4a") -> String {
        let cleanedExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let ext = cleanedExt.isEmpty ? "m4a" : cleanedExt.lowercased()
        return "\(takesSubdirectoryName)/\(attemptID.uuidString.lowercased()).\(ext)"
    }

    // MARK: - Path Management

    @discardableResult
    func prepareTakesDirectory() throws -> URL {
        let takesDir = storageRootURL.appendingPathComponent(Self.takesSubdirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: takesDir, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = takesDir
        try? mutableURL.setResourceValues(resourceValues)
        return takesDir
    }

    func resolvedAudioURL(for relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            throw AttemptStoreError.invalidRelativeAudioPath
        }
        let components = trimmed.split(separator: "/")
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw AttemptStoreError.invalidRelativeAudioPath
        }

        let rootStandardized = storageRootURL.standardizedFileURL
        let resolved = rootStandardized.appendingPathComponent(trimmed).standardizedFileURL
        let rootPrefix = rootStandardized.path.hasSuffix("/")
            ? rootStandardized.path
            : rootStandardized.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw AttemptStoreError.invalidRelativeAudioPath
        }
        return resolved
    }

    func resolvedAudioURL(for attempt: AttemptRecord) -> URL? {
        guard let relativePath = attempt.relativeAudioPath else { return nil }
        return try? resolvedAudioURL(for: relativePath)
    }

    func playableDuration(forRelativePath relativePath: String?) -> TimeInterval? {
        guard let relativePath, let url = try? resolvedAudioURL(for: relativePath) else {
            return nil
        }
        return audioInspector.playableDuration(at: url)
    }

    // MARK: - Atomic Transactions

    func performAtomicWrite<Result>(_ body: () throws -> Result) throws -> Result {
        let previousAutosave = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosave }

        do {
            let result = try body()
            try saveContext(modelContext)
            return result
        } catch {
            modelContext.processPendingChanges()
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Queries

    func attempt(withID id: UUID) throws -> AttemptRecord? {
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { record in
                record.id == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    func fetchAttempts(
        forSectionID sectionID: UUID,
        in presentationID: UUID,
        includeInProgress: Bool = false
    ) throws -> [AttemptRecord] {
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { record in
                record.presentationID == presentationID && record.sectionID == sectionID
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let fetched = try modelContext.fetch(descriptor)
        return includeInProgress ? fetched : fetched.filter { $0.status.isFinalized }
    }

    func fetchAttempts(
        forPresentationID presentationID: UUID,
        includeInProgress: Bool = false
    ) throws -> [AttemptRecord] {
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { record in
                record.presentationID == presentationID
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let fetched = try modelContext.fetch(descriptor)
        return includeInProgress ? fetched : fetched.filter { $0.status.isFinalized }
    }

    func fetchInProgressAttempts() throws -> [AttemptRecord] {
        let inProgressRaw = AttemptStatus.inProgress.rawValue
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { record in
                record.statusRawValue == inProgressRaw
            },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }
}

extension AttemptStore {
    // MARK: - Attempt Lifecycle

    @discardableResult
    func beginAttempt(
        snapshot: AttemptSnapshotReference,
        practiceMode: PracticeMode,
        isSilentRecall: Bool,
        startedAt: Date = Date(),
        attemptID: UUID = UUID()
    ) throws -> AttemptRecord {
        let relativePath: String?
        if isSilentRecall {
            relativePath = nil
        } else {
            try prepareTakesDirectory()
            relativePath = Self.opaqueRelativeAudioPath(for: attemptID)
        }

        return try performAtomicWrite {
            let record = AttemptRecord(
                id: attemptID,
                snapshot: snapshot,
                startedAt: startedAt,
                practiceMode: practiceMode,
                status: .inProgress,
                relativeAudioPath: relativePath,
                isSilentRecall: isSilentRecall
            )
            modelContext.insert(record)
            return record
        }
    }

    @discardableResult
    func finalizeAttempt(_ input: AttemptFinalizationInput) throws -> AttemptRecord {
        let outcome = evaluateFinalizationOutcome(for: input)

        do {
            let record = try performAtomicWrite {
                let target: AttemptRecord
                if let existing = try attempt(withID: input.id) {
                    target = existing
                    apply(input: input, outcome: outcome, to: target)
                } else {
                    target = AttemptRecord(
                        id: input.id,
                        snapshot: input.snapshot,
                        startedAt: input.startedAt,
                        finishedAt: input.finishedAt,
                        practiceMode: input.practiceMode,
                        status: outcome.status,
                        relativeAudioPath: outcome.finalAudioPath,
                        playableDuration: outcome.playableDuration,
                        elapsedDuration: max(input.elapsedDuration, outcome.playableDuration),
                        revealCount: input.revealCount,
                        markers: input.markers,
                        interruptionReason: outcome.interruptionReason,
                        isSilentRecall: input.isSilentRecall
                    )
                    modelContext.insert(target)
                }
                return target
            }

            removePendingSaveManifest(for: input.id)
            if outcome.finalAudioPath == nil, let unplayablePath = input.relativeAudioPath {
                removeAudioFileIfUnreferenced(relativePath: unplayablePath)
            }
            return record
        } catch {
            let manifest = PendingSaveManifest(
                attemptID: input.id,
                snapshot: input.snapshot,
                practiceMode: input.practiceMode,
                startedAt: input.startedAt,
                finishedAt: input.finishedAt,
                relativeAudioPath: input.relativeAudioPath,
                elapsedDuration: input.elapsedDuration,
                revealCount: input.revealCount,
                markers: input.markers,
                isSilentRecall: input.isSilentRecall,
                interrupted: input.interrupted,
                interruptionReason: input.interruptionReason
            )
            writePendingSaveManifest(manifest)
            throw error
        }
    }

    // MARK: - Deletion Safety

    func deleteAttempt(id: UUID) throws {
        guard let target = try attempt(withID: id) else {
            removePendingSaveManifest(for: id)
            return
        }
        try deleteAttempt(target)
    }

    func deleteAttempt(_ attempt: AttemptRecord) throws {
        let attemptID = attempt.id
        let relativePath = attempt.relativeAudioPath

        try performAtomicWrite {
            modelContext.delete(attempt)
        }

        removePendingSaveManifest(for: attemptID)
        if let relativePath {
            removeAudioFileIfUnreferenced(relativePath: relativePath)
        }
    }

    func deletePresentationAndAttempts(_ presentation: PresentationRecord) throws {
        let presentationID = presentation.id
        let attempts = try fetchAttempts(forPresentationID: presentationID, includeInProgress: true)
        let cleanupTargets: [(UUID, String?)] = attempts.map { ($0.id, $0.relativeAudioPath) }

        try performAtomicWrite {
            for attempt in attempts {
                modelContext.delete(attempt)
            }
            modelContext.delete(presentation)
        }

        for (attemptID, relativePath) in cleanupTargets {
            removePendingSaveManifest(for: attemptID)
            if let relativePath {
                removeAudioFileIfUnreferenced(relativePath: relativePath)
            }
        }
    }

    func discardUnpersistedAudio(for attemptID: UUID, relativeAudioPath: String?) {
        removePendingSaveManifest(for: attemptID)
        if let existing = try? attempt(withID: attemptID), !existing.status.isFinalized {
            try? deleteAttempt(existing)
            return
        }
        if let relativeAudioPath {
            removeAudioFileIfUnreferenced(relativePath: relativeAudioPath)
        }
    }
}

private extension AttemptStore {
    struct FinalizationOutcome {
        let status: AttemptStatus
        let finalAudioPath: String?
        let playableDuration: TimeInterval
        let interruptionReason: String?
    }

    func evaluateFinalizationOutcome(for input: AttemptFinalizationInput) -> FinalizationOutcome {
        if input.isSilentRecall {
            let status: AttemptStatus = input.interrupted ? .interrupted : .silentCompleted
            return FinalizationOutcome(
                status: status,
                finalAudioPath: nil,
                playableDuration: 0,
                interruptionReason: input.interrupted ? input.interruptionReason : nil
            )
        }

        if let relativePath = input.relativeAudioPath,
           let duration = playableDuration(forRelativePath: relativePath) {
            let status: AttemptStatus = input.interrupted ? .interrupted : .ready
            return FinalizationOutcome(
                status: status,
                finalAudioPath: relativePath,
                playableDuration: duration,
                interruptionReason: input.interrupted ? input.interruptionReason : nil
            )
        }

        let fallbackReason = input.interruptionReason ?? "No playable audio was captured."
        return FinalizationOutcome(
            status: .interrupted,
            finalAudioPath: nil,
            playableDuration: 0,
            interruptionReason: fallbackReason
        )
    }

    func apply(
        input: AttemptFinalizationInput,
        outcome: FinalizationOutcome,
        to record: AttemptRecord
    ) {
        record.presentationID = input.snapshot.presentationID
        record.talkRevisionID = input.snapshot.talkRevisionID
        record.talkRevisionNumber = input.snapshot.talkRevisionNumber
        record.sectionID = input.snapshot.sectionID
        record.sectionRevisionID = input.snapshot.sectionRevisionID
        record.sectionTitleSnapshot = input.snapshot.sectionTitle
        record.startedAt = input.startedAt
        record.finishedAt = input.finishedAt
        record.practiceModeRawValue = input.practiceMode.rawValue
        record.statusRawValue = outcome.status.rawValue
        record.relativeAudioPath = outcome.finalAudioPath
        record.playableDuration = outcome.playableDuration
        record.elapsedDuration = max(input.elapsedDuration, outcome.playableDuration)
        record.revealCount = input.revealCount
        record.updateMarkers(input.markers)
        record.interruptionReason = outcome.interruptionReason
        record.isSilentRecall = input.isSilentRecall
    }
}
