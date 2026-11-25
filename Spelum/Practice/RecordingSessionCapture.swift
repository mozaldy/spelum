import AVFoundation
import Foundation

extension RecordingSession {
    func invalidatePendingStart(matching requestID: UUID) {
        guard activePermissionRequestID == requestID else { return }
        activePermissionRequestID = nil
        if phase == .requestingPermission {
            phase = .idle
        }
    }

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
            installRecorderCallbacks(for: attemptID)
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

    func installRecorderCallbacks(for attemptID: UUID) {
        recorder.onUnexpectedFinish = { [weak self] successfully in
            guard let self, self.activeAttemptID == attemptID, self.phase == .recording else { return }
            let reason = successfully
                ? "Recording finished unexpectedly."
                : "Audio recording ended before completion."
            self.handleInterruption(reason: reason)
        }
        recorder.onEncodeError = { [weak self] error in
            guard let self, self.activeAttemptID == attemptID, self.phase == .recording else { return }
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
