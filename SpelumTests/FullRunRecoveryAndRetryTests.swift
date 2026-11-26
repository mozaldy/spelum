import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Full Run Interruption, Relaunch Recovery, Retry & Isolated Deletion")
@MainActor
struct FullRunRecoveryAndRetryTests {
    @Test("Interrupted run, save failure retry, and crash/relaunch recovery preserve full-run transitions")
    func interruptionSaveRetryAndCrashRecovery() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Recovery")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        var shouldFailSave = false
        let attemptStore = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if shouldFailSave {
                    throw NSError(domain: "SimulatedFullRunSaveFailure", code: 500)
                }
                try context.save()
            }
        )
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .entireTalk
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 2.4
        recorder.silentDemoRange = nil
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            recorder: recorder
        )

        await session.startRecording()
        recorder.currentTime = 1.1
        _ = try #require(session.advanceFullRunSection())

        shouldFailSave = true
        recorder.currentTime = 2.4
        session.handleInterruption(reason: "Incoming phone call")
        guard case .saveFailed(let recovery) = session.phase else {
            Issue.record("Expected saveFailed recovery state after simulated save error")
            return
        }
        #expect(recovery.attemptKind == .fullRun)
        #expect(recovery.fullRunPayload?.transitions.count == 2)

        shouldFailSave = false
        let retried = try #require(session.retryFailedSave())
        #expect(retried.isFullRun)
        #expect(retried.status == .interrupted)
        #expect(retried.hasPlayableAudio)
        #expect(retried.fullRunPayload?.completionKind == .interrupted)
        #expect(retried.fullRunPayload?.transitions.count == 2)
        #expect(try attemptStore.fetchFullRuns(forPresentationID: talk.presentation.id).count == 1)

        try verifyCrashRelaunchRecovery(
            snapshot: snapshot,
            attemptStore: attemptStore,
            workspace: workspace
        )
    }

    @Test("Full run retries preserve mode and scope, and deleting one run keeps other runs playable")
    func retryAndIsolatedDeletion() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7RetryDelete")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .fromHandoff
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 1.6
        recorder.silentDemoRange = nil
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            initialMode: .memory,
            recorder: recorder
        )

        await session.startRecording()
        recorder.currentTime = 1.6
        let firstRun = try #require(session.stopRecording())

        let retryTarget = TakeReview.makeFullRunRetryTarget(
            for: firstRun,
            payload: try #require(firstRun.fullRunPayload)
        )
        #expect(retryTarget.talkRevisionID == talk.talkRevision.id)
        #expect(retryTarget.startKind == .fromHandoff)
        #expect(retryTarget.startingSectionID == snapshot.startingSection?.sectionID)
        #expect(retryTarget.initialMode == .memory)

        session.prepareForFullRunRetry(fullRunSnapshot: snapshot, practiceMode: retryTarget.initialMode)
        await session.startRecording()
        recorder.currentTime = 1.6
        let secondRun = try #require(session.stopRecording())

        #expect(firstRun.id != secondRun.id)
        #expect(firstRun.relativeAudioPath != secondRun.relativeAudioPath)

        // Delete first run; second run and its audio remain intact and playable across relaunch.
        try attemptStore.deleteAttempt(firstRun)
        #expect(try attemptStore.attempt(withID: firstRun.id) == nil)
        let relaunchedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let relaunchedStore = AttemptStore(
            modelContext: relaunchedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let remaining = try #require(try relaunchedStore.attempt(withID: secondRun.id))
        let remainingURL = try #require(relaunchedStore.resolvedAudioURL(for: remaining))
        #expect(FileManager.default.fileExists(atPath: remainingURL.path))
    }

    @Test("Leaving an active full run interrupts cleanly and preserves checkpointed transitions")
    func leavingViewInterruptsActiveFullRun() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Disappear")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .entireTalk
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 2.0
        recorder.silentDemoRange = nil
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            recorder: recorder
        )

        await session.startRecording()
        recorder.currentTime = 0.8
        _ = try #require(session.advanceFullRunSection())
        recorder.currentTime = 1.5
        session.handleViewDisappear()

        guard case .interrupted(let attemptID, let hasPlayableAudio, _) = session.phase else {
            Issue.record("Expected interrupted phase when leaving an active full run")
            return
        }
        #expect(hasPlayableAudio)
        let saved = try #require(try attemptStore.attempt(withID: attemptID))
        #expect(saved.isFullRun)
        #expect(saved.status == .interrupted)
        #expect(saved.fullRunPayload?.transitions.count == 2)
    }
}

private extension FullRunRecoveryAndRetryTests {
    func verifyCrashRelaunchRecovery(
        snapshot: FullRunSnapshot,
        attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws {
        let crashAttemptID = UUID()
        let partialPayload = FullRunAttemptPayload(
            snapshot: snapshot,
            transitions: [
                FullRunSectionTransition(
                    runIndex: 0,
                    talkSectionIndex: 0,
                    sectionID: snapshot.sections[0].sectionID,
                    sectionRevisionID: snapshot.sections[0].sectionRevisionID,
                    sectionTitle: snapshot.sections[0].title,
                    speaker: snapshot.sections[0].speaker,
                    speakerRole: snapshot.sections[0].speakerRole,
                    purpose: snapshot.sections[0].purpose,
                    startTime: 0
                ),
                FullRunSectionTransition(
                    runIndex: 1,
                    talkSectionIndex: 1,
                    sectionID: snapshot.sections[1].sectionID,
                    sectionRevisionID: snapshot.sections[1].sectionRevisionID,
                    sectionTitle: snapshot.sections[1].title,
                    speaker: snapshot.sections[1].speaker,
                    speakerRole: snapshot.sections[1].speakerRole,
                    purpose: snapshot.sections[1].purpose,
                    startTime: 0.9
                )
            ],
            completionKind: .interrupted,
            reachedSectionCount: 2
        )
        let begun = try attemptStore.beginAttempt(
            snapshot: snapshot.makeAttemptSnapshotReference(),
            practiceMode: .cueWords,
            isSilentRecall: false,
            attemptID: crashAttemptID,
            attemptKind: .fullRun,
            fullRunPayload: partialPayload
        )
        let crashAudioURL = try attemptStore.resolvedAudioURL(
            for: try #require(begun.relativeAudioPath)
        )
        try FullRunTestFixtures.writeContinuousQuietAAC(to: crashAudioURL, durationSeconds: 1.8)

        let relaunchedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let relaunchedAttempts = AttemptStore(
            modelContext: relaunchedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let summary = try relaunchedAttempts.recoverUnfinishedAttempts()
        #expect(summary.totalRecoveredCount == 1)
        #expect(summary.recoveredPlayableCount == 1)

        let recovered = try #require(try relaunchedAttempts.attempt(withID: crashAttemptID))
        #expect(recovered.isFullRun)
        #expect(recovered.status == .interrupted)
        #expect(recovered.hasPlayableAudio)
        #expect(recovered.fullRunPayload?.transitions.count == 2)
        #expect(recovered.fullRunPayload?.transitions[1].endTime != nil)
    }
}
