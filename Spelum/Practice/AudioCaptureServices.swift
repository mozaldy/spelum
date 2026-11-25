import AVFoundation
import Foundation

enum MicrophonePermissionStatus: Equatable, Sendable {
    case undetermined
    case granted
    case denied
}

@MainActor
protocol MicrophonePermissionProviding {
    func currentStatus() -> MicrophonePermissionStatus
    func requestAccess() async -> Bool
}

@MainActor
struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    func currentStatus() -> MicrophonePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .undetermined
        case .granted: .granted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

@MainActor
protocol AudioSessionManaging {
    func activateForRecording() throws
    func activateForPlayback() throws
    func deactivate()
}

@MainActor
struct SystemAudioSessionManager: AudioSessionManaging {
    func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
protocol AudioRecorderControlling: AnyObject {
    var currentTime: TimeInterval { get }
    var isRecording: Bool { get }
    var onUnexpectedFinish: ((Bool) -> Void)? { get set }
    var onEncodeError: ((Error?) -> Void)? { get set }
    func startRecording(to url: URL) throws
    func stopRecording()
}

enum RecordingSessionError: LocalizedError, Equatable, Sendable {
    case recorderStartFailed

    var errorDescription: String? {
        switch self {
        case .recorderStartFailed:
            "Spelum could not start the audio recorder. Try again or use silent recall."
        }
    }
}

@MainActor
final class AVAudioRecorderController: NSObject, AudioRecorderControlling {
    private var recorder: AVAudioRecorder?
    private var isStoppingIntentionally = false

    var onUnexpectedFinish: ((Bool) -> Void)?
    var onEncodeError: ((Error?) -> Void)?

    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    func startRecording(to url: URL) throws {
        isStoppingIntentionally = false
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.delegate = self
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            throw RecordingSessionError.recorderStartFailed
        }
        recorder = newRecorder
    }

    func stopRecording() {
        isStoppingIntentionally = true
        recorder?.stop()
        recorder = nil
    }
}

extension AVAudioRecorderController: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !self.isStoppingIntentionally else { return }
            self.recorder = nil
            self.onUnexpectedFinish?(flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recorder = nil
            self.onEncodeError?(error)
        }
    }
}

struct PendingSaveRecovery: Equatable, Sendable {
    let attemptID: UUID
    let snapshot: AttemptSnapshotReference
    let practiceMode: PracticeMode
    let startedAt: Date
    let finishedAt: Date
    let relativeAudioPath: String?
    let playableDuration: TimeInterval
    let elapsedDuration: TimeInterval
    let revealCount: Int
    let markers: [AttemptMarker]
    let isSilentRecall: Bool
    let interrupted: Bool
    let interruptionReason: String?
    let errorMessage: String

    init(input: AttemptFinalizationInput, playableDuration: TimeInterval, errorMessage: String) {
        self.attemptID = input.id
        self.snapshot = input.snapshot
        self.practiceMode = input.practiceMode
        self.startedAt = input.startedAt
        self.finishedAt = input.finishedAt
        self.relativeAudioPath = input.relativeAudioPath
        self.playableDuration = playableDuration
        self.elapsedDuration = input.elapsedDuration
        self.revealCount = input.revealCount
        self.markers = input.markers
        self.isSilentRecall = input.isSilentRecall
        self.interrupted = input.interrupted
        self.interruptionReason = input.interruptionReason
        self.errorMessage = errorMessage
    }

    var hasPlayableAudio: Bool {
        relativeAudioPath != nil && playableDuration > 0
    }
}

enum RecordingSessionPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case silentRecall
    case finalizing
    case completed(UUID)
    case interrupted(attemptID: UUID, hasPlayableAudio: Bool, reason: String)
    case saveFailed(PendingSaveRecovery)
    case error(String)
}

@MainActor
final class AudioInterruptionMonitor {
    private let notificationCenter: NotificationCenter
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func start(onInterrupted: @escaping @MainActor (String) -> Void) {
        stop()
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                      type == .began else {
                    return
                }
                onInterrupted("Recording was interrupted by another audio event.")
            }
        }
        mediaResetObserver = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onInterrupted("Audio services reset during recording.")
            }
        }
    }

    func stop() {
        if let interruptionObserver {
            notificationCenter.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let mediaResetObserver {
            notificationCenter.removeObserver(mediaResetObserver)
            self.mediaResetObserver = nil
        }
    }
}
