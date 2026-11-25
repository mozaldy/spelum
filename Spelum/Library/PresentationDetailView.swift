import SwiftData
import SwiftUI

struct PresentationDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let presentation: PresentationRecord
    let onSelectSection: (UUID) -> Void
    let onPracticeSection: (PracticeTarget) -> Void
    let onOpenReview: (UUID) -> Void

    init(
        presentation: PresentationRecord,
        onSelectSection: @escaping (UUID) -> Void,
        onPracticeSection: @escaping (PracticeTarget) -> Void = { _ in },
        onOpenReview: @escaping (UUID) -> Void = { _ in }
    ) {
        self.presentation = presentation
        self.onSelectSection = onSelectSection
        self.onPracticeSection = onPracticeSection
        self.onOpenReview = onOpenReview
    }

    @Query(sort: \AttemptRecord.startedAt, order: .reverse)
    private var allAttempts: [AttemptRecord]

    @State private var showingRevisionHistory = false
    @State private var showingOriginalScript = false
    @State private var showingRenameAlert = false
    @State private var renameDraft = ""
    @State private var pendingFailedRename: String?
    @State private var sectionPendingDelete: SectionRevisionRecord?
    @State private var errorMessage: String?

    private var store: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var currentRevision: TalkRevisionRecord? {
        store.currentTalkRevision(for: presentation)
    }

    private var orderedSections: [SectionRevisionRecord] {
        guard let currentRevision else { return [] }
        return store.orderedSections(in: currentRevision)
    }

    private var presentationAttempts: [AttemptRecord] {
        allAttempts.filter { $0.presentationID == presentation.id && $0.status.isFinalized }
    }

    private var speakerSummary: String {
        let count = store.speakerCount(for: presentation)
        return count <= 1 ? "1 speaker (solo)" : "\(count) speakers"
    }

    var body: some View {
        List {
            if let errorMessage {
                errorSection(message: errorMessage)
            }
            overviewSection
            sectionsListSection
            if !presentationAttempts.isEmpty {
                PresentationRecentTakesSection(
                    attempts: presentationAttempts,
                    currentSectionRevisionIDs: Set(orderedSections.map(\.revisionID)),
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    onOpenReview: onOpenReview
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(presentation.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { detailToolbar }
        .alert("Rename Presentation", isPresented: $showingRenameAlert) {
            TextField("Presentation title", text: $renameDraft)
            Button("Save") { renamePresentation() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove this section from the current revision?",
            isPresented: Binding(
                get: { sectionPendingDelete != nil },
                set: { if !$0 { sectionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Section", role: .destructive) {
                if let section = sectionPendingDelete {
                    sectionPendingDelete = nil
                    deleteSection(section)
                }
            }
            Button("Cancel", role: .cancel) { sectionPendingDelete = nil }
        } message: {
            Text("Earlier saved revisions will still keep this section intact.")
        }
        .sheet(isPresented: $showingRevisionHistory) {
            RevisionHistorySheet(presentation: presentation)
        }
        .sheet(isPresented: $showingOriginalScript) {
            OriginalScriptSheet(title: presentation.title, sourceText: presentation.sourceText)
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if orderedSections.count > 1 {
                EditButton()
                    .accessibilityIdentifier("reorderSectionsEditButton")
            }
            Menu {
                Button {
                    renameDraft = pendingFailedRename ?? presentation.title
                    showingRenameAlert = true
                } label: {
                    Label("Rename Presentation", systemImage: "pencil")
                }
                Button {
                    showingRevisionHistory = true
                } label: {
                    Label("Revision History", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showingOriginalScript = true
                } label: {
                    Label("Original Imported Script", systemImage: "doc.plaintext")
                }
            } label: {
                Label("Presentation Options", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("presentationOptionsMenu")
        }
    }

    private func errorSection(message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("detailErrorLabel")
                if let pendingFailedRename {
                    Button("Retry Rename to “\(pendingFailedRename)”") {
                        renameDraft = pendingFailedRename
                        renamePresentation()
                    }
                    .font(.callout)
                    .accessibilityIdentifier("retryRenameButton")
                }
            }
        }
    }

    private var overviewSection: some View {
        Section {
            LabeledContent(
                "Current Revision",
                value: "Revision \(currentRevision?.revisionNumber ?? 1)"
            )
            LabeledContent("Sections", value: "\(orderedSections.count)")
            LabeledContent("Speakers", value: speakerSummary)
            if !presentationAttempts.isEmpty {
                LabeledContent("Saved Takes", value: "\(presentationAttempts.count)")
            }

            Button {
                showingRevisionHistory = true
            } label: {
                Label(
                    "Revision History (\(presentation.talkRevisions.count))",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .accessibilityIdentifier("openRevisionHistoryButton")

            Button {
                showingOriginalScript = true
            } label: {
                Label("View Original Imported Script", systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("viewOriginalScriptButton")
        } header: {
            Text("Overview")
        }
    }

    private var sectionsListSection: some View {
        Section {
            ForEach(Array(orderedSections.enumerated()), id: \.element.sectionID) { index, section in
                let handoff = currentRevision.flatMap {
                    store.handoffContext(forSectionID: section.sectionID, in: $0)
                }
                let takeCount = presentationAttempts.filter { $0.sectionID == section.sectionID }.count
                Button {
                    onSelectSection(section.sectionID)
                } label: {
                    SectionRowView(
                        index: index,
                        section: section,
                        handoff: handoff,
                        savedTakeCount: takeCount,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                    )
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("sectionRow_\(index)")
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { startPractice(for: section) } label: {
                        Label("Practice", systemImage: "mic.fill")
                    }
                    .tint(.accentColor)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if orderedSections.count > 1 {
                        Button(role: .destructive) { sectionPendingDelete = section } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .contextMenu {
                    Button { startPractice(for: section) } label: {
                        Label("Practice Section", systemImage: "mic.fill")
                    }
                    Button { onSelectSection(section.sectionID) } label: {
                        Label("Edit Script & Handoff", systemImage: "pencil")
                    }
                }
            }
            .onMove(perform: moveSections)
        } header: {
            Text("Sections")
        } footer: {
            Text(
                orderedSections.count > 1
                    ? "Select a section to edit, split, or rehearse. Swipe right on a section to practice directly."
                    : "Select this section to edit, split, or rehearse. Swipe right to practice directly."
            )
        }
    }
}

private extension PresentationDetailView {
    func startPractice(for section: SectionRevisionRecord) {
        let target = PracticeTarget(
            presentationID: presentation.id,
            sectionID: section.sectionID,
            talkRevisionID: currentRevision?.id,
            sectionRevisionID: section.revisionID,
            initialMode: .cueWords
        )
        onPracticeSection(target)
    }

    func moveSections(from source: IndexSet, to destination: Int) {
        errorMessage = nil
        var ids = orderedSections.map(\.sectionID)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            _ = try store.reorderSections(in: presentation, orderedSectionIDs: ids)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSection(_ section: SectionRevisionRecord) {
        errorMessage = nil
        do {
            _ = try store.deleteSection(in: presentation, sectionID: section.sectionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renamePresentation() {
        errorMessage = nil
        let attemptedTitle = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try store.renamePresentation(presentation, to: renameDraft)
            pendingFailedRename = nil
        } catch {
            if !attemptedTitle.isEmpty {
                pendingFailedRename = attemptedTitle
            }
            errorMessage = error.localizedDescription
        }
    }
}
