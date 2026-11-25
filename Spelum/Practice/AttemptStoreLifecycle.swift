import Foundation
import SwiftData

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
                _ = try? removeAudioFileIfUnreferenced(relativePath: unplayablePath)
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
            let manifest = try loadPendingSaveManifest(for: id)
            if let relativePath = manifest?.relativeAudioPath {
                _ = try? removeAudioFileIfUnreferenced(
                    relativePath: relativePath,
                    excludingManifestAttemptIDs: [id]
                )
            }
            try removePendingSaveManifestStrict(for: id)
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

        try? removePendingSaveManifestStrict(for: attemptID)
        if let relativePath {
            _ = try? removeAudioFileIfUnreferenced(relativePath: relativePath)
        }
    }

    func deletePresentationAndAttempts(_ presentation: PresentationRecord) throws {
        let presentationID = presentation.id
        let attempts = try fetchAttempts(forPresentationID: presentationID, includeInProgress: true)
        let manifestScan = try loadPendingSaveManifestEntries()
        let matchingManifests = manifestScan.manifests.filter {
            $0.snapshot.presentationID == presentationID
        }
        let attemptTargets: [(id: UUID, relativePath: String?)] = attempts.map {
            ($0.id, $0.relativeAudioPath)
        }

        try performAtomicWrite {
            for attempt in attempts {
                modelContext.delete(attempt)
            }
            modelContext.delete(presentation)
        }

        try cleanupDeletedPresentationArtifacts(
            attemptTargets: attemptTargets,
            matchingManifests: matchingManifests
        )
    }

    func discardUnpersistedAudio(for attemptID: UUID, relativeAudioPath: String?) throws {
        let existing = try attempt(withID: attemptID)
        var candidatePaths: Set<String> = []
        if let relativeAudioPath {
            candidatePaths.insert(relativeAudioPath)
        }

        if let existing {
            guard !existing.status.isFinalized else {
                try removePendingSaveManifestStrict(for: attemptID)
                return
            }
            if let existingPath = existing.relativeAudioPath {
                candidatePaths.insert(existingPath)
            }
            try performAtomicWrite {
                modelContext.delete(existing)
            }
        }

        try removePendingSaveManifestStrict(for: attemptID)

        for path in candidatePaths {
            _ = try? removeAudioFileIfUnreferenced(relativePath: path)
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
