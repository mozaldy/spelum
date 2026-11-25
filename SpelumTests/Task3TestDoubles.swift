import AVFoundation
import Foundation
@testable import Spelum

@MainActor
final class ControlledMicrophonePermissionProvider: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus
    private var pendingContinuations: [CheckedContinuation<Bool, Never>] = []
    private(set) var requestCount = 0

    init(status: MicrophonePermissionStatus = .undetermined) {
        self.status = status
    }

    func currentStatus() -> MicrophonePermissionStatus { status }

    func requestAccess() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    var pendingRequestCount: Int { pendingContinuations.count }

    func resolveOldest(granted: Bool, updateStatus: Bool = true) {
        guard !pendingContinuations.isEmpty else { return }
        if updateStatus {
            status = granted ? .granted : .denied
        }
        let continuation = pendingContinuations.removeFirst()
        continuation.resume(returning: granted)
    }

    func resolveNewest(granted: Bool, updateStatus: Bool = true) {
        guard !pendingContinuations.isEmpty else { return }
        if updateStatus {
            status = granted ? .granted : .denied
        }
        let continuation = pendingContinuations.removeLast()
        continuation.resume(returning: granted)
    }
}

@MainActor
final class TrackingAudioSessionManager: AudioSessionManaging {
    private(set) var recordingActivations = 0
    private(set) var playbackActivations = 0
    private(set) var deactivations = 0

    func activateForRecording() throws { recordingActivations += 1 }
    func activateForPlayback() throws { playbackActivations += 1 }
    func deactivate() { deactivations += 1 }
}

@MainActor
final class TrackingAudioRecorderController: AudioRecorderControlling {
    var currentTime: TimeInterval = 0
    var isRecording = false
    var onUnexpectedFinish: ((Bool) -> Void)?
    var onEncodeError: ((Error?) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    var syntheticDuration: TimeInterval = 1.2

    func startRecording(to url: URL) throws {
        startCount += 1
        isRecording = true
        currentTime = syntheticDuration
        try PracticeTestFixtures.writeSyntheticAACM4A(to: url, durationSeconds: syntheticDuration)
    }

    func stopRecording() {
        stopCount += 1
        isRecording = false
    }
}

final class DeterministicStubAudioRecorder: AVAudioRecorder {
    private var recordingFlag = false
    private(set) var stopCallCount = 0

    override var isRecording: Bool { recordingFlag }

    override func prepareToRecord() -> Bool { true }

    override func record() -> Bool {
        recordingFlag = true
        return true
    }

    override func stop() {
        stopCallCount += 1
        recordingFlag = false
    }
}

@MainActor
enum Task3ManifestTestHelper {
    static func makeManifest(
        attemptID: UUID = UUID(),
        snapshot: AttemptSnapshotReference,
        mode: PracticeMode = .cueWords,
        relativeAudioPath: String? = nil,
        elapsedDuration: TimeInterval = 1.2,
        revealCount: Int = 0,
        isSilentRecall: Bool = false
    ) -> PendingSaveManifest {
        PendingSaveManifest(
            attemptID: attemptID,
            snapshot: snapshot,
            practiceMode: mode,
            startedAt: Date().addingTimeInterval(-3),
            finishedAt: Date(),
            relativeAudioPath: relativeAudioPath,
            elapsedDuration: elapsedDuration,
            revealCount: revealCount,
            markers: [],
            isSilentRecall: isSilentRecall,
            interrupted: false,
            interruptionReason: nil
        )
    }

    static func manifestURL(in workspace: PracticeTestWorkspace, attemptID: UUID) -> URL {
        workspace.storageRoot
            .appendingPathComponent(AttemptStore.pendingSavesSubdirectoryName)
            .appendingPathComponent("\(attemptID.uuidString.lowercased()).json")
    }
}
