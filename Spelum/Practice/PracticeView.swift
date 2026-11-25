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
        .onAppear { initializeSessionIfNeeded() }
        .onChange(of: target.retryToken) { _, _ in resetSessionForNewTarget() }
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
        .onDisappear { session?.handleViewDisappear() }
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
                session?.discardFailedSave()
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
            phase: session.phase,
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

    private func initializeSessionIfNeeded() {
        guard session == nil else { return }
        resetSessionForNewTarget()
    }

    private func resetSessionForNewTarget() {
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

    private func deleteAttempt(_ attempt: AttemptRecord) {
        historyErrorMessage = nil
        do {
            try attemptStore.deleteAttempt(attempt)
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }
}

struct PracticeHistoryCard: View {
    let attempts: [AttemptRecord]
    let currentSectionRevisionID: UUID?
    let errorMessage: String?
    let isAccessibilitySize: Bool
    let onOpenReview: (UUID) -> Void
    let onRequestDelete: (AttemptRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved Takes (\(attempts.count))", systemImage: "clock")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if attempts.isEmpty {
                Text("Completed, interrupted, and silent takes for this section appear here for replay and retry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(attempts, id: \.id) { attempt in
                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            onOpenReview(attempt.id)
                        } label: {
                            PracticeHistoryRow(
                                attempt: attempt,
                                isCurrentSectionRevision: attempt.sectionRevisionID == currentSectionRevisionID,
                                isAccessibilitySize: isAccessibilitySize
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("historyAttemptRow_\(attempt.id.uuidString)")

                        Button(role: .destructive) {
                            onRequestDelete(attempt)
                        } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            "Delete take from \(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .accessibilityIdentifier("deleteHistoryAttemptButton_\(attempt.id.uuidString)")
                    }
                    if attempt.id != attempts.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("sectionHistoryCard")
    }
}
