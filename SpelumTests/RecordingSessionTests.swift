import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Spelum

@MainActor
private final class FakeMicrophonePermissionProvider: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus
    var grantOnRequest: Bool
    var requestCount = 0

    init(status: MicrophonePermissionStatus, grantOnRequest: Bool = true) {
        self.status = status
        self.grantOnRequest = grantOnRequest
    }

    func currentStatus() -> MicrophonePermissionStatus { status }

    func requestAccess() async -> Bool {
        requestCount += 1
        status = grantOnRequest ? .granted : .denied
        return grantOnRequest
    }
}

@MainActor
private final class FakeAudioSessionManager: AudioSessionManaging {
    var recordingActivations = 0
    var playbackActivations = 0
    var deactivations = 0
    var errorOnRecording: Error?

    func activateForRecording() throws {
        if let errorOnRecording { throw errorOnRecording }
        recordingActivations += 1
    }

    func activateForPlayback() throws { playbackActivations += 1 }
    func deactivate() { deactivations += 1 }
}

@MainActor
private final class SyntheticAudioRecorderController: AudioRecorderControlling {
    var currentTime: TimeInterval = 0
    var isRecording = false
    var onUnexpectedFinish: ((Bool) -> Void)?
    var onEncodeError: ((Error?) -> Void)?

    var syntheticDuration: TimeInterval = 1.4
    var writePlayableAudio = true
    var activeURL: URL?

    func startRecording(to url: URL) throws {
        activeURL = url
        isRecording = true
        currentTime = syntheticDuration
        if writePlayableAudio {
            try Self.writeToneWAV(to: url, durationSeconds: syntheticDuration)
        } else {
            try Data().write(to: url)
        }
    }

    func stopRecording() {
        isRecording = false
    }

