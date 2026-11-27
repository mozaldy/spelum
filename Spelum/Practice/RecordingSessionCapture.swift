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
        seedInitialFullRunTransitionIfNeeded(startedAt: startedAt)
        let initialPayload = makeCurrentFullRunPayload(
            finalDuration: 0,
            interrupted: true,
            isSilentRecall: false
        )

        do {
            try audioSessionManager.activateForRecording()
            let pending = try attemptStore.beginAttempt(
                snapshot: snapshot,
                practiceMode: practiceMode,
                isSilentRecall: false,
                startedAt: startedAt,
                attemptID: attemptID,
                attemptKind: isFullRunSession ? .fullRun : .section,
                fullRunPayload: initialPayload
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
            activeCaptureStartedAt = nowProvider()
            phase = .recording
            startElapsedTimer()
        } catch {
            stopTimersAndObservers()
            audioSessionManager.deactivate()
            try? attemptStore.deleteAttempt(id: attemptID)
            clearActiveState()
            fullRunTransitions = []
            currentFullRunSectionIndex = 0
            currentFullRunSlideIndex = 0
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
        let payload = makeCurrentFullRunPayload(
            finalDuration: elapsed,
            interrupted: interrupted,
            isSilentRecall: isSilentRecall
        )

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
            interruptionReason: interruptionReason,
            attemptKind: isFullRunSession ? .fullRun : .section,
            fullRunPayload: payload
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
        lastMonotonicAudioTime = 0
        hasObservedRecorderTime = false
        fullRunTransitions = []
        currentFullRunSectionIndex = 0
        currentFullRunSlideIndex = 0
    }

    func clearActiveState() {
        activeAttemptID = nil
        activeRelativeAudioPath = nil
        activeStartedAt = nil
        activeCaptureStartedAt = nil
    }

    func resolvedElapsedDuration(wasSilentRecall: Bool) -> TimeInterval {
        let referenceStart = activeCaptureStartedAt ?? activeStartedAt
        let wallElapsed = referenceStart.map { max(0, nowProvider().timeIntervalSince($0)) } ?? elapsedDuration
        if wasSilentRecall {
            lastMonotonicAudioTime = max(lastMonotonicAudioTime, wallElapsed)
            return lastMonotonicAudioTime
        }
        let rawRecorderTime = recorder.currentTime
        if rawRecorderTime.isFinite && rawRecorderTime > 0 {
            hasObservedRecorderTime = true
            lastMonotonicAudioTime = max(lastMonotonicAudioTime, rawRecorderTime)
            return lastMonotonicAudioTime
        }
        if hasObservedRecorderTime {
            return lastMonotonicAudioTime
        }
        lastMonotonicAudioTime = max(lastMonotonicAudioTime, wallElapsed)
        return lastMonotonicAudioTime
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

extension RecordingSession {
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
            interruptionReason: recovery.interruptionReason,
            attemptKind: recovery.attemptKind,
            fullRunPayload: recovery.fullRunPayload
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
            let reason = isFullRunSession
                ? "Full run stopped when leaving rehearsal."
                : "Recording stopped when leaving practice."
            handleInterruption(reason: reason)
        } else {
            cancelPendingStart()
            stopTimersAndObservers()
        }
    }
}
