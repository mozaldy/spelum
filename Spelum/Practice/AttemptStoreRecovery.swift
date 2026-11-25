import Foundation
import SwiftData

extension AttemptStore {
    // MARK: - Deterministic Relaunch Recovery

    @discardableResult
    func recoverUnfinishedAttempts() throws -> AttemptRecoverySummary {
        let sidecarOutcome = try recoverPendingSaveSidecars()
        let inProgressOutcome = try recoverInProgressRecords()
        return AttemptRecoverySummary(
            recoveredPlayableCount: sidecarOutcome.playable + inProgressOutcome.playable,
            recoveredWithoutAudioCount: sidecarOutcome.withoutAudio + inProgressOutcome.withoutAudio,
            removedStaleSidecarCount: sidecarOutcome.removedStale
        )
    }

    // MARK: - Pending Save Sidecars

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
        let fileURL = pendingSaveManifestURL(for: attemptID)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func removeAudioFileIfUnreferenced(relativePath: String) {
        guard let fileURL = try? resolvedAudioURL(for: relativePath) else { return }
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { record in
                record.relativeAudioPath == relativePath
            }
        )
        let references = (try? modelContext.fetch(descriptor)) ?? []
        guard references.isEmpty else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private extension AttemptStore {
    struct RecoveryCounts {
        var playable = 0
        var withoutAudio = 0
        var removedStale = 0
    }

    func recoverPendingSaveSidecars() throws -> RecoveryCounts {
        var counts = RecoveryCounts()
        for manifest in loadPendingSaveManifests() {
            if let existing = try attempt(withID: manifest.attemptID), existing.status.isFinalized {
                removePendingSaveManifest(for: manifest.attemptID)
                counts.removedStale += 1
                continue
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
                interruptionReason: reason
            )
            let recovered = try finalizeAttempt(input)
            if recovered.hasPlayableAudio {
                counts.playable += 1
            } else {
                counts.withoutAudio += 1
            }
        }
        return counts
    }

    func recoverInProgressRecords() throws -> RecoveryCounts {
        var counts = RecoveryCounts()
        for pending in try fetchInProgressAttempts() {
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
                interruptionReason: reason
            )
            let recovered = try finalizeAttempt(input)
            if recovered.hasPlayableAudio {
                counts.playable += 1
            } else {
                counts.withoutAudio += 1
            }
        }
        return counts
    }

    func pendingSavesDirectoryURL() -> URL {
        storageRootURL.appendingPathComponent(Self.pendingSavesSubdirectoryName, isDirectory: true)
    }

    func pendingSaveManifestURL(for attemptID: UUID) -> URL {
        pendingSavesDirectoryURL().appendingPathComponent("\(attemptID.uuidString.lowercased()).json")
    }

    func loadPendingSaveManifests() -> [PendingSaveManifest] {
        let directory = pendingSavesDirectoryURL()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(PendingSaveManifest.self, from: data)
            }
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
