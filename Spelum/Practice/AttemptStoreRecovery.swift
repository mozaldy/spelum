import Foundation
import SwiftData

extension AttemptStore {
    struct PendingManifestScanResult {
        let manifests: [PendingSaveManifest]
        let unreadableCount: Int
    }

    // MARK: - Deterministic Relaunch Recovery

    @discardableResult
    func recoverUnfinishedAttempts() throws -> AttemptRecoverySummary {
        let sidecarOutcome = try recoverPendingSaveSidecars()
        let inProgressOutcome = try recoverInProgressRecords()
        if let firstError = sidecarOutcome.firstError ?? inProgressOutcome.firstError {
            throw firstError
        }
        return AttemptRecoverySummary(
            recoveredPlayableCount: sidecarOutcome.playable + inProgressOutcome.playable,
            recoveredWithoutAudioCount: sidecarOutcome.withoutAudio + inProgressOutcome.withoutAudio,
            removedStaleSidecarCount: sidecarOutcome.removedStale + inProgressOutcome.removedStale
        )
    }

    // MARK: - Pending Save Sidecars & Reference-Safe Cleanup

    func writePendingSaveManifest(_ manifest: PendingSaveManifest) {
        let directory = pendingSavesDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(manifest)
            let fileURL = pendingSaveManifestURL(for: manifest.attemptID)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort sidecar; in-memory recovery still remains active.
        }
    }

    func removePendingSaveManifest(for attemptID: UUID) {
        try? removePendingSaveManifestStrict(for: attemptID)
    }

    func removePendingSaveManifestStrict(for attemptID: UUID) throws {
        try removeFileStrictly(at: pendingSaveManifestURL(for: attemptID))
    }

    func loadPendingSaveManifest(for attemptID: UUID) throws -> PendingSaveManifest? {
        let fileURL = pendingSaveManifestURL(for: attemptID)
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(PendingSaveManifest.self, from: data)
        } catch where isFileNotFoundError(error) {
            return nil
        }
    }

    func loadPendingSaveManifestEntries() throws -> PendingManifestScanResult {
        let directory = pendingSavesDirectoryURL()
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch where isFileNotFoundError(error) {
            return PendingManifestScanResult(manifests: [], unreadableCount: 0)
        }

        var manifests: [PendingSaveManifest] = []
        var unreadableCount = 0
        let sortedURLs = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in sortedURLs {
            do {
                let data = try Data(contentsOf: url)
                let manifest = try JSONDecoder().decode(PendingSaveManifest.self, from: data)
                manifests.append(manifest)
            } catch {
                unreadableCount += 1
            }
        }
        return PendingManifestScanResult(manifests: manifests, unreadableCount: unreadableCount)
    }

    @discardableResult
    func removeAudioFileIfUnreferenced(
        relativePath: String,
        excludingAttemptIDs: Set<UUID> = [],
        excludingManifestAttemptIDs: Set<UUID> = []
    ) throws -> Bool {
        let fileURL = try resolvedAudioURL(for: relativePath)
        let dbReferences = try fetchStoredAudioReferences(forRelativePath: relativePath)
            .filter { !excludingAttemptIDs.contains($0.id) }
        guard dbReferences.isEmpty else { return false }

        let manifestScan = try loadPendingSaveManifestEntries()
        guard manifestScan.unreadableCount == 0 else {
            throw AttemptStoreError.audioReferenceStateUnknown
        }
        let referencedByManifest = manifestScan.manifests.contains { manifest in
            !excludingManifestAttemptIDs.contains(manifest.attemptID) &&
                manifest.relativeAudioPath == relativePath
        }
        guard !referencedByManifest else { return false }

        try removeFileStrictly(at: fileURL)
        return true
    }

    func cleanupDeletedPresentationArtifacts(
        attemptTargets: [(id: UUID, relativePath: String?)],
        matchingManifests: [PendingSaveManifest]
    ) throws {
        let batchIDs = Set(attemptTargets.map(\.id)).union(matchingManifests.map(\.attemptID))
        var cleanupError: Error?

        for manifest in matchingManifests {
            do {
                if let relativePath = manifest.relativeAudioPath {
                    _ = try removeAudioFileIfUnreferenced(
                        relativePath: relativePath,
                        excludingManifestAttemptIDs: batchIDs
                    )
                }
                try removePendingSaveManifestStrict(for: manifest.attemptID)
            } catch {
                if cleanupError == nil { cleanupError = error }
            }
        }

        let manifestIDs = Set(matchingManifests.map(\.attemptID))
        for target in attemptTargets where !manifestIDs.contains(target.id) {
            do {
                if let relativePath = target.relativePath {
                    _ = try removeAudioFileIfUnreferenced(
                        relativePath: relativePath,
                        excludingManifestAttemptIDs: batchIDs
                    )
                }
                try removePendingSaveManifestStrict(for: target.id)
            } catch {
                if cleanupError == nil { cleanupError = error }
            }
        }

        if let cleanupError {
            throw cleanupError
        }
    }
}

