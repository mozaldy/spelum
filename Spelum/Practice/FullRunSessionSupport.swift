import Foundation

extension RecordingSession {
    var isFullRunSession: Bool {
        fullRunSnapshot != nil
    }

    var currentFullRunSection: FullRunSectionSnapshot? {
        guard let fullRunSnapshot,
              fullRunSnapshot.sections.indices.contains(currentFullRunSectionIndex) else {
            return nil
        }
        return fullRunSnapshot.sections[currentFullRunSectionIndex]
    }

    var nextFullRunSection: FullRunSectionSnapshot? {
        guard let fullRunSnapshot else { return nil }
        let nextIndex = currentFullRunSectionIndex + 1
        guard fullRunSnapshot.sections.indices.contains(nextIndex) else { return nil }
        return fullRunSnapshot.sections[nextIndex]
    }

    var currentFullRunSlides: [ResolvedRehearsalSlide] {
        guard let section = currentFullRunSection else { return [] }
        return RehearsalSlideResolver.resolveSlides(for: section)
    }

    var currentFullRunSlide: ResolvedRehearsalSlide? {
        let slides = currentFullRunSlides
        guard !slides.isEmpty else { return nil }
        let clamped = min(max(currentFullRunSlideIndex, 0), slides.count - 1)
        return slides[clamped]
    }

    var nextSlideInCurrentSection: ResolvedRehearsalSlide? {
        let slides = currentFullRunSlides
        let nextIndex = currentFullRunSlideIndex + 1
        guard slides.indices.contains(nextIndex) else { return nil }
        return slides[nextIndex]
    }

    var hasNextSlideInCurrentSection: Bool {
        nextSlideInCurrentSection != nil
    }

    var hasPreviousSlideInCurrentSection: Bool {
        currentFullRunSlideIndex > 0
    }

    var canAdvanceFullRunSection: Bool {
        isActiveTake && nextFullRunSection != nil
    }

    var canAdvanceFullRunStep: Bool {
        hasNextSlideInCurrentSection || nextFullRunSection != nil
    }

    var canRetreatFullRunStep: Bool {
        if hasPreviousSlideInCurrentSection {
            return true
        }
        return !isActiveTake && currentFullRunSectionIndex > 0
    }

    var isOnFinalFullRunSection: Bool {
        guard let fullRunSnapshot else { return true }
        return currentFullRunSectionIndex >= max(0, fullRunSnapshot.sections.count - 1)
    }

    var isOnFinalFullRunStep: Bool {
        isOnFinalFullRunSection && !hasNextSlideInCurrentSection
    }

    var currentSectionElapsedDuration: TimeInterval {
        guard let activeStart = fullRunTransitions.last?.startTime else {
            return elapsedDuration
        }
        return max(0, elapsedDuration - activeStart)
    }

    func updateFullRunSnapshot(_ newSnapshot: FullRunSnapshot) {
        guard canChangePracticeMode else { return }
        fullRunSnapshot = newSnapshot
        snapshot = newSnapshot.makeAttemptSnapshotReference()
        currentFullRunSectionIndex = 0
        currentFullRunSlideIndex = 0
        fullRunTransitions = []
        isScriptRevealed = false
    }

    func selectFullRunSlide(index: Int) {
        let slides = currentFullRunSlides
        guard !slides.isEmpty else { return }
        currentFullRunSlideIndex = min(max(index, 0), slides.count - 1)
        isScriptRevealed = false
    }

    @discardableResult
    func advanceFullRunStep() -> Bool {
        if hasNextSlideInCurrentSection {
            currentFullRunSlideIndex += 1
            isScriptRevealed = false
            return true
        }
        guard nextFullRunSection != nil else { return false }
        if isActiveTake {
            return advanceFullRunSection() != nil
        }
        currentFullRunSectionIndex += 1
        currentFullRunSlideIndex = 0
        isScriptRevealed = false
        return true
    }

    @discardableResult
    func retreatFullRunStep() -> Bool {
        if hasPreviousSlideInCurrentSection {
            currentFullRunSlideIndex -= 1
            isScriptRevealed = false
            return true
        }
        guard !isActiveTake, currentFullRunSectionIndex > 0 else { return false }
        currentFullRunSectionIndex -= 1
        currentFullRunSlideIndex = max(0, currentFullRunSlides.count - 1)
        isScriptRevealed = false
        return true
    }

