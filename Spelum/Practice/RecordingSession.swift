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
    var isScriptRevealed = false
    var revealCount = 0
    var markers: [AttemptMarker] = []
    var elapsedDuration: TimeInterval = 0
    var activeAttemptID: UUID?
    var microphoneDeniedNoticeVisible = false

    var activeRelativeAudioPath: String?
    var activeStartedAt: Date?
    var elapsedTimer: Timer?
    var activePermissionRequestID: UUID?

    init(
        attemptStore: AttemptStore,
        snapshot: AttemptSnapshotReference,
        initialMode: PracticeMode = .fullScript,
        permissionProvider: (any MicrophonePermissionProviding)? = nil,
        audioSessionManager: (any AudioSessionManaging)? = nil,
        recorder: (any AudioRecorderControlling)? = nil,
        notificationCenter: NotificationCenter = .default,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        let resolvedPermission = permissionProvider ?? SystemMicrophonePermissionProvider()
        self.attemptStore = attemptStore
        self.snapshot = snapshot
        self.practiceMode = initialMode
        self.permissionProvider = resolvedPermission
        self.audioSessionManager = audioSessionManager ?? SystemAudioSessionManager()
        self.recorder = recorder ?? AVAudioRecorderController()
        self.interruptionMonitor = AudioInterruptionMonitor(notificationCenter: notificationCenter)
        self.nowProvider = nowProvider
        self.permissionStatus = resolvedPermission.currentStatus()
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
        let resolvedLabel = (trimmed?.isEmpty == false) ? trimmed ?? "" : "Marker \(markers.count + 1)"
        let marker = AttemptMarker(
            timestamp: elapsedDuration,
            label: resolvedLabel,
            createdAt: nowProvider()
        )
        markers.append(marker)
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
        activeAttemptID = UUID()
        activeRelativeAudioPath = nil
        activeStartedAt = nowProvider()
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

    @discardableResult
    func retryFailedSave() -> AttemptRecord? {
        guard case .saveFailed(let recovery) = phase else { return nil }
        phase = .finalizing
        let input = AttemptFinalizationInput(
            id: recovery.attemptID,
            snapshot: recovery.snapshot,
            practiceMode: recovery.practiceMode,
            startedAt: recovery.startedAt,
            finishedAt: recovery.finishedAt,
            relativeAudioPath: recovery.relativeAudioPath,
            elapsedDuration: recovery.elapsedDuration,
            revealCount: recovery.revealCount,
            markers: recovery.markers,
            isSilentRecall: recovery.isSilentRecall,
            interrupted: recovery.interrupted,
            interruptionReason: recovery.interruptionReason
        )
        return persistFinalization(input)
    }

    @discardableResult
    func discardFailedSave() -> Bool {
        guard case .saveFailed(let recovery) = phase else { return false }
        do {
            try attemptStore.discardUnpersistedAudio(
                for: recovery.attemptID,
                relativeAudioPath: recovery.relativeAudioPath
            )
            phase = .idle
            return true
        } catch {
            phase = .saveFailed(recovery.withDiscardError(error.localizedDescription))
            return false
        }
    }

    func prepareForRetry(
        snapshot: AttemptSnapshotReference? = nil,
        practiceMode: PracticeMode? = nil
    ) {
        guard !isActiveTake, phase != .finalizing else { return }
        cancelPendingStart()
        if let snapshot { self.snapshot = snapshot }
        if let practiceMode { self.practiceMode = practiceMode }
        resetTakeCounters()
        clearActiveState()
        phase = .idle
    }

    func clearDeletedAttemptReference(_ deletedAttemptID: UUID) {
        switch phase {
        case .interrupted(let attemptID, _, _) where attemptID == deletedAttemptID:
            phase = .idle
        case .completed(let attemptID) where attemptID == deletedAttemptID:
            phase = .idle
        default:
            break
        }
    }

    func reconcileReferencedAttempt() {
        let referencedID: UUID?
        switch phase {
        case .interrupted(let attemptID, _, _):
            referencedID = attemptID
        case .completed(let attemptID):
            referencedID = attemptID
        default:
            referencedID = nil
        }
        guard let referencedID else { return }
        do {
            if try attemptStore.attempt(withID: referencedID) == nil {
                phase = .idle
            }
        } catch {
            // Preserve current phase if lookup fails.
        }
    }

    func handleViewDisappear() {
        if isActiveTake {
            handleInterruption(reason: "Recording stopped when leaving practice.")
        } else {
            cancelPendingStart()
            stopTimersAndObservers()
        }
    }
}
