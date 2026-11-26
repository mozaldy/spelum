import SwiftData
import SwiftUI
import UIKit

struct PracticeTarget: Hashable, Sendable {
    let presentationID: UUID
    let sectionID: UUID
    let talkRevisionID: UUID?
    let sectionRevisionID: UUID?
    let initialMode: PracticeMode
    let hasUnsavedEditorDraft: Bool
    let retryToken: UUID

    init(
        presentationID: UUID,
        sectionID: UUID,
        talkRevisionID: UUID? = nil,
        sectionRevisionID: UUID? = nil,
        initialMode: PracticeMode = .cueWords,
        hasUnsavedEditorDraft: Bool = false,
        retryToken: UUID = UUID()
    ) {
        self.presentationID = presentationID
        self.sectionID = sectionID
        self.talkRevisionID = talkRevisionID
        self.sectionRevisionID = sectionRevisionID
        self.initialMode = initialMode
        self.hasUnsavedEditorDraft = hasUnsavedEditorDraft
        self.retryToken = retryToken
    }
}

struct PracticeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    let presentation: PresentationRecord
    let target: PracticeTarget
    let onOpenReview: (UUID) -> Void

    @Query(sort: \AttemptRecord.startedAt, order: .reverse)
    private var allAttempts: [AttemptRecord]

    @State private var session: RecordingSession?
    @State private var coachCoordinator: PreparationCoachCoordinator?
    @State private var pinnedTalkRevisionID: UUID?
    @State private var pinnedSectionRevisionID: UUID?
    @State private var lastAutoOpenedAttemptID: UUID?
    @State private var attemptPendingDelete: AttemptRecord?
    @State private var showingDiscardFailedConfirm = false
    @State private var historyErrorMessage: String?

    private var presentationStore: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var attemptStore: AttemptStore {
        AttemptStore(modelContext: modelContext)
    }

    private var coachingStore: CoachingStore {
        CoachingStore(modelContext: modelContext)
    }

    private var resolvedTalkRevision: TalkRevisionRecord? {
        if let id = pinnedTalkRevisionID ?? target.talkRevisionID,
           let matched = presentation.talkRevisions.first(where: { $0.id == id }) {
            return matched
        }
        return presentationStore.currentTalkRevision(for: presentation)
    }

    private var resolvedSection: SectionRevisionRecord? {
        if let revID = pinnedSectionRevisionID ?? target.sectionRevisionID,
           let matched = presentation.sectionRevisions.first(where: { $0.revisionID == revID }) {
            return matched
        }
        if let talkRevision = resolvedTalkRevision {
            return presentationStore.orderedSections(in: talkRevision)
                .first { $0.sectionID == target.sectionID }
        }
        return nil
    }

    private var handoffContext: HandoffContext? {
        guard let talkRevision = resolvedTalkRevision else { return nil }
        return presentationStore.handoffContext(forSectionID: target.sectionID, in: talkRevision)
    }

    private var isOlderRevision: Bool {
        guard let currentID = presentation.currentRevisionID,
              let resolvedTalkRevision else {
            return false
        }
        return resolvedTalkRevision.id != currentID
    }

    private var sectionAttempts: [AttemptRecord] {
        allAttempts.filter { attempt in
            attempt.presentationID == presentation.id &&
            attempt.sectionID == target.sectionID &&
            attempt.status.isFinalized
        }
    }

    private var currentSectionRevisionID: UUID? {
        presentationStore.orderedSections(for: presentation)
            .first { $0.sectionID == target.sectionID }?.revisionID
    }

    var body: some View {
        Group {
            if let section = resolvedSection,
               let talkRevision = resolvedTalkRevision,
               let session {
                practiceScrollContent(section: section, talkRevision: talkRevision, session: session)
            } else {
                ContentUnavailableView(
                    "Section Unavailable",
                    systemImage: "waveform.slash",
                    description: Text("This section revision could not be loaded for practice.")
                )
            }
        }
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            initializeSessionIfNeeded()
            refreshPreparationCoach()
            session?.refreshPermissionStatus()
            session?.reconcileReferencedAttempt()
        }
        .onChange(of: target.retryToken) { _, _ in
            resetSessionForNewTarget()
            refreshPreparationCoach()
        }
        .onChange(of: resolvedSection?.revisionID) { _, _ in
            refreshPreparationCoach()
        }
        .onChange(of: sectionAttempts.map(\.id)) { _, _ in
            session?.reconcileReferencedAttempt()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                session?.refreshPermissionStatus()
            }
        }
        .onChange(of: session?.phase) { _, newPhase in
            guard case .completed(let attemptID) = newPhase,
                  lastAutoOpenedAttemptID != attemptID else {
                return
            }
            lastAutoOpenedAttemptID = attemptID
            onOpenReview(attemptID)
        }
        .onDisappear {
            coachCoordinator?.handleViewDisappear()
            session?.handleViewDisappear()
        }
        .confirmationDialog(
            "Delete this rehearsal take?",
            isPresented: Binding(
                get: { attemptPendingDelete != nil },
                set: { if !$0 { attemptPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Take", role: .destructive) {
                if let attempt = attemptPendingDelete {
                    attemptPendingDelete = nil
                    deleteAttempt(attempt)
                }
            }
            Button("Cancel", role: .cancel) { attemptPendingDelete = nil }
        } message: {
            Text("This removes only this take and its local audio recording.")
        }
        .confirmationDialog(
            "Discard unsaved recording?",
            isPresented: $showingDiscardFailedConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                _ = session?.discardFailedSave()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The preserved audio file for this failed save will be permanently deleted.")
        }
    }

    private func practiceScrollContent(
        section: SectionRevisionRecord,
        talkRevision: TalkRevisionRecord,
        session: RecordingSession
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PracticeHeaderCard(
                    presentationTitle: presentation.title,
                    section: section,
                    talkRevisionNumber: talkRevision.revisionNumber,
                    isOlderRevision: isOlderRevision,
                    hasUnsavedEditorDraft: target.hasUnsavedEditorDraft,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )

                PracticeModeCard(
                    selectedMode: session.practiceMode,
                    isEnabled: session.canChangePracticeMode,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    onSelectMode: { session.selectPracticeMode($0) }
                )

                if let handoff = handoffContext {
                    PracticeHandoffCueCard(handoff: handoff)
                }

                PracticePromptCard(
                    section: section,
                    practiceMode: session.practiceMode,
                    isScriptRevealed: session.isScriptRevealed,
                    revealCount: session.revealCount,
                    isActiveTake: session.isActiveTake,
                    onToggleReveal: { session.toggleReveal() }
                )

                if let coachCoordinator {
                    PracticeCoachingCard(
                        coordinator: coachCoordinator,
                        practiceMode: session.practiceMode,
                        isScriptRevealed: session.isScriptRevealed,
                        sectionExactPhrase: section.exactPhrase,
                        handoffCueText: handoffContext?.effectiveCueText,
                        isActiveTake: session.isActiveTake,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                        onRevealScript: { session.activateReveal() }
                    )
                }

                captureAndHistoryCards(session: session)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func captureAndHistoryCards(session: RecordingSession) -> some View {
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
            onRetrySection: { session.prepareForRetry() },
            onRetryFailedSave: { _ = session.retryFailedSave() },
            onDiscardFailedSave: { showingDiscardFailedConfirm = true },
            onStartSilentRecall: { session.startSilentRecall() }
        )

        PracticeCaptureControlsCard(
            session: session,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )

        PracticeHistoryCard(
            attempts: sectionAttempts,
            currentSectionRevisionID: currentSectionRevisionID,
            errorMessage: historyErrorMessage,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            onOpenReview: onOpenReview,
            onRequestDelete: { attemptPendingDelete = $0 }
        )
    }
}