    @discardableResult
    func advanceFullRunSection() -> FullRunSectionTransition? {
        guard isActiveTake,
              let fullRunSnapshot,
              currentFullRunSectionIndex + 1 < fullRunSnapshot.sections.count else {
            return nil
        }

        let wasSilentRecall = phase == .silentRecall
        let sampledTime = resolvedElapsedDuration(wasSilentRecall: wasSilentRecall)
        let previousStart = fullRunTransitions.last?.startTime ?? 0
        let transitionTime = max(previousStart, sampledTime)
        let timestamp = nowProvider()

        if let lastIndex = fullRunTransitions.indices.last {
            let previous = fullRunTransitions[lastIndex]
            fullRunTransitions[lastIndex] = FullRunSectionTransition(
                id: previous.id,
                runIndex: previous.runIndex,
                talkSectionIndex: previous.talkSectionIndex,
                sectionID: previous.sectionID,
                sectionRevisionID: previous.sectionRevisionID,
                sectionTitle: previous.sectionTitle,
                speaker: previous.speaker,
                speakerRole: previous.speakerRole,
                purpose: previous.purpose,
                startTime: previous.startTime,
                endTime: transitionTime,
                recordedAt: previous.recordedAt
            )
        }

        currentFullRunSectionIndex += 1
        currentFullRunSlideIndex = 0
        isScriptRevealed = false

        let nextSection = fullRunSnapshot.sections[currentFullRunSectionIndex]
        let nextTransition = FullRunSectionTransition(
            runIndex: nextSection.runIndex,
            talkSectionIndex: nextSection.talkSectionIndex,
            sectionID: nextSection.sectionID,
            sectionRevisionID: nextSection.sectionRevisionID,
            sectionTitle: nextSection.title,
            speaker: nextSection.speaker,
            speakerRole: nextSection.speakerRole,
            purpose: nextSection.purpose,
            startTime: transitionTime,
            endTime: nil,
            recordedAt: timestamp
        )
        fullRunTransitions.append(nextTransition)
        elapsedDuration = max(elapsedDuration, transitionTime)

        checkpointInProgressFullRunState(wasSilentRecall: wasSilentRecall)
        return nextTransition
    }

    @discardableResult
    func finishFullRunEarly() -> AttemptRecord? {
        finishActiveTake(interrupted: false, interruptionReason: nil)
    }

    func prepareForFullRunRetry(
        fullRunSnapshot: FullRunSnapshot? = nil,
        practiceMode: PracticeMode? = nil
    ) {
        guard !isActiveTake, phase != .finalizing else { return }
        cancelPendingStart()
        if let fullRunSnapshot {
            self.fullRunSnapshot = fullRunSnapshot
            self.snapshot = fullRunSnapshot.makeAttemptSnapshotReference()
        }
        if let practiceMode {
            self.practiceMode = practiceMode
        }
        resetTakeCounters()
        clearActiveState()
        phase = .idle
    }

    func seedInitialFullRunTransitionIfNeeded(startedAt: Date) {
        guard let fullRunSnapshot, let firstSection = fullRunSnapshot.sections.first else {
            fullRunTransitions = []
            currentFullRunSectionIndex = 0
            currentFullRunSlideIndex = 0
            return
        }
        currentFullRunSectionIndex = 0
        currentFullRunSlideIndex = 0
        fullRunTransitions = [
            FullRunSectionTransition(
                runIndex: firstSection.runIndex,
                talkSectionIndex: firstSection.talkSectionIndex,
                sectionID: firstSection.sectionID,
                sectionRevisionID: firstSection.sectionRevisionID,
                sectionTitle: firstSection.title,
                speaker: firstSection.speaker,
                speakerRole: firstSection.speakerRole,
                purpose: firstSection.purpose,
                startTime: 0,
                endTime: nil,
                recordedAt: startedAt
            )
        ]
    }

    func makeCurrentFullRunPayload(
        finalDuration: TimeInterval,
        interrupted: Bool,
        isSilentRecall: Bool
    ) -> FullRunAttemptPayload? {
        guard let fullRunSnapshot else { return nil }
        let rawPayload = FullRunAttemptPayload(
            snapshot: fullRunSnapshot,
            transitions: fullRunTransitions,
            completionKind: interrupted ? .interrupted : .completedAllSections,
            reachedSectionCount: max(fullRunTransitions.count, 1)
        )
        return FullRunTimelineNormalizer.normalize(
            payload: rawPayload,
            finalDuration: finalDuration,
            interrupted: interrupted,
            isSilentRecall: isSilentRecall
        )
    }

    func checkpointInProgressFullRunState(wasSilentRecall: Bool) {
        guard !wasSilentRecall,
              let attemptID = activeAttemptID,
              let fullRunSnapshot else {
            return
        }
        let inProgressPayload = FullRunAttemptPayload(
            snapshot: fullRunSnapshot,
            transitions: fullRunTransitions,
            completionKind: .interrupted,
            reachedSectionCount: fullRunTransitions.count
        )
        try? attemptStore.updateInProgressFullRunState(
            attemptID: attemptID,
            fullRunPayload: inProgressPayload,
            elapsedDuration: elapsedDuration,
            revealCount: revealCount,
            markers: markers
        )
    }
}
