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
    private let fetchAudioPathReferences: (ModelContext, String) throws -> [AttemptRecord]
    private let removeFileItem: (URL) throws -> Void

    init(
        modelContext: ModelContext,
        storageRootURL: URL? = nil,
        audioInspector: (any AudioFileInspecting)? = nil,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        fetchAudioPathReferences: ((ModelContext, String) throws -> [AttemptRecord])? = nil,
        removeFileItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.modelContext = modelContext
        self.storageRootURL = storageRootURL ?? Self.defaultStorageRootURL()
        self.audioInspector = audioInspector ?? AVAudioFileInspector()
        self.saveContext = saveContext
        self.fetchAudioPathReferences = fetchAudioPathReferences ?? Self.defaultFetchAudioPathReferences
        self.removeFileItem = removeFileItem
    }

    private static func defaultFetchAudioPathReferences(
        in context: ModelContext,
        relativePath: String
    ) throws -> [AttemptRecord] {
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { record in
                record.relativeAudioPath == relativePath
            }
        )
        return try context.fetch(descriptor)
    }

    func fetchStoredAudioReferences(forRelativePath relativePath: String) throws -> [AttemptRecord] {
        try fetchAudioPathReferences(modelContext, relativePath)
    }

    func removeStoredFile(at url: URL) throws {
        try removeFileItem(url)
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
        let fetched = try modelContext.fetch(descriptor).filter { !$0.isFullRun }
        return includeInProgress ? fetched : fetched.filter { $0.status.isFinalized }
    }

    func fetchFullRuns(
        forPresentationID presentationID: UUID,
        includeInProgress: Bool = false
    ) throws -> [AttemptRecord] {
        try fetchAttempts(forPresentationID: presentationID, includeInProgress: includeInProgress)
            .filter(\.isFullRun)
    }

    func fetchSectionTakes(
        forPresentationID presentationID: UUID,
        includeInProgress: Bool = false
    ) throws -> [AttemptRecord] {
        try fetchAttempts(forPresentationID: presentationID, includeInProgress: includeInProgress)
            .filter { !$0.isFullRun }
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