    static func writeToneWAV(to url: URL, durationSeconds: Double) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "SyntheticRecorder", code: 1)
        }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "SyntheticRecorder", code: 2)
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0 ..< Int(frameCount) {
                channel[frame] = Float(sin(2.0 * Double.pi * 330.0 * Double(frame) / sampleRate) * 0.2)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

@Suite("Recording Session and Playback")
@MainActor
struct RecordingSessionTests {
    private func makeSnapshot() -> AttemptSnapshotReference {
        AttemptSnapshotReference(
            presentationID: UUID(),
            talkRevisionID: UUID(),
            talkRevisionNumber: 2,
            sectionID: UUID(),
            sectionRevisionID: UUID(),
            sectionTitle: "Product Reveal"
        )
    }

    @Test("First record asks microphone permission; denial leaves silent recall accessible")
    func permissionAskedOnFirstRecordAndDenialEnablesSilentRecall() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SessionPerm")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let permission = FakeMicrophonePermissionProvider(status: .undetermined, grantOnRequest: false)
        let session = RecordingSession(
            attemptStore: store,
            snapshot: makeSnapshot(),
            initialMode: .memory,
            permissionProvider: permission,
            audioSessionManager: FakeAudioSessionManager(),
            recorder: SyntheticAudioRecorderController()
        )

        #expect(permission.requestCount == 0)
        await session.startRecording()
        #expect(permission.requestCount == 1)
        #expect(session.permissionStatus == .denied)
        #expect(session.microphoneDeniedNoticeVisible)
        #expect(session.phase == .idle)

        session.startSilentRecall()
        #expect(session.phase == .silentRecall)
        session.activateReveal()
        session.activateReveal() // Repeated while already revealed does not double-count
        session.hideScript()
        session.activateReveal()
        session.addManualMarker(label: "Key beat")

        let saved = try #require(session.stopRecording())
        #expect(saved.status == .silentCompleted)
        #expect(saved.isSilentRecall)
        #expect(saved.relativeAudioPath == nil)
        #expect(saved.playableDuration == 0)
        #expect(saved.revealCount == 2)
        #expect(saved.markers.count == 1)
        #expect(saved.markers.first?.label == "Key beat")
    }

    @Test("Repeated stop is idempotent and retry preserves revision and practice mode without duplicating")
    func repeatedStopAndRetryOnSameRevisionAndMode() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SessionTest")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let snapshot = makeSnapshot()
        let recorder = SyntheticAudioRecorderController()
        let session = RecordingSession(
            attemptStore: store,
            snapshot: snapshot,
            initialMode: .cueWords,
            permissionProvider: FakeMicrophonePermissionProvider(status: .granted),
            audioSessionManager: FakeAudioSessionManager(),
            recorder: recorder
        )

        await session.startRecording()
        #expect(session.phase == .recording)
        session.activateReveal()
        session.addManualMarker()

        let first = try #require(session.stopRecording())
        let secondStopResult = session.stopRecording()
        #expect(secondStopResult == nil)
        #expect(first.status == .ready)
        #expect(first.revealCount == 1)
        #expect(first.playableDuration > 1.1)

        session.prepareForRetry()
        #expect(session.practiceMode == .cueWords)
        #expect(session.snapshot == snapshot)
        #expect(session.revealCount == 0)
        #expect(session.markers.isEmpty)

        await session.startRecording()
        let retried = try #require(session.stopRecording())
        #expect(retried.id != first.id)
        #expect(retried.talkRevisionID == snapshot.talkRevisionID)
        #expect(retried.sectionRevisionID == snapshot.sectionRevisionID)
        #expect(retried.practiceMode == .cueWords)

        let all = try store.fetchAttempts(forSectionID: snapshot.sectionID, in: snapshot.presentationID)
        #expect(all.count == 2)
    }

    @Test("Audio interruption preserves playable partial audio and labels take interrupted")
    func interruptionPreservesPlayablePartialTake() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SessionTest")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let snapshot = makeSnapshot()
        let recorder = SyntheticAudioRecorderController()
        recorder.syntheticDuration = 0.8
        let center = NotificationCenter()
        let session = RecordingSession(
            attemptStore: store,
            snapshot: snapshot,
            initialMode: .fullScript,
            permissionProvider: FakeMicrophonePermissionProvider(status: .granted),
            audioSessionManager: FakeAudioSessionManager(),
            recorder: recorder,
            notificationCenter: center
        )

        await session.startRecording()
        #expect(session.phase == .recording)
        // Reveal in full script mode should never increment revealCount
        session.activateReveal()
        #expect(session.revealCount == 0)

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        try await Task.sleep(for: .milliseconds(50))

        guard case .interrupted(let attemptID, let hasPlayableAudio, _) = session.phase else {
            Issue.record("Expected interrupted phase, got \(session.phase)")
            return
        }
        #expect(hasPlayableAudio)
        let saved = try #require(try store.attempt(withID: attemptID))
        #expect(saved.status == .interrupted)
        #expect(saved.playableDuration > 0.6)
        let audioURL = try #require(store.resolvedAudioURL(for: saved))
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test("Finalization store failure preserves playable audio and retry saves without duplicating")
    func finalizationFailurePreservesAudioAndRetrySavesOnce() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SessionTest")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        var shouldFailNextSave = false
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if shouldFailNextSave {
                    throw NSError(domain: "TestStoreFailure", code: 500)
                }
                try context.save()
            }
        )
        let snapshot = makeSnapshot()
        let recorder = SyntheticAudioRecorderController()
        let session = RecordingSession(
            attemptStore: store,
            snapshot: snapshot,
            initialMode: .memory,
            permissionProvider: FakeMicrophonePermissionProvider(status: .granted),
            audioSessionManager: FakeAudioSessionManager(),
            recorder: recorder
        )

        await session.startRecording()
        session.activateReveal()
        shouldFailNextSave = true
        let failedResult = session.stopRecording()
        #expect(failedResult == nil)

        guard case .saveFailed(let recovery) = session.phase else {
            Issue.record("Expected saveFailed phase, got \(session.phase)")
            return
        }
        #expect(recovery.hasPlayableAudio)
        let preservedPath = try #require(recovery.relativeAudioPath)
        let preservedURL = try store.resolvedAudioURL(for: preservedPath)
        #expect(FileManager.default.fileExists(atPath: preservedURL.path))

        shouldFailNextSave = false
        let retriedSave = try #require(session.retryFailedSave())
        #expect(retriedSave.id == recovery.attemptID)
        #expect(retriedSave.status == .ready)
        #expect(retriedSave.revealCount == 1)

        let attempts = try store.fetchAttempts(forSectionID: snapshot.sectionID, in: snapshot.presentationID)
        #expect(attempts.count == 1)
    }

    @Test("TakeAudioPlayer loads synthetic audio, seeks to marker timestamps, and pauses on interruption")
    func audioPlayerPlaysSeeksAndHandlesInterruption() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SessionTest")
        defer { workspace.cleanup() }

        let audioURL = workspace.storageRoot.appendingPathComponent("Takes/sample.wav")
        try SyntheticAudioRecorderController.writeToneWAV(to: audioURL, durationSeconds: 2.0)

        let player = TakeAudioPlayer(audioSessionManager: FakeAudioSessionManager())
        player.load(url: audioURL)
        #expect(player.isLoaded)
        #expect(player.duration > 1.8)
        #expect(player.errorMessage == nil)

        player.seek(to: 1.25)
        #expect(abs(player.currentTime - 1.25) < 0.05)

        // Clamp out-of-range seeks safely
        player.seek(to: 99.0)
        #expect(player.currentTime <= player.duration)
        player.seek(to: -5.0)
        #expect(player.currentTime == 0)

        player.play()
        #expect(player.isPlaying)
        player.handleAudioInterruptionBegan()
        #expect(!player.isPlaying)
        player.stop()
        #expect(!player.isLoaded)
    }

    @Test("Deleting a presentation removes only its attempts and audio while keeping other talks intact")
    func deletingPresentationOnlyDeletesItsOwnAudio() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SessionTest")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attempts = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        let talkA = try library.importScript(text: "Talk A opening line.", title: "Talk A")
        let talkB = try library.importScript(text: "Talk B opening line.", title: "Talk B")
        let revA = try #require(library.currentTalkRevision(for: talkA))
        let revB = try #require(library.currentTalkRevision(for: talkB))
        let secA = try #require(library.orderedSections(in: revA).first)
        let secB = try #require(library.orderedSections(in: revB).first)

        let snapA = AttemptSnapshotReference(
            presentationID: talkA.id,
            talkRevisionID: revA.id,
            talkRevisionNumber: revA.revisionNumber,
            sectionID: secA.sectionID,
            sectionRevisionID: secA.revisionID,
            sectionTitle: secA.title
        )
        let snapB = AttemptSnapshotReference(
            presentationID: talkB.id,
            talkRevisionID: revB.id,
            talkRevisionNumber: revB.revisionNumber,
            sectionID: secB.sectionID,
            sectionRevisionID: secB.revisionID,
            sectionTitle: secB.title
        )

        let attA = try attempts.beginAttempt(snapshot: snapA, practiceMode: .fullScript, isSilentRecall: false)
        let attB = try attempts.beginAttempt(snapshot: snapB, practiceMode: .fullScript, isSilentRecall: false)
        let urlA = try attempts.resolvedAudioURL(for: try #require(attA.relativeAudioPath))
        let urlB = try attempts.resolvedAudioURL(for: try #require(attB.relativeAudioPath))
        try SyntheticAudioRecorderController.writeToneWAV(to: urlA, durationSeconds: 1.0)
        try SyntheticAudioRecorderController.writeToneWAV(to: urlB, durationSeconds: 1.0)

        try attempts.deletePresentationAndAttempts(talkA)

        #expect(!FileManager.default.fileExists(atPath: urlA.path))
        #expect(FileManager.default.fileExists(atPath: urlB.path))
        #expect(try attempts.attempt(withID: attA.id) == nil)
        #expect(try attempts.attempt(withID: attB.id) != nil)
    }
}
