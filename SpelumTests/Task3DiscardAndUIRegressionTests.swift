import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 3 Discard and UI State Regressions")
@MainActor
struct Task3DiscardAndUIRegressionTests {
    @Test("Failed discard after failed finalization preserves retry, metadata, and stays deleted once resolved")
    func failedDiscardPreservesRetryMetadataAndStaysDeletedOnceResolved() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3DiscardFail")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        var shouldFailSave = false
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if shouldFailSave { throw NSError(domain: "PersistentStorageFailure", code: 503) }
                try context.save()
            }
        )
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .memory,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: TrackingAudioRecorderController()
        )

        await session.startRecording()
        session.activateReveal()
        session.addManualMarker(label: "Critical transition")

        shouldFailSave = true
        #expect(session.stopRecording() == nil)
        guard case .saveFailed(let initialRecovery) = session.phase else {
            Issue.record("Expected .saveFailed, got \(session.phase)")
            return
        }
        let manifestURL = Task3ManifestTestHelper.manifestURL(in: workspace, attemptID: initialRecovery.attemptID)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        #expect(!session.discardFailedSave())
        guard case .saveFailed(let preservedRecovery) = session.phase else {
            Issue.record("Expected .saveFailed to remain visible on failed discard")
            return
        }
        #expect(preservedRecovery.attemptID == initialRecovery.attemptID)
        #expect(preservedRecovery.revealCount == 1)
        #expect(preservedRecovery.markers.map(\.label) == ["Critical transition"])
        #expect(preservedRecovery.discardErrorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        shouldFailSave = false
        #expect(session.discardFailedSave())
        #expect(session.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))

        try verifyDiscardedStaysDeletedAcrossRelaunch(workspace: workspace, presentationID: seeded.presentation.id)
    }

    @Test("Failed silent-recall manifest removal on discard preserves retry and stays deleted once resolved")
    func failedSilentRecallDiscardPreservesManifestUntilRemovalSucceeds() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3SilentDiscardFail")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        var shouldFailSave = false
        var shouldFailManifestRemoval = true
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if shouldFailSave { throw NSError(domain: "SilentSaveError", code: 500) }
                try context.save()
            },
            removeFileItem: { url in
                if shouldFailManifestRemoval && url.pathExtension == "json" {
                    throw NSError(domain: "ManifestRemovalBlocked", code: 13)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .memory,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .denied),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: TrackingAudioRecorderController()
        )

        session.startSilentRecall()
        session.activateReveal()
        shouldFailSave = true
        #expect(session.stopRecording() == nil)
        guard case .saveFailed(let recovery) = session.phase else {
            Issue.record("Expected .saveFailed for silent recall")
            return
        }
        let manifestURL = Task3ManifestTestHelper.manifestURL(in: workspace, attemptID: recovery.attemptID)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        #expect(!session.discardFailedSave())
        guard case .saveFailed(let preserved) = session.phase else {
            Issue.record("Expected .saveFailed while manifest removal fails")
            return
        }
        #expect(preserved.revealCount == 1)
        #expect(preserved.discardErrorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        shouldFailSave = false
        shouldFailManifestRemoval = false
        #expect(session.discardFailedSave())
        #expect(session.phase == .idle)
        try verifyDiscardedStaysDeletedAcrossRelaunch(workspace: workspace, presentationID: seeded.presentation.id)
    }

    @Test("Retry save still succeeds with intact metadata after an earlier failed discard")
    func retrySaveSucceedsWithIntactMetadataAfterFailedDiscard() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3RetryAfterDiscardFail")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        var shouldFailSave = false
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if shouldFailSave { throw NSError(domain: "TransientSaveFailure", code: 503) }
                try context.save()
            }
        )
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .cueWords,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: TrackingAudioRecorderController()
        )

        await session.startRecording()
        session.activateReveal()
        session.addManualMarker(label: "Opening beat")
        shouldFailSave = true
        #expect(session.stopRecording() == nil)
        #expect(!session.discardFailedSave())

        shouldFailSave = false
        let saved = try #require(session.retryFailedSave())
        #expect(saved.status == .ready)
        #expect(saved.revealCount == 1)
        #expect(saved.markers.map(\.label) == ["Opening beat"])
    }

    @Test("Deleting an interrupted take clears stale partial-take banner state; surviving take preserves it")
    func deletingInterruptedTakeClearsStalePartialTakeBanner() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3StaleBanner")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .cueWords,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: TrackingAudioRecorderController()
        )

        await session.startRecording()
        session.handleInterruption(reason: "Incoming call")
        guard case .interrupted(let interruptedID, true, _) = session.phase else {
            Issue.record("Expected .interrupted with playable audio")
            return
        }

        session.reconcileReferencedAttempt()
        #expect(
            session.phase == .interrupted(
                attemptID: interruptedID,
                hasPlayableAudio: true,
                reason: "Incoming call"
            )
        )

        try store.deleteAttempt(id: interruptedID)
        session.reconcileReferencedAttempt()
        #expect(session.phase == .idle)

        await session.startRecording()
        session.handleInterruption(reason: "Route reset")
        guard case .interrupted(let secondID, _, _) = session.phase else {
            Issue.record("Expected second .interrupted phase")
            return
        }
        try store.deleteAttempt(id: secondID)
        session.clearDeletedAttemptReference(secondID)
        #expect(session.phase == .idle)
    }

    @Test("Failed take deletion in TakeReview preserves loaded playable audio; successful deletion stops player")
    func failedTakeDeletionPreservesPlaybackAndSuccessfulDeletionStopsPlayer() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3DeletePlayback")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        var shouldFailSave = false
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if shouldFailSave { throw NSError(domain: "DeleteBlocked", code: 500) }
                try context.save()
            }
        )
        let saved = try PracticeTestFixtures.saveSyntheticTake(
            in: store,
            snapshot: seeded.snapshot,
            mode: .memory,
            durationSeconds: 1.5
        )
        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: saved.audioURL)
        player.play()
        #expect(player.isLoaded)
        #expect(player.isPlaying)

        shouldFailSave = true
        #expect(throws: Error.self) {
            try TakeReview.performDeletion(attempt: saved.attempt, attemptStore: store, player: player)
        }
        #expect(player.isLoaded)
        #expect(!player.isPlaying)
        #expect(player.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: saved.audioURL.path))

        player.seek(to: 0.5, autoPlay: true)
        #expect(player.isPlaying)
        #expect(abs(player.currentTime - 0.5) < 0.1)

        shouldFailSave = false
        try TakeReview.performDeletion(attempt: saved.attempt, attemptStore: store, player: player)
        #expect(!player.isLoaded)
        #expect(!player.isPlaying)
        #expect(try store.attempt(withID: saved.attempt.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: saved.audioURL.path))
    }

    private func verifyDiscardedStaysDeletedAcrossRelaunch(
        workspace: PracticeTestWorkspace,
        presentationID: UUID
    ) throws {
        let reopened = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let reopenedStore = AttemptStore(modelContext: reopened.mainContext, storageRootURL: workspace.storageRoot)
        let summary = try reopenedStore.recoverUnfinishedAttempts()
        #expect(summary.totalRecoveredCount == 0)
        let remaining = try reopenedStore.fetchAttempts(
            forPresentationID: presentationID,
            includeInProgress: true
        )
        #expect(remaining.isEmpty)
    }
}
