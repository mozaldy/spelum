import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class RecordingSession {
    private let attemptStore: AttemptStore
    private let permissionProvider: any MicrophonePermissionProviding
    private let audioSessionManager: any AudioSessionManaging
    private let recorder: any AudioRecorderControlling
    private let interruptionMonitor: AudioInterruptionMonitor
    private let nowProvider: () -> Date

    private(set) var phase: RecordingSessionPhase = .idle
    private(set) var permissionStatus: MicrophonePermissionStatus
    private(set) var practiceMode: PracticeMode
    private(set) var snapshot: AttemptSnapshotReference
    private(set) var isScriptRevealed = false
    private(set) var revealCount = 0
    private(set) var markers: [AttemptMarker] = []
    private(set) var elapsedDuration: TimeInterval = 0
    private(set) var activeAttemptID: UUID?
    private(set) var microphoneDeniedNoticeVisible = false

    private var activeRelativeAudioPath: String?
    private var activeStartedAt: Date?
    private var elapsedTimer: Timer?

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

    func startRecording() async {
        guard canStartNewTake else { return }

        let status = permissionProvider.currentStatus()
        permissionStatus = status
        if status == .undetermined {
            phase = .requestingPermission
            let granted = await permissionProvider.requestAccess()
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

    func discardFailedSave() {
        guard case .saveFailed(let recovery) = phase else { return }
        attemptStore.discardUnpersistedAudio(
            for: recovery.attemptID,
            relativeAudioPath: recovery.relativeAudioPath
        )
        phase = .idle
    }

    func prepareForRetry(
        snapshot: AttemptSnapshotReference? = nil,
        practiceMode: PracticeMode? = nil
    ) {
        guard !isActiveTake, phase != .finalizing, phase != .requestingPermission else { return }
        if let snapshot { self.snapshot = snapshot }
        if let practiceMode { self.practiceMode = practiceMode }
        resetTakeCounters()
        clearActiveState()
        phase = .idle
    }

    func handleViewDisappear() {
        if isActiveTake {
            handleInterruption(reason: "Recording stopped when leaving practice.")
        } else {
            stopTimersAndObservers()
        }
    }
}

private extension RecordingSession {
    func finishActiveTake(interrupted: Bool, interruptionReason: String?) -> AttemptRecord? {
        guard isActiveTake else { return nil }
        let wasSilentRecall = phase == .silentRecall
        phase = .finalizing
        stopTimersAndObservers()

        let finalElapsed = resolvedElapsedDuration(wasSilentRecall: wasSilentRecall)
        if !wasSilentRecall {
            recorder.stopRecording()
            audioSessionManager.deactivate()
        }
        return finalizeActiveTake(
            isSilentRecall: wasSilentRecall,
            elapsed: finalElapsed,
            interrupted: interrupted,
            interruptionReason: interruptionReason
        )
    }

    func beginAudioCapture() {
        resetTakeCounters()
        microphoneDeniedNoticeVisible = false

        let attemptID = UUID()
        let startedAt = nowProvider()

        do {
            try audioSessionManager.activateForRecording()
            let pending = try attemptStore.beginAttempt(
                snapshot: snapshot,
                practiceMode: practiceMode,
                isSilentRecall: false,
                startedAt: startedAt,
                attemptID: attemptID
            )
            guard let relativePath = pending.relativeAudioPath else {
                throw AttemptStoreError.invalidRelativeAudioPath
            }
            let audioURL = try attemptStore.resolvedAudioURL(for: relativePath)
            installRecorderCallbacks()
            installInterruptionObservers()
            try recorder.startRecording(to: audioURL)

            activeAttemptID = attemptID
            activeRelativeAudioPath = relativePath
            activeStartedAt = startedAt
            phase = .recording
            startElapsedTimer()
        } catch {
            stopTimersAndObservers()
            audioSessionManager.deactivate()
            try? attemptStore.deleteAttempt(id: attemptID)
            clearActiveState()
            phase = .error(error.localizedDescription)
        }
    }

    func finalizeActiveTake(
        isSilentRecall: Bool,
        elapsed: TimeInterval,
        interrupted: Bool,
        interruptionReason: String?
    ) -> AttemptRecord? {
        let attemptID = activeAttemptID ?? UUID()
        let startedAt = activeStartedAt ?? nowProvider()
        let relativePath = activeRelativeAudioPath
        let finishedAt = nowProvider()

        let input = AttemptFinalizationInput(
            id: attemptID,
            snapshot: snapshot,
            practiceMode: practiceMode,
            startedAt: startedAt,
            finishedAt: finishedAt,
            relativeAudioPath: relativePath,
            elapsedDuration: elapsed,
            revealCount: revealCount,
            markers: markers,
            isSilentRecall: isSilentRecall,
            interrupted: interrupted,
            interruptionReason: interruptionReason
        )
        return persistFinalization(input)
    }

    func persistFinalization(_ input: AttemptFinalizationInput) -> AttemptRecord? {
        do {
            let saved = try attemptStore.finalizeAttempt(input)
            clearActiveState()
            if saved.status == .interrupted {
                phase = .interrupted(
                    attemptID: saved.id,
                    hasPlayableAudio: saved.hasPlayableAudio,
                    reason: saved.interruptionReason ?? "Recording was interrupted."
                )
            } else {
                phase = .completed(saved.id)
            }
            return saved
        } catch {
            clearActiveState()
            let playable = attemptStore.playableDuration(forRelativePath: input.relativeAudioPath) ?? 0
            let recovery = PendingSaveRecovery(
                input: input,
                playableDuration: playable,
                errorMessage: error.localizedDescription
            )
            phase = .saveFailed(recovery)
            return nil
        }
    }

    func resetTakeCounters() {
        isScriptRevealed = false
        revealCount = 0
        markers = []
        elapsedDuration = 0
    }

    func clearActiveState() {
        activeAttemptID = nil
        activeRelativeAudioPath = nil
        activeStartedAt = nil
    }

    func resolvedElapsedDuration(wasSilentRecall: Bool) -> TimeInterval {
        let wallElapsed = activeStartedAt.map { max(0, nowProvider().timeIntervalSince($0)) } ?? elapsedDuration
        if wasSilentRecall {
            return max(elapsedDuration, wallElapsed)
        }
        return max(recorder.currentTime, max(elapsedDuration, wallElapsed))
    }

    func updateElapsedDuration() {
        guard isActiveTake else { return }
        elapsedDuration = resolvedElapsedDuration(wasSilentRecall: phase == .silentRecall)
    }

    func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateElapsedDuration()
            }
        }
    }

    func installRecorderCallbacks() {
        recorder.onUnexpectedFinish = { [weak self] successfully in
            guard let self else { return }
            let reason = successfully
                ? "Recording finished unexpectedly."
                : "Audio recording ended before completion."
            self.handleInterruption(reason: reason)
        }
        recorder.onEncodeError = { [weak self] error in
            guard let self else { return }
            let reason = error?.localizedDescription ?? "An audio encoding error interrupted this recording."
            self.handleInterruption(reason: reason)
        }
    }

    func installInterruptionObservers() {
        interruptionMonitor.start { [weak self] reason in
            self?.handleInterruption(reason: reason)
        }
    }

    func stopTimersAndObservers() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recorder.onUnexpectedFinish = nil
        recorder.onEncodeError = nil
        interruptionMonitor.stop()
    }
}
