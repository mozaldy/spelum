import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class RecordingSession {
    let attemptStore: AttemptStore
    let permissionProvider: any MicrophonePermissionProviding
    let audioSessionManager: any AudioSessionManaging
    let recorder: any AudioRecorderControlling
    let interruptionMonitor: AudioInterruptionMonitor
    let nowProvider: () -> Date

    var phase: RecordingSessionPhase = .idle
    var permissionStatus: MicrophonePermissionStatus
    var practiceMode: PracticeMode
    var snapshot: AttemptSnapshotReference
    var fullRunSnapshot: FullRunSnapshot?
    var fullRunTransitions: [FullRunSectionTransition] = []
    var currentFullRunSectionIndex = 0
    var currentFullRunSlideIndex = 0
    var isScriptRevealed = false
    var revealCount = 0
    var markers: [AttemptMarker] = []
    var elapsedDuration: TimeInterval = 0
    var activeAttemptID: UUID?
    var microphoneDeniedNoticeVisible = false

    var activeRelativeAudioPath: String?
    var activeStartedAt: Date?
    var activeCaptureStartedAt: Date?
    var lastMonotonicAudioTime: TimeInterval = 0
    var hasObservedRecorderTime = false
    var elapsedTimer: Timer?
    var activePermissionRequestID: UUID?

    init(
        attemptStore: AttemptStore,
        snapshot: AttemptSnapshotReference,
        initialMode: PracticeMode = .fullScript,
        fullRunSnapshot: FullRunSnapshot? = nil,
        permissionProvider: (any MicrophonePermissionProviding)? = nil,
        audioSessionManager: (any AudioSessionManaging)? = nil,
        recorder: (any AudioRecorderControlling)? = nil,
        notificationCenter: NotificationCenter = .default,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        let resolvedPermission = permissionProvider ?? SystemMicrophonePermissionProvider()
        self.attemptStore = attemptStore
        self.fullRunSnapshot = fullRunSnapshot
        self.snapshot = fullRunSnapshot?.makeAttemptSnapshotReference() ?? snapshot
        self.practiceMode = initialMode
        self.permissionProvider = resolvedPermission
        self.audioSessionManager = audioSessionManager ?? SystemAudioSessionManager()
        self.recorder = recorder ?? AVAudioRecorderController()
        self.interruptionMonitor = AudioInterruptionMonitor(notificationCenter: notificationCenter)
        self.nowProvider = nowProvider
        self.permissionStatus = resolvedPermission.currentStatus()
    }

    convenience init(
        attemptStore: AttemptStore,
        fullRunSnapshot: FullRunSnapshot,
        initialMode: PracticeMode = .cueWords,
        permissionProvider: (any MicrophonePermissionProviding)? = nil,
        audioSessionManager: (any AudioSessionManaging)? = nil,
        recorder: (any AudioRecorderControlling)? = nil,
        notificationCenter: NotificationCenter = .default,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.init(
            attemptStore: attemptStore,
            snapshot: fullRunSnapshot.makeAttemptSnapshotReference(),
            initialMode: initialMode,
            fullRunSnapshot: fullRunSnapshot,
            permissionProvider: permissionProvider,
            audioSessionManager: audioSessionManager,
            recorder: recorder,
            notificationCenter: notificationCenter,
            nowProvider: nowProvider
        )
    }

    var isActiveTake: Bool {
        phase == .recording || phase == .silentRecall
    }

    var canChangePracticeMode: Bool {
        !isActiveTake && phase != .finalizing && phase != .requestingPermission
    }

    var canStartNewTake: Bool {
        switch phase {
        case .idle, .completed, .interrupted, .error:
            true
        case .requestingPermission, .recording, .silentRecall, .finalizing, .saveFailed:
            false
        }
    }

    func refreshPermissionStatus() {
        permissionStatus = permissionProvider.currentStatus()
        if permissionStatus == .granted {
            microphoneDeniedNoticeVisible = false
        }
    }

    func selectPracticeMode(_ mode: PracticeMode) {
        guard canChangePracticeMode else { return }
        practiceMode = mode
        isScriptRevealed = false
    }

    func activateReveal() {
        guard practiceMode.supportsReveal, !isScriptRevealed else { return }
        isScriptRevealed = true
        if isActiveTake {
            revealCount += 1
            if isFullRunSession {
                checkpointInProgressFullRunState(wasSilentRecall: phase == .silentRecall)
            }
        }
    }

    func hideScript() {
        isScriptRevealed = false
    }

    func toggleReveal() {
        if isScriptRevealed {
            hideScript()
        } else {
            activateReveal()
        }
    }

    func addManualMarker(label: String? = nil) {
        guard isActiveTake else { return }
        updateElapsedDuration()
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultLabel: String
        if let currentSection = currentFullRunSection {
            defaultLabel = "Marker \(markers.count + 1) (\(currentSection.title))"
        } else {
            defaultLabel = "Marker \(markers.count + 1)"
        }
        let resolvedLabel = (trimmed?.isEmpty == false) ? (trimmed ?? defaultLabel) : defaultLabel
        let marker = AttemptMarker(
            timestamp: elapsedDuration,
            label: resolvedLabel,
            createdAt: nowProvider()
        )
        markers.append(marker)
        if isFullRunSession {
            checkpointInProgressFullRunState(wasSilentRecall: phase == .silentRecall)
        }
    }

    func cancelPendingStart() {
        activePermissionRequestID = nil
        if phase == .requestingPermission {
            phase = .idle
        }
    }

    func startRecording() async {
        guard canStartNewTake, !Task.isCancelled else { return }

        let status = permissionProvider.currentStatus()
        permissionStatus = status
        if status == .undetermined {
            let requestID = UUID()
            activePermissionRequestID = requestID
            phase = .requestingPermission
            let granted = await withTaskCancellationHandler {
                await permissionProvider.requestAccess()
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.invalidatePendingStart(matching: requestID)
                }
            }

            guard !Task.isCancelled,
                  activePermissionRequestID == requestID,
                  phase == .requestingPermission else {
                invalidatePendingStart(matching: requestID)
                return
            }
            activePermissionRequestID = nil
            permissionStatus = granted ? .granted : .denied
            guard granted else {
                phase = .idle
                microphoneDeniedNoticeVisible = true
                return
            }
        } else if status == .denied {
            microphoneDeniedNoticeVisible = true
            phase = .idle
            return
        }

        guard !Task.isCancelled else { return }
        beginAudioCapture()
    }

    func startSilentRecall() {
        guard canStartNewTake else { return }
        resetTakeCounters()
        let startedAt = nowProvider()
        seedInitialFullRunTransitionIfNeeded(startedAt: startedAt)
        activeAttemptID = UUID()
        activeRelativeAudioPath = nil
        activeStartedAt = startedAt
        activeCaptureStartedAt = startedAt
        phase = .silentRecall
        startElapsedTimer()
    }

    @discardableResult
    func stopRecording() -> AttemptRecord? {
        finishActiveTake(interrupted: false, interruptionReason: nil)
    }

    func handleInterruption(reason: String = "Recording was interrupted by the system.") {
        _ = finishActiveTake(interrupted: true, interruptionReason: reason)
    }
}
