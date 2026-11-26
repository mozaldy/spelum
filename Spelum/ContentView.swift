import SwiftData
import SwiftUI

enum LibraryRoute: Hashable {
    case presentation(UUID)
    case section(presentationID: UUID, sectionID: UUID)
    case practice(PracticeTarget)
    case fullRun(FullRunTarget)
    case history(presentationID: UUID, initialFilter: AttemptHistoryFilter, anchorAttemptID: UUID?)
    case review(attemptID: UUID)
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Query(sort: \PresentationRecord.updatedAt, order: .reverse)
    private var presentations: [PresentationRecord]

    @State private var navigationPath: [LibraryRoute] = []
    @State private var showingImportSheet = false
    @State private var showingCoachEvaluation = false
    @State private var presentationPendingDelete: PresentationRecord?
    @State private var errorMessage: String?

    private var store: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var attemptStore: AttemptStore {
        AttemptStore(modelContext: modelContext)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if presentations.isEmpty {
                    emptyLibraryView
                } else {
                    presentationsListView
                }
            }
            .navigationTitle("Presentations")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showingCoachEvaluation = true
                        } label: {
                            Label("Blinded Coach Evaluation", systemImage: "checklist")
                        }
                        .accessibilityIdentifier("openCoachEvaluationMenuButton")
                    } label: {
                        Label("Internal Tools", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("Internal Tools")
                    .accessibilityHint("Opens internal blinded evaluation tools for on-device coaching.")
                    .accessibilityIdentifier("internalToolsMenuButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImportSheet = true
                    } label: {
                        Label("Import Script", systemImage: "plus")
                    }
                    .accessibilityLabel("Import Script")
                    .accessibilityHint("Paste a script or import a UTF-8 plain text file.")
                    .accessibilityIdentifier("importScriptButton")
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                destinationView(for: route)
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportScriptSheet { importedPresentationID in
                    navigationPath = [.presentation(importedPresentationID)]
                }
            }
            .sheet(isPresented: $showingCoachEvaluation) {
                CoachingEvaluationView()
            }
            .confirmationDialog(
                "Delete “\(presentationPendingDelete?.title ?? "Presentation")”?",
                isPresented: Binding(
                    get: { presentationPendingDelete != nil },
                    set: { isPresented in
                        if !isPresented { presentationPendingDelete = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Presentation", role: .destructive) {
                    if let target = presentationPendingDelete {
                        presentationPendingDelete = nil
                        deletePresentation(target)
                    }
                }
                Button("Cancel", role: .cancel) {
                    presentationPendingDelete = nil
                }
            } message: {
                Text(
                    "This removes the presentation, its saved script revisions, " +
                    "and its local rehearsal takes from this device."
                )
            }
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Presentations Yet", systemImage: "doc.text")
        } description: {
            Text(
                "Paste a rehearsal script or import a UTF-8 plain text file " +
                "to organize sections and prepare your handoff."
            )
        } actions: {
            Button {
                showingImportSheet = true
            } label: {
                Label("Import Script", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("emptyStateImportButton")
        }
    }

    private var presentationsListView: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("libraryErrorLabel")
                }
            }

            Section {
                ForEach(presentations, id: \.id) { presentation in
                    NavigationLink(value: LibraryRoute.presentation(presentation.id)) {
                        PresentationLibraryRow(
                            presentation: presentation,
                            sectionCount: store.orderedSections(for: presentation).count,
                            revisionNumber: store.currentTalkRevision(for: presentation)?.revisionNumber ?? 1,
                            speakerCount: store.speakerCount(for: presentation),
                            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                        )
                    }
                    .accessibilityIdentifier("presentationRow_\(presentation.title)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            presentationPendingDelete = presentation
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Scripts, saved revisions, and rehearsal takes stay strictly local on this device.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var missingPresentationView: some View {
        ContentUnavailableView(
            "Presentation Not Found",
            systemImage: "doc.questionmark",
            description: Text("This presentation may have been deleted.")
        )
    }
}

private extension ContentView {
    @ViewBuilder
    func destinationView(for route: LibraryRoute) -> some View {
        switch route {
        case .presentation(let presentationID):
            presentationDestination(for: presentationID)
        case .section(let presentationID, let sectionID):
            sectionDestination(presentationID: presentationID, sectionID: sectionID)
        case .practice(let target):
            practiceDestination(for: target)
        case .fullRun(let target):
            fullRunDestination(for: target)
        case .history(let presentationID, let initialFilter, let anchorAttemptID):
            historyDestination(
                presentationID: presentationID,
                initialFilter: initialFilter,
                anchorAttemptID: anchorAttemptID
            )
        case .review(let attemptID):
            TakeReview(
                attemptID: attemptID,
                onRetry: { retryTarget in
                    navigateToRetry(retryTarget)
                },
                onRetryFullRun: { retryTarget in
                    navigateToFullRunRetry(retryTarget)
                },
                onCompare: { presentationID, filter, anchorID in
                    navigationPath.append(
                        .history(
                            presentationID: presentationID,
                            initialFilter: filter,
                            anchorAttemptID: anchorID
                        )
                    )
                }
            )
        }
    }

    @ViewBuilder
    func presentationDestination(for presentationID: UUID) -> some View {
        if let presentation = presentations.first(where: { $0.id == presentationID }) {
            PresentationDetailView(
                presentation: presentation,
                onSelectSection: { sectionID in
                    navigationPath.append(
                        .section(presentationID: presentation.id, sectionID: sectionID)
                    )
                },
                onPracticeSection: { target in
                    navigationPath.append(.practice(target))
                },
                onOpenReview: { attemptID in
                    navigationPath.append(.review(attemptID: attemptID))
                },
                onStartFullRun: { target in
                    navigationPath.append(.fullRun(target))
                },
                onOpenHistory: { filter, anchorID in
                    navigationPath.append(
                        .history(
                            presentationID: presentation.id,
                            initialFilter: filter,
                            anchorAttemptID: anchorID
                        )
                    )
                }
            )
        } else {
            missingPresentationView
        }
    }

    @ViewBuilder
    func sectionDestination(presentationID: UUID, sectionID: UUID) -> some View {
        if let presentation = presentations.first(where: { $0.id == presentationID }) {
            ScriptEditor(
                presentation: presentation,
                sectionID: sectionID,
                onNavigateToSection: { nextSectionID in
                    replaceCurrentSectionRoute(
                        presentationID: presentation.id,
                        sectionID: nextSectionID
                    )
                },
                onPracticeSection: { target in
                    navigationPath.append(.practice(target))
                }
            )
        } else {
            missingPresentationView
        }
    }

    @ViewBuilder
    func practiceDestination(for target: PracticeTarget) -> some View {
        if let presentation = presentations.first(where: { $0.id == target.presentationID }) {
            PracticeView(
                presentation: presentation,
                target: target,
                onOpenReview: { attemptID in
                    navigationPath.append(.review(attemptID: attemptID))
                }
            )
        } else {
            missingPresentationView
        }
    }

    @ViewBuilder
    func fullRunDestination(for target: FullRunTarget) -> some View {
        if let presentation = presentations.first(where: { $0.id == target.presentationID }) {
            FullRunView(
                presentation: presentation,
                target: target,
                onOpenReview: { attemptID in
                    navigationPath.append(.review(attemptID: attemptID))
                },
                onOpenHistory: { filter, anchorID in
                    navigationPath.append(
                        .history(
                            presentationID: presentation.id,
                            initialFilter: filter,
                            anchorAttemptID: anchorID
                        )
                    )
                }
            )
        } else {
            missingPresentationView
        }
    }

    @ViewBuilder
    func historyDestination(
        presentationID: UUID,
        initialFilter: AttemptHistoryFilter,
        anchorAttemptID: UUID?
    ) -> some View {
        if let presentation = presentations.first(where: { $0.id == presentationID }) {
            AttemptHistory(
                presentation: presentation,
                initialFilter: initialFilter,
                anchorAttemptID: anchorAttemptID,
                onOpenReview: { attemptID in
                    navigationPath.append(.review(attemptID: attemptID))
                }
            )
        } else {
            missingPresentationView
        }
    }

    func replaceCurrentSectionRoute(presentationID: UUID, sectionID: UUID) {
        if !navigationPath.isEmpty {
            navigationPath[navigationPath.count - 1] = .section(
                presentationID: presentationID,
                sectionID: sectionID
            )
        } else {
            navigationPath = [
                .presentation(presentationID),
                .section(presentationID: presentationID, sectionID: sectionID)
            ]
        }
    }

    func navigateToRetry(_ target: PracticeTarget) {
        if navigationPath.count >= 2,
           case .review = navigationPath[navigationPath.count - 1],
           case .practice(let previousTarget) = navigationPath[navigationPath.count - 2],
           previousTarget.presentationID == target.presentationID,
           previousTarget.sectionID == target.sectionID {
            let preservedDraftTarget = PracticeTarget(
                presentationID: target.presentationID,
                sectionID: target.sectionID,
                talkRevisionID: target.talkRevisionID,
                sectionRevisionID: target.sectionRevisionID,
                initialMode: target.initialMode,
                hasUnsavedEditorDraft: previousTarget.hasUnsavedEditorDraft,
                retryToken: target.retryToken
            )
            navigationPath[navigationPath.count - 2] = .practice(preservedDraftTarget)
            navigationPath.removeLast()
        } else if !navigationPath.isEmpty, case .review = navigationPath[navigationPath.count - 1] {
            navigationPath[navigationPath.count - 1] = .practice(target)
        } else {
            navigationPath.append(.practice(target))
        }
    }

    func navigateToFullRunRetry(_ target: FullRunTarget) {
        if navigationPath.count >= 2,
           case .review = navigationPath[navigationPath.count - 1],
           case .fullRun(let previousTarget) = navigationPath[navigationPath.count - 2],
           previousTarget.presentationID == target.presentationID {
            navigationPath[navigationPath.count - 2] = .fullRun(target)
            navigationPath.removeLast()
        } else if !navigationPath.isEmpty, case .review = navigationPath[navigationPath.count - 1] {
            navigationPath[navigationPath.count - 1] = .fullRun(target)
        } else {
            navigationPath.append(.fullRun(target))
        }
    }

    func deletePresentation(_ presentation: PresentationRecord) {
        errorMessage = nil
        do {
            try attemptStore.deletePresentationAndAttempts(presentation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    if let container = try? PresentationStore.makeModelContainer(inMemory: true) {
        ContentView()
            .modelContainer(container)
    }
}
