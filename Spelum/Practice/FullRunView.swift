import SwiftData
import SwiftUI

struct FullRunView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.openURL) var openURL
    @Environment(\.accessibilityReduceMotion) var reduceMotion

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
    var allAttempts: [AttemptRecord]

    @State var session: RecordingSession?
    @State var pinnedTalkRevisionID: UUID?
    @State var selectedStartKind: FullRunStartKind = .entireTalk
    @State var selectedHandoffSectionID: UUID?
    @State var lastAutoOpenedAttemptID: UUID?
    @State var attemptPendingDelete: AttemptRecord?
    @State var showingDiscardFailedConfirm = false
    @State var historyErrorMessage: String?
    @State var isFullscreenMode = false
    @State var lastObservedPhase: RecordingSessionPhase?

    var presentationStore: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    var attemptStore: AttemptStore {
        AttemptStore(modelContext: modelContext)
    }

    var resolvedTalkRevision: TalkRevisionRecord? {
        if let id = pinnedTalkRevisionID ?? target.talkRevisionID,
           let matched = presentation.talkRevisions.first(where: { $0.id == id }) {
            return matched
        }
        return presentationStore.currentTalkRevision(for: presentation)
    }

    var orderedSections: [SectionRevisionRecord] {
        guard let talkRevision = resolvedTalkRevision else { return [] }
        return presentationStore.orderedSections(in: talkRevision)
    }

    var handoffCandidates: [SectionRevisionRecord] {
        guard let talkRevision = resolvedTalkRevision else { return [] }
        return presentationStore.handoffStartCandidates(in: talkRevision)
    }

    var isOlderRevision: Bool {
        guard let currentID = presentation.currentRevisionID,
              let resolvedTalkRevision else {
            return false
        }
        return resolvedTalkRevision.id != currentID
    }

    var presentationFullRuns: [AttemptRecord] {
        allAttempts.filter { attempt in
            attempt.presentationID == presentation.id &&
            attempt.isFullRun &&
            attempt.status.isFinalized
        }
    }

    var body: some View {
        Group {
            if let session, let snapshot = session.fullRunSnapshot {
                if isFullscreenMode {
                    FullRunFullscreenStageView(
                        session: session,
                        snapshot: snapshot,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                        onExitFullscreen: { setFullscreenMode(false) }
                    )
                } else {
                    fullRunScrollContent(session: session, snapshot: snapshot)
                }
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
        .navigationBarBackButtonHidden(isFullscreenMode)
        .toolbar(isFullscreenMode ? .hidden : .visible, for: .navigationBar)
        .preferredColorScheme(isFullscreenMode ? .dark : nil)
        .toolbar {
            if session?.fullRunSnapshot != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        setFullscreenMode(true)
                    } label: {
                        Label("Fullscreen Stage", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Fullscreen Stage")
                    .accessibilityHint("Opens fullscreen mode showing only the script and rehearsal controls.")
                    .accessibilityIdentifier("fullRunEnterFullscreenButton")
                }
            }
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
            handleSessionPhaseChange(newPhase)
        }
        .onDisappear {
            isFullscreenMode = false
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
}