private extension AttemptStore {
    struct RecoveryCounts {
        var playable = 0
        var withoutAudio = 0
        var removedStale = 0
        var firstError: Error?
    }

    func recoverPendingSaveSidecars() throws -> RecoveryCounts {
        var counts = RecoveryCounts()
        let manifestScan = try loadPendingSaveManifestEntries()
        for manifest in manifestScan.manifests {
            do {
                try recoverSingleManifest(manifest, counts: &counts)
            } catch {
                if counts.firstError == nil { counts.firstError = error }
            }
        }
        return counts
    }

    func recoverSingleManifest(
        _ manifest: PendingSaveManifest,
        counts: inout RecoveryCounts
    ) throws {
        guard try hasValidParent(for: manifest.snapshot) else {
            try cleanupOrphanManifest(manifest)
            counts.removedStale += 1
            return
        }
        if let existing = try attempt(withID: manifest.attemptID), existing.status.isFinalized {
            try removePendingSaveManifestStrict(for: manifest.attemptID)
            counts.removedStale += 1
            return
        }
        let reason = manifest.interruptionReason
            ?? "Recovered unfinished rehearsal save after reopening Spelum."
        let input = AttemptFinalizationInput(
            id: manifest.attemptID,
            snapshot: manifest.snapshot,
            practiceMode: manifest.practiceMode,
            startedAt: manifest.startedAt,
            finishedAt: manifest.finishedAt,
            relativeAudioPath: manifest.relativeAudioPath,
            elapsedDuration: manifest.elapsedDuration,
            revealCount: manifest.revealCount,
            markers: manifest.markers,
            isSilentRecall: manifest.isSilentRecall,
            interrupted: true,
            interruptionReason: reason,
            attemptKind: manifest.resolvedAttemptKind,
            fullRunPayload: manifest.fullRunPayload
        )
        let recovered = try finalizeAttempt(input)
        if recovered.hasPlayableAudio {
            counts.playable += 1
        } else {
            counts.withoutAudio += 1
        }
    }

    func recoverInProgressRecords() throws -> RecoveryCounts {
        var counts = RecoveryCounts()
        for pending in try fetchInProgressAttempts() {
            do {
                try recoverSingleInProgressAttempt(pending, counts: &counts)
            } catch {
                if counts.firstError == nil { counts.firstError = error }
            }
        }
        return counts
    }