private extension PracticeView {
    func initializeSessionIfNeeded() {
        guard session == nil else { return }
        resetSessionForNewTarget()
    }

    func refreshPreparationCoach() {
        guard let section = resolvedSection,
              let talkRevision = resolvedTalkRevision else {
            return
        }
        let coordinator: PreparationCoachCoordinator
        if let existing = coachCoordinator {
            coordinator = existing
        } else {
            coordinator = PreparationCoachCoordinator(coachingStore: coachingStore)
            coachCoordinator = coordinator
        }
        let speakers = Array(
            Set(
                presentationStore.orderedSections(in: talkRevision)
                    .map { $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        let selectedTechID = coordinator.activeRequest?.sectionRevisionID == section.revisionID
            ? coordinator.activeRequest?.selectedTechniqueID
            : nil
        let request = SectionCoachService.makePreparationRequest(
            section: section,
            talkRevisionID: talkRevision.id,
            handoff: handoffContext,
            knownSpeakerNames: speakers,
            selectedTechniqueID: selectedTechID
        )
        coordinator.load(request: request)
    }

    func resetSessionForNewTarget() {
        let talkRevision = target.talkRevisionID.flatMap { id in
            presentation.talkRevisions.first { $0.id == id }
        } ?? presentationStore.currentTalkRevision(for: presentation)
        guard let talkRevision else { return }

        let section: SectionRevisionRecord?
        if let targetSecRevID = target.sectionRevisionID {
            section = presentation.sectionRevisions.first { $0.revisionID == targetSecRevID }
        } else {
            section = presentationStore.orderedSections(in: talkRevision)
                .first { $0.sectionID == target.sectionID }
        }
        guard let section else { return }

        pinnedTalkRevisionID = talkRevision.id
        pinnedSectionRevisionID = section.revisionID
        lastAutoOpenedAttemptID = nil

        let snapshot = AttemptSnapshotReference(
            presentationID: presentation.id,
            talkRevisionID: talkRevision.id,
            talkRevisionNumber: talkRevision.revisionNumber,
            sectionID: section.sectionID,
            sectionRevisionID: section.revisionID,
            sectionTitle: section.title
        )
        if let existing = session {
            existing.prepareForRetry(snapshot: snapshot, practiceMode: target.initialMode)
        } else {
            session = RecordingSession(
                attemptStore: attemptStore,
                snapshot: snapshot,
                initialMode: target.initialMode
            )
        }
    }

    func displayedBannerPhase(for session: RecordingSession) -> RecordingSessionPhase {
        guard case .interrupted(let attemptID, _, _) = session.phase else {
            return session.phase
        }
        if sectionAttempts.contains(where: { $0.id == attemptID }) {
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
