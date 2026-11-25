import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 3 Permission and Delegate Callback Regressions")
@MainActor
struct Task3ReviewRegressionTests {
    @Test("Leaving practice during async mic permission invalidates late grant and allows clean restart")
    func leavePracticeDuringAsyncPermissionInvalidatesLateGrant() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3PermLeave")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let permission = ControlledMicrophonePermissionProvider(status: .undetermined)
        let audioSession = TrackingAudioSessionManager()
        let recorder = TrackingAudioRecorderController()
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .cueWords,
            permissionProvider: permission,
            audioSessionManager: audioSession,
            recorder: recorder
        )

        let startTask = Task { await session.startRecording() }
        while permission.pendingRequestCount == 0 { await Task.yield() }
        #expect(session.phase == .requestingPermission)

        session.handleViewDisappear()
        #expect(session.phase == .idle)
        permission.resolveOldest(granted: true)
        await startTask.value

        #expect(session.phase == .idle)
        #expect(audioSession.recordingActivations == 0)
        #expect(recorder.startCount == 0)
        #expect(!recorder.isRecording)
        let attempts = try store.fetchAttempts(forPresentationID: seeded.presentation.id, includeInProgress: true)
        #expect(attempts.isEmpty)
        let takesDir = workspace.storageRoot.appendingPathComponent(AttemptStore.takesSubdirectoryName)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: takesDir.path)) ?? []
        #expect(files.isEmpty)

        await session.startRecording()
        #expect(session.phase == .recording)
        #expect(audioSession.recordingActivations == 1)
        #expect(recorder.startCount == 1)
        let saved = try #require(session.stopRecording())
        #expect(saved.status == .ready)
    }

    @Test("Leave/re-enter before old permission returns guards stale grant and lets new request succeed")
    func leaveReenterBeforeOldPermissionGuardsStaleGrant() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3PermReenterGrant")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let permission = ControlledMicrophonePermissionProvider(status: .undetermined)
        let audioSession = TrackingAudioSessionManager()
        let recorder = TrackingAudioRecorderController()
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .memory,
            permissionProvider: permission,
            audioSessionManager: audioSession,
            recorder: recorder
        )

        let firstTask = Task { await session.startRecording() }
        while permission.pendingRequestCount < 1 { await Task.yield() }
        session.handleViewDisappear()
        session.prepareForRetry()

        let secondTask = Task { await session.startRecording() }
        while permission.pendingRequestCount < 2 { await Task.yield() }

        // Stale grant from Request 1 arrives first: must NOT start capture or disturb Request 2.
        permission.resolveOldest(granted: true, updateStatus: false)
        await firstTask.value
        #expect(session.phase == .requestingPermission)
        #expect(audioSession.recordingActivations == 0)
        #expect(recorder.startCount == 0)

        permission.resolveOldest(granted: true, updateStatus: true)
        await secondTask.value
        #expect(session.phase == .recording)
        #expect(audioSession.recordingActivations == 1)
        #expect(recorder.startCount == 1)
        let saved = try #require(session.stopRecording())
        #expect(saved.status == .ready)
    }

    @Test("Stale permission denial after retry cannot clobber a newer active recording")
    func staleDenialAfterRetryDoesNotClobberActiveRecording() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3PermStaleDeny")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let permission = ControlledMicrophonePermissionProvider(status: .undetermined)
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .cueWords,
            permissionProvider: permission,
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: TrackingAudioRecorderController()
        )

        let staleTask = Task { await session.startRecording() }
        while permission.pendingRequestCount < 1 { await Task.yield() }
        session.prepareForRetry()

        let freshTask = Task { await session.startRecording() }
        while permission.pendingRequestCount < 2 { await Task.yield() }

        permission.resolveNewest(granted: true, updateStatus: true)
        await freshTask.value
        #expect(session.phase == .recording)

        permission.resolveOldest(granted: false, updateStatus: false)
        await staleTask.value
        #expect(session.phase == .recording)
        #expect(!session.microphoneDeniedNoticeVisible)
        #expect(session.permissionStatus == .granted)

        let saved = try #require(session.stopRecording())
        #expect(saved.status == .ready)
    }

    @Test("Cancelling startRecording task invalidates pending request and allows a new start")
    func cancelledStartRecordingTaskInvalidatesPendingRequest() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3PermCancel")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let permission = ControlledMicrophonePermissionProvider(status: .undetermined)
        let audioSession = TrackingAudioSessionManager()
        let recorder = TrackingAudioRecorderController()
        let session = RecordingSession(
            attemptStore: store,
            snapshot: seeded.snapshot,
            initialMode: .fullScript,
            permissionProvider: permission,
            audioSessionManager: audioSession,
            recorder: recorder
        )

        let cancelledTask = Task { await session.startRecording() }
        while permission.pendingRequestCount < 1 { await Task.yield() }
        cancelledTask.cancel()
        try await Task.sleep(for: .milliseconds(25))
        #expect(session.phase == .idle)

        session.startSilentRecall()
        #expect(session.phase == .silentRecall)

        permission.resolveOldest(granted: true, updateStatus: false)
        await cancelledTask.value

        #expect(session.phase == .silentRecall)
        #expect(audioSession.recordingActivations == 0)
        #expect(recorder.startCount == 0)
        let saved = try #require(session.stopRecording())
        #expect(saved.status == .silentCompleted)
    }

    @Test("Stale finish and encode-error callbacks from recorder A do not clear or interrupt recorder B")
    func staleRecorderCallbacksDoNotClearOrInterruptRecorderB() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3StaleRecorder")
        defer { workspace.cleanup() }

        let urlA = workspace.storageRoot.appendingPathComponent("Takes/recA.m4a")
        let urlB = workspace.storageRoot.appendingPathComponent("Takes/recB.m4a")
        try FileManager.default.createDirectory(
            at: urlA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recorderA = try DeterministicStubAudioRecorder(
            url: urlA,
            settings: AVAudioRecorderController.recordingSettings
        )
        let recorderB = try DeterministicStubAudioRecorder(
            url: urlB,
            settings: AVAudioRecorderController.recordingSettings
        )
        var created = 0
        let controller = AVAudioRecorderController { _, _ in
            created += 1
            return created == 1 ? recorderA : recorderB
        }

        var unexpectedFinishCount = 0
        var encodeErrorCount = 0
        controller.onUnexpectedFinish = { _ in unexpectedFinishCount += 1 }
        controller.onEncodeError = { _ in encodeErrorCount += 1 }

        try controller.startRecording(to: urlA)
        controller.stopRecording()
        try controller.startRecording(to: urlB)
        #expect(controller.isRecording)

        controller.audioRecorderDidFinishRecording(recorderA, successfully: true)
        controller.audioRecorderDidFinishRecording(recorderA, successfully: false)
        controller.audioRecorderEncodeErrorDidOccur(
            recorderA,
            error: NSError(domain: "StaleEncode", code: 42)
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(controller.isRecording)
        #expect(recorderB.isRecording)
        #expect(unexpectedFinishCount == 0)
        #expect(encodeErrorCount == 0)

        controller.audioRecorderEncodeErrorDidOccur(
            recorderB,
            error: NSError(domain: "ActiveEncode", code: 7)
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(!controller.isRecording)
        #expect(encodeErrorCount == 1)
    }

    @Test("Stale AVAudioPlayer delegate callbacks from player A do not stop or error player B")
    func stalePlayerCallbacksDoNotAffectActivePlayer() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3StalePlayer")
        defer { workspace.cleanup() }

        let urlA = workspace.storageRoot.appendingPathComponent("Takes/a.m4a")
        let urlB = workspace.storageRoot.appendingPathComponent("Takes/b.m4a")
        try PracticeTestFixtures.writeSyntheticAACM4A(to: urlA, durationSeconds: 1.5)
        try PracticeTestFixtures.writeSyntheticAACM4A(to: urlB, durationSeconds: 1.5)

        let stalePlayerA = try AVAudioPlayer(contentsOf: urlA)
        let audioSession = TrackingAudioSessionManager()
        let takePlayer = TakeAudioPlayer(audioSessionManager: audioSession)
        takePlayer.load(url: urlB)
        takePlayer.play()
        #expect(takePlayer.isPlaying)
        let deactivationsBefore = audioSession.deactivations

        takePlayer.audioPlayerDidFinishPlaying(stalePlayerA, successfully: true)
        takePlayer.audioPlayerDecodeErrorDidOccur(
            stalePlayerA,
            error: NSError(domain: "StaleDecode", code: 99)
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(takePlayer.isPlaying)
        #expect(takePlayer.errorMessage == nil)
        #expect(audioSession.deactivations == deactivationsBefore)
        takePlayer.stop()
    }
}