    func recoverSingleInProgressAttempt(
        _ pending: AttemptRecord,
        counts: inout RecoveryCounts
    ) throws {
        guard try hasValidParent(for: pending.snapshotReference) else {
            try cleanupOrphanInProgressAttempt(pending)
            counts.removedStale += 1
            return
        }
        let playable = playableDuration(forRelativePath: pending.relativeAudioPath)
        let reason = playable != nil
            ? "Recovered playable audio from an unfinished recording."
            : "Recording ended before playable audio was saved."
        let input = AttemptFinalizationInput(
            id: pending.id,
            snapshot: pending.snapshotReference,
            practiceMode: pending.practiceMode,
            startedAt: pending.startedAt,
            finishedAt: modificationDate(forRelativePath: pending.relativeAudioPath) ?? Date(),
            relativeAudioPath: pending.relativeAudioPath,
            elapsedDuration: max(pending.elapsedDuration, playable ?? 0),
            revealCount: pending.revealCount,
            markers: pending.markers,
            isSilentRecall: pending.isSilentRecall,
            interrupted: true,
            interruptionReason: reason,
            attemptKind: pending.attemptKind,
            fullRunPayload: pending.fullRunPayload
        )
        let recovered = try finalizeAttempt(input)
        if recovered.hasPlayableAudio {
            counts.playable += 1
        } else {
            counts.withoutAudio += 1
        }
    }

    func hasValidParent(for snapshot: AttemptSnapshotReference) throws -> Bool {
        let presentationID = snapshot.presentationID
        let talkRevisionID = snapshot.talkRevisionID
        let sectionRevisionID = snapshot.sectionRevisionID

        let presentationDescriptor = FetchDescriptor<PresentationRecord>(
            predicate: #Predicate<PresentationRecord> { record in
                record.id == presentationID
            }
        )
        guard try !modelContext.fetch(presentationDescriptor).isEmpty else {
            return false
        }
        let talkDescriptor = FetchDescriptor<TalkRevisionRecord>(
            predicate: #Predicate<TalkRevisionRecord> { record in
                record.id == talkRevisionID
            }
        )
        guard let talkRevision = try modelContext.fetch(talkDescriptor).first,
              talkRevision.presentation?.id == presentationID else {
            return false
        }
        let sectionDescriptor = FetchDescriptor<SectionRevisionRecord>(
            predicate: #Predicate<SectionRevisionRecord> { record in
                record.revisionID == sectionRevisionID
            }
        )
        guard let sectionRevision = try modelContext.fetch(sectionDescriptor).first,
              sectionRevision.presentation?.id == presentationID else {
            return false
        }
        return true
    }

    func cleanupOrphanManifest(_ manifest: PendingSaveManifest) throws {
        let existing = try attempt(withID: manifest.attemptID)
        let removableInProgressID: Set<UUID> = (existing?.status.isFinalized == false)
            ? [manifest.attemptID]
            : []
        if let relativePath = manifest.relativeAudioPath {
            _ = try removeAudioFileIfUnreferenced(
                relativePath: relativePath,
                excludingAttemptIDs: removableInProgressID,
                excludingManifestAttemptIDs: [manifest.attemptID]
            )
        }
        if let existing, !existing.status.isFinalized {
            try performAtomicWrite {
                modelContext.delete(existing)
            }
        }
        try removePendingSaveManifestStrict(for: manifest.attemptID)
    }

    func cleanupOrphanInProgressAttempt(_ pending: AttemptRecord) throws {
        let attemptID = pending.id
        let relativePath = pending.relativeAudioPath
        if let relativePath {
            _ = try removeAudioFileIfUnreferenced(
                relativePath: relativePath,
                excludingAttemptIDs: [attemptID],
                excludingManifestAttemptIDs: [attemptID]
            )
        }
        try performAtomicWrite {
            modelContext.delete(pending)
        }
        try removePendingSaveManifestStrict(for: attemptID)
    }

    func removeFileStrictly(at url: URL) throws {
        do {
            try removeStoredFile(at: url)
        } catch where isFileNotFoundError(error) {
            return
        }
    }

    func isFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        return false
    }

    func pendingSavesDirectoryURL() -> URL {
        storageRootURL.appendingPathComponent(Self.pendingSavesSubdirectoryName, isDirectory: true)
    }

    func pendingSaveManifestURL(for attemptID: UUID) -> URL {
        pendingSavesDirectoryURL().appendingPathComponent("\(attemptID.uuidString.lowercased()).json")
    }

    func modificationDate(forRelativePath relativePath: String?) -> Date? {
        guard let relativePath,
              let url = try? resolvedAudioURL(for: relativePath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
