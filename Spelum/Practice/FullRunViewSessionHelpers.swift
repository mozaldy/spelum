import SwiftUI
import UIKit

extension FullRunView {
    func fullRunScrollContent(
        session: RecordingSession,
        snapshot: FullRunSnapshot
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.isActiveTake {
                    Button {
                        setFullscreenMode(true)
                    } label: {
                        Label("Return to Fullscreen Stage", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("fullRunReturnToFullscreenButton")
                }

                FullRunHeaderCard(
                    presentationTitle: presentation.title,
                    snapshot: snapshot,
                    currentRunIndex: session.currentFullRunSectionIndex,
                    isOlderRevision: isOlderRevision,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )

                FullRunScopeCard(
                    selectedStartKind: selectedStartKind,
                    selectedHandoffSectionID: selectedHandoffSectionID,
                    handoffCandidates: handoffCandidates,
                    totalSectionCount: orderedSections.count,
                    isEnabled: session.canChangePracticeMode,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    onSelectStartKind: { selectStartKind($0) },
                    onSelectHandoffSection: { selectHandoffSection($0) }
                )

                PracticeModeCard(
                    selectedMode: session.practiceMode,
                    isEnabled: session.canChangePracticeMode,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    onSelectMode: { session.selectPracticeMode($0) }
                )

                fullRunStageSection(session: session, snapshot: snapshot)

                captureAndHistoryCards(session: session)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func fullRunStageSection(
        session: RecordingSession,
        snapshot: FullRunSnapshot
    ) -> some View {
        if let activeSection = session.currentFullRunSection {
            let hasStepNav = session.currentFullRunSlides.count > 1 || snapshot.sections.count > 1
            FullRunStageCard(
                section: activeSection,
                slides: session.currentFullRunSlides,
                activeSlideIndex: session.currentFullRunSlideIndex,
                totalInRun: snapshot.sections.count,
                practiceMode: session.practiceMode,
                isScriptRevealed: session.isScriptRevealed,
                revealCount: session.revealCount,
                isActiveTake: session.isActiveTake,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                storageRootURL: session.attemptStore.storageRootURL,
                canGoPrevious: session.canRetreatFullRunStep,
                previousButtonLabel: session.hasPreviousSlideInCurrentSection
                    ? "Previous Slide"
                    : "Previous Section",
                onPrevious: hasStepNav ? { _ = session.retreatFullRunStep() } : nil,
                canGoNext: session.canAdvanceFullRunStep,
                nextButtonLabel: session.hasNextSlideInCurrentSection
                    ? "Next Slide"
                    : "Next Section",
                onNext: hasStepNav ? { _ = session.advanceFullRunStep() } : nil,
                onSelectSlideIndex: session.currentFullRunSlides.count > 1
                    ? { session.selectFullRunSlide(index: $0) }
                    : nil,
                onToggleReveal: { session.toggleReveal() }
            )
        }
    }

    @ViewBuilder
    func captureAndHistoryCards(session: RecordingSession) -> some View {
        if session.microphoneDeniedNoticeVisible || session.permissionStatus == .denied {
            PracticeMicrophoneDeniedCard(
                canStartNewTake: session.canStartNewTake,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                onStartSilentRecall: { session.startSilentRecall() },
                onOpenSettings: {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        openURL(settingsURL)
                    }
                }
            )
        }

        PracticeRecoveryBanner(
            phase: displayedBannerPhase(for: session),
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            onOpenReview: onOpenReview,
            onRetrySection: { session.prepareForFullRunRetry() },
            onRetryFailedSave: { _ = session.retryFailedSave() },
            onDiscardFailedSave: { showingDiscardFailedConfirm = true },
            onStartSilentRecall: { session.startSilentRecall() }
        )

        FullRunControlsCard(
            session: session,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )

        FullRunRecentHistoryCard(
            fullRuns: presentationFullRuns,
            currentTalkRevisionID: presentation.currentRevisionID,
            errorMessage: historyErrorMessage,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            onOpenReview: onOpenReview,
            onOpenCompare: {
                let descriptors = presentationFullRuns.map(ComparableAttemptDescriptor.init(record:))
                let defaultPair = AttemptComparisonEngine.defaultComparablePair(
                    from: descriptors,
                    filter: .fullRuns,
                    anchorAttemptID: nil,
                    currentTalkRevisionID: presentation.currentRevisionID,
                    currentSectionRevisionIDs: []
                )
                onOpenHistory(.fullRuns, defaultPair?.laterID ?? presentationFullRuns.first?.id)
            },
            onRequestDelete: { attemptPendingDelete = $0 }
        )
    }

    func initializeSessionIfNeeded() {
        guard session == nil else { return }
        resetSessionForNewTarget()
    }

    func resetSessionForNewTarget() {
        let talkRevision = target.talkRevisionID.flatMap { id in
            presentation.talkRevisions.first { $0.id == id }
        } ?? presentationStore.currentTalkRevision(for: presentation)
        guard let talkRevision else { return }

        pinnedTalkRevisionID = talkRevision.id
        let ordered = presentationStore.orderedSections(in: talkRevision)
        let defaultHandoffID = presentationStore.defaultPresenterHandoffSection(in: talkRevision)?.sectionID
        selectedHandoffSectionID = target.startingSectionID ?? defaultHandoffID
        selectedStartKind = (target.startKind == .fromHandoff && ordered.count > 1)
            ? .fromHandoff
            : .entireTalk
        lastAutoOpenedAttemptID = nil
        isFullscreenMode = false

        guard let snapshot = presentationStore.makeFullRunSnapshot(
            for: presentation,
            talkRevision: talkRevision,
            startKind: selectedStartKind,
            startingSectionID: selectedHandoffSectionID
        ) else {
            return
        }

        if let existing = session {
            existing.prepareForFullRunRetry(fullRunSnapshot: snapshot, practiceMode: target.initialMode)
            lastObservedPhase = existing.phase
        } else {
            let newSession = RecordingSession(
                attemptStore: attemptStore,
                fullRunSnapshot: snapshot,
                initialMode: target.initialMode
            )
            session = newSession
            lastObservedPhase = newSession.phase
        }
    }

    func setFullscreenMode(_ enabled: Bool) {
        if reduceMotion {
            isFullscreenMode = enabled
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                isFullscreenMode = enabled
            }
        }
    }

    func handleSessionPhaseChange(_ newPhase: RecordingSessionPhase?) {
        guard let newPhase else {
            lastObservedPhase = nil
            return
        }
        if FullRunFullscreenPolicy.shouldAutoEnterFullscreen(
            previousPhase: lastObservedPhase,
            currentPhase: newPhase
        ) {
            setFullscreenMode(true)
        } else if FullRunFullscreenPolicy.shouldAutoExitFullscreen(for: newPhase) {
            setFullscreenMode(false)
        }
        lastObservedPhase = newPhase

        guard case .completed(let attemptID) = newPhase,
              lastAutoOpenedAttemptID != attemptID else {
            return
        }
        lastAutoOpenedAttemptID = attemptID
        onOpenReview(attemptID)
    }

    func selectStartKind(_ kind: FullRunStartKind) {
        guard let session, session.canChangePracticeMode,
              let talkRevision = resolvedTalkRevision else {
            return
        }
        selectedStartKind = kind
        if kind == .fromHandoff && selectedHandoffSectionID == nil {
            selectedHandoffSectionID = presentationStore.defaultPresenterHandoffSection(in: talkRevision)?.sectionID
        }
        if let updated = presentationStore.makeFullRunSnapshot(
            for: presentation,
            talkRevision: talkRevision,
            startKind: selectedStartKind,
            startingSectionID: selectedHandoffSectionID
        ) {
            session.updateFullRunSnapshot(updated)
        }
    }

    func selectHandoffSection(_ sectionID: UUID) {
        guard let session, session.canChangePracticeMode,
              let talkRevision = resolvedTalkRevision else {
            return
        }
        selectedHandoffSectionID = sectionID
        selectedStartKind = .fromHandoff
        if let updated = presentationStore.makeFullRunSnapshot(
            for: presentation,
            talkRevision: talkRevision,
            startKind: .fromHandoff,
            startingSectionID: sectionID
        ) {
            session.updateFullRunSnapshot(updated)
        }
    }

    func displayedBannerPhase(for session: RecordingSession) -> RecordingSessionPhase {
        guard case .interrupted(let attemptID, _, _) = session.phase else {
            return session.phase
        }
        if presentationFullRuns.contains(where: { $0.id == attemptID }) {
            return session.phase
        }
        do {
            if try attemptStore.attempt(withID: attemptID) == nil {
                return .idle
            }
        } catch {
            return session.phase
        }
        return session.phase
    }

    func deleteAttempt(_ attempt: AttemptRecord) {
        historyErrorMessage = nil
        let deletedID = attempt.id
        do {
            try attemptStore.deleteAttempt(attempt)
            session?.clearDeletedAttemptReference(deletedID)
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }
}
