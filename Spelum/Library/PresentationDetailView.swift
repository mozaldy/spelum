import SwiftData
import SwiftUI

struct PresentationDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let presentation: PresentationRecord
    let onSelectSection: (UUID) -> Void

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

    private var speakerSummary: String {
        let count = store.speakerCount(for: presentation)
        if count <= 1 {
            return "1 speaker (solo)"
        }
        return "\(count) speakers"
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
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

            overviewSection
            sectionsListSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(presentation.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
        .alert("Rename Presentation", isPresented: $showingRenameAlert) {
            TextField("Presentation title", text: $renameDraft)
            Button("Save") {
                renamePresentation()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove this section from the current revision?",
            isPresented: Binding(
                get: { sectionPendingDelete != nil },
                set: { isPresented in
                    if !isPresented { sectionPendingDelete = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Section", role: .destructive) {
                if let section = sectionPendingDelete {
                    sectionPendingDelete = nil
                    deleteSection(section)
                }
            }
            Button("Cancel", role: .cancel) {
                sectionPendingDelete = nil
            }
        } message: {
            Text("Earlier saved revisions will still keep this section intact.")
        }
        .sheet(isPresented: $showingRevisionHistory) {
            RevisionHistorySheet(presentation: presentation)
        }
        .sheet(isPresented: $showingOriginalScript) {
            OriginalScriptSheet(
                title: presentation.title,
                sourceText: presentation.sourceText
            )
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
                Button {
                    onSelectSection(section.sectionID)
                } label: {
                    SectionRowView(
                        index: index,
                        section: section,
                        handoff: handoff,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                    )
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("sectionRow_\(index)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if orderedSections.count > 1 {
                        Button(role: .destructive) {
                            sectionPendingDelete = section
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove(perform: moveSections)
        } header: {
            Text("Sections")
        } footer: {
            if orderedSections.count > 1 {
                Text("Select a section to edit, split, or present its handoff. Tap Edit to reorder sections.")
            } else {
                Text("Select this section to split your script, assign speakers, and prepare the handoff.")
            }
        }
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        errorMessage = nil
        var ids = orderedSections.map(\.sectionID)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            _ = try store.reorderSections(in: presentation, orderedSectionIDs: ids)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSection(_ section: SectionRevisionRecord) {
        errorMessage = nil
        do {
            _ = try store.deleteSection(in: presentation, sectionID: section.sectionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renamePresentation() {
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

private struct SectionRowView: View {
    let index: Int
    let section: SectionRevisionRecord
    let handoff: HandoffContext?
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerLayout

            let snippet = PresentationStore.displaySnippet(for: section.text)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(isAccessibilitySize ? 4 : 2)
            }

            if let handoff, !handoff.isFirstSection, let cue = handoff.effectiveCueText {
                handoffPreview(cue: cue, context: handoff)
            }

            if let exactPhrase = section.exactPhrase,
               !exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Exact phrase marked", systemImage: "quote.opening")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens section editor and handoff preparation.")
    }

    @ViewBuilder
    private var headerLayout: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(index + 1). \(section.title)")
                    .font(.headline)
                metadataLabels
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1). \(section.title)")
                        .font(.headline)
                    Spacer()
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Label(speakerSummary, systemImage: section.speakerRole.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var speakerSummary: String {
        let trimmedSpeaker = section.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSpeaker.isEmpty ||
            trimmedSpeaker.caseInsensitiveCompare(section.speakerRole.displayName) == .orderedSame {
            return section.speakerRole.displayName
        }
        return "\(trimmedSpeaker) · \(section.speakerRole.displayName)"
    }

    private var metadataLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(speakerSummary, systemImage: section.speakerRole.symbolName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handoffPreview(cue: String, context: HandoffContext) -> some View {
        let prefix: String
        if context.isSpeakerChange, let speaker = context.precedingSpeaker {
            prefix = "Handoff from \(speaker): "
        } else {
            prefix = "Previous line: "
        }
        return Text("\(prefix)“\(cue)”")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(isAccessibilitySize ? 3 : 1)
    }
}
