import SwiftData
import SwiftUI
import UIKit

struct FullRunView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    let presentation: PresentationRecord
    let target: FullRunTarget
    let onOpenReview: (UUID) -> Void
    let onOpenHistory: (AttemptHistoryFilter, UUID?) -> Void

    init(
        presentation: PresentationRecord,
        target: FullRunTarget,
        onOpenReview: @escaping (UUID) -> Void,
        onOpenHistory: @escaping (AttemptHistoryFilter, UUID?) -> Void = { _, _ in }
    ) {
        self.presentation = presentation
        self.target = target
        self.onOpenReview = onOpenReview
        self.onOpenHistory = onOpenHistory
    }

    @Query(sort: \AttemptRecord.startedAt, order: .reverse)
    private var allAttempts: [AttemptRecord]

    @State private var session: RecordingSession?
    @State private var pinnedTalkRevisionID: UUID?
    @State private var selectedStartKind: FullRunStartKind = .entireTalk
    @State private var selectedHandoffSectionID: UUID?
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

    private var resolvedTalkRevision: TalkRevisionRecord? {
        if let id = pinnedTalkRevisionID ?? target.talkRevisionID,
           let matched = presentation.talkRevisions.first(where: { $0.id == id }) {
            return matched
        }
        return presentationStore.currentTalkRevision(for: presentation)
    }

    private var orderedSections: [SectionRevisionRecord] {
        guard let talkRevision = resolvedTalkRevision else { return [] }
        return presentationStore.orderedSections(in: talkRevision)
    }

    private var handoffCandidates: [SectionRevisionRecord] {
        guard let talkRevision = resolvedTalkRevision else { return [] }
        return presentationStore.handoffStartCandidates(in: talkRevision)
    }

    private var isOlderRevision: Bool {
        guard let currentID = presentation.currentRevisionID,
              let resolvedTalkRevision else {
            return false
        }
        return resolvedTalkRevision.id != currentID
    }

    private var presentationFullRuns: [AttemptRecord] {
        allAttempts.filter { attempt in
            attempt.presentationID == presentation.id &&
            attempt.isFullRun &&
            attempt.status.isFinalized
        }
    }

    var body: some View {
        Group {
            if let session, let snapshot = session.fullRunSnapshot {
                fullRunScrollContent(session: session, snapshot: snapshot)
            } else {
                ContentUnavailableView(
                    "Full Run Unavailable",
                    systemImage: "waveform.slash",
                    description: Text("Add at least one section to rehearse a full run.")
                )
            }
        }
        .navigationTitle("Full Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !presentationFullRuns.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onOpenHistory(.fullRuns, nil)
                    } label: {
                        Label("History & Compare", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("fullRunToolbarHistoryButton")
                }
            }
        }
        .onAppear {
            initializeSessionIfNeeded()
            session?.refreshPermissionStatus()
            session?.reconcileReferencedAttempt()
        }
        .onChange(of: target.retryToken) { _, _ in
            resetSessionForNewTarget()
        }
        .onChange(of: presentationFullRuns.map(\.id)) { _, _ in
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
            session?.handleViewDisappear()
        }
        .confirmationDialog(
            "Delete this full run?",
            isPresented: Binding(
                get: { attemptPendingDelete != nil },
                set: { if !$0 { attemptPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Full Run", role: .destructive) {
                if let attempt = attemptPendingDelete {
                    attemptPendingDelete = nil
                    deleteAttempt(attempt)
                }
            }
            Button("Cancel", role: .cancel) { attemptPendingDelete = nil }
        } message: {
            Text("This removes only this full run and its local audio recording.")
        }
        .confirmationDialog(
            "Discard unsaved full run?",
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

    private func fullRunScrollContent(
        session: RecordingSession,
        snapshot: FullRunSnapshot
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                if let activeSection = session.currentFullRunSection {
                    FullRunStageCard(
                        section: activeSection,
                        totalInRun: snapshot.sections.count,
                        practiceMode: session.practiceMode,
                        isScriptRevealed: session.isScriptRevealed,
                        revealCount: session.revealCount,
                        isActiveTake: session.isActiveTake,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                        onToggleReveal: { session.toggleReveal() }
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
}

private extension FullRunView {
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
        } else {
            session = RecordingSession(
                attemptStore: attemptStore,
                fullRunSnapshot: snapshot,
                initialMode: target.initialMode
            )
        }
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
