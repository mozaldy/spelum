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

final class WeakObjectBox<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?

    init(_ value: Object) {
        self.value = value
    }
}

@MainActor
final class AVAudioRecorderController: NSObject, AudioRecorderControlling {
    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    private let recorderFactory: (URL, [String: Any]) throws -> AVAudioRecorder
    private var recorder: AVAudioRecorder?

    var onUnexpectedFinish: ((Bool) -> Void)?
    var onEncodeError: ((Error?) -> Void)?

    init(
        recorderFactory: @escaping (URL, [String: Any]) throws -> AVAudioRecorder = {
            try AVAudioRecorder(url: $0, settings: $1)
        }
    ) {
        self.recorderFactory = recorderFactory
        super.init()
    }

    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    func startRecording(to url: URL) throws {
        stopRecording()
        let newRecorder = try recorderFactory(url, Self.recordingSettings)
        newRecorder.delegate = self
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            newRecorder.delegate = nil
            throw RecordingSessionError.recorderStartFailed
        }
        recorder = newRecorder
    }

    func stopRecording() {
        guard let current = recorder else { return }
        recorder = nil
        current.delegate = nil
        current.stop()
    }
}

extension AVAudioRecorderController: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let senderBox = WeakObjectBox(recorder)
        Task { @MainActor [weak self] in
            guard let self,
                  let activeRecorder = self.recorder,
                  let sender = senderBox.value,
                  activeRecorder === sender else {
                return
            }
            self.recorder = nil
            activeRecorder.delegate = nil
            self.onUnexpectedFinish?(flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let senderBox = WeakObjectBox(recorder)
        Task { @MainActor [weak self] in
            guard let self,
                  let activeRecorder = self.recorder,
                  let sender = senderBox.value,
                  activeRecorder === sender else {
                return
            }
            self.recorder = nil
            activeRecorder.delegate = nil
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
    let attemptKind: AttemptKind
    let fullRunPayload: FullRunAttemptPayload?
    let errorMessage: String
    let discardErrorMessage: String?

    init(
        input: AttemptFinalizationInput,
        playableDuration: TimeInterval,
        errorMessage: String,
        discardErrorMessage: String? = nil
    ) {
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
        self.attemptKind = input.attemptKind
        self.fullRunPayload = input.fullRunPayload
        self.errorMessage = errorMessage
        self.discardErrorMessage = discardErrorMessage
    }

    private init(
        attemptID: UUID,
        snapshot: AttemptSnapshotReference,
        practiceMode: PracticeMode,
        startedAt: Date,
        finishedAt: Date,
        relativeAudioPath: String?,
        playableDuration: TimeInterval,
        elapsedDuration: TimeInterval,
        revealCount: Int,
        markers: [AttemptMarker],
        isSilentRecall: Bool,
        interrupted: Bool,
        interruptionReason: String?,
        attemptKind: AttemptKind,
        fullRunPayload: FullRunAttemptPayload?,
        errorMessage: String,
        discardErrorMessage: String?
    ) {
        self.attemptID = attemptID
        self.snapshot = snapshot
        self.practiceMode = practiceMode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.relativeAudioPath = relativeAudioPath
        self.playableDuration = playableDuration
        self.elapsedDuration = elapsedDuration
        self.revealCount = revealCount
        self.markers = markers
        self.isSilentRecall = isSilentRecall
        self.interrupted = interrupted
        self.interruptionReason = interruptionReason
        self.attemptKind = attemptKind
        self.fullRunPayload = fullRunPayload
        self.errorMessage = errorMessage
        self.discardErrorMessage = discardErrorMessage
    }

    var hasPlayableAudio: Bool {
        relativeAudioPath != nil && playableDuration > 0
    }

    func withDiscardError(_ message: String?) -> PendingSaveRecovery {
        PendingSaveRecovery(
            attemptID: attemptID,
            snapshot: snapshot,
            practiceMode: practiceMode,
            startedAt: startedAt,
            finishedAt: finishedAt,
            relativeAudioPath: relativeAudioPath,
            playableDuration: playableDuration,
            elapsedDuration: elapsedDuration,
            revealCount: revealCount,
            markers: markers,
            isSilentRecall: isSilentRecall,
            interrupted: interrupted,
            interruptionReason: interruptionReason,
            attemptKind: attemptKind,
            fullRunPayload: fullRunPayload,
            errorMessage: errorMessage,
            discardErrorMessage: message
        )
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
    private var generation: UInt64 = 0

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func start(onInterrupted: @escaping @MainActor (String) -> Void) {
        stop()
        generation &+= 1
        let activeGeneration = generation

        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      self.generation == activeGeneration,
                      let typeValue,
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
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                onInterrupted("Audio services reset during recording.")
            }
        }
    }

    func stop() {
        generation &+= 1
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
