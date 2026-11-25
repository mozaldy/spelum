import SwiftData
import SwiftUI

enum PendingEditorExit: Equatable {
    case back
    case section(UUID)
}

struct PendingExactPhraseSplit {
    let requestedIndex: String.Index
    let conflict: ExactPhraseSplitConflict
}

struct ScriptEditor: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext

    let presentation: PresentationRecord
    let sectionID: UUID
    let onNavigateToSection: (UUID) -> Void
    let onPracticeSection: (PracticeTarget) -> Void

    init(
        presentation: PresentationRecord,
        sectionID: UUID,
        onNavigateToSection: @escaping (UUID) -> Void,
        onPracticeSection: @escaping (PracticeTarget) -> Void = { _ in }
    ) {
        self.presentation = presentation
        self.sectionID = sectionID
        self.onNavigateToSection = onNavigateToSection
        self.onPracticeSection = onPracticeSection
    }

    @State var draftTitle = ""
    @State var draftText = ""
    @State var draftSpeaker = ""
    @State var draftSpeakerRole: SpeakerRole = .presenter
    @State var draftPurpose: SectionPurpose = .general
    @State var draftCueWords: [EditableCueWord] = []
    @State var newCueWord = ""
    @State var draftExactPhrase = ""
    @State var draftHandoffCue = ""
    @State var loadedRevisionID: UUID?
    @State var loadedTalkRevisionID: UUID?
    @State var textSelection: TextSelection?

    @State var showingLineSplitSheet = false
    @State var showingHandoffPreview = false
    @State var pendingStartPracticeFromHandoff = false
    @State var pendingExit: PendingEditorExit?
    @State var pendingLineSplitIndex: String.Index?
    @State var pendingExactPhraseSplit: PendingExactPhraseSplit?
    @State var statusBanner: String?
    @State var errorMessage: String?

    var body: some View {
        Group {
            if let currentSection {
                editorForm(for: currentSection)
            } else {
                ContentUnavailableView(
                    "Section Unavailable",
                    systemImage: "doc.questionmark",
                    description: Text("This section is no longer in the current revision.")
                )
            }
        }
        .navigationTitle(draftTitle.isEmpty ? "Section" : draftTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar { editorToolbar }
        .sheet(isPresented: $showingLineSplitSheet, onDismiss: handlePendingLineSplit) {
            LineSplitPickerSheet(
                options: PresentationStore.lineSplitOptions(in: draftText),
                sourceText: draftText,
                exactPhrase: normalizedDraft.exactPhrase,
                cueWordCount: normalizedDraft.cueWords.count
            ) { index in
                pendingLineSplitIndex = index
            }
        }
        .sheet(isPresented: $showingHandoffPreview, onDismiss: handlePendingHandoffPractice) {
            if let handoffContext {
                HandoffPresentationSheet(
                    presentationTitle: presentation.title,
                    revisionNumber: currentTalkRevisionNumber,
                    sectionDraft: normalizedDraft,
                    handoffContext: previewHandoffContext(from: handoffContext),
                    totalSections: orderedSections.count,
                    onStartPractice: {
                        pendingStartPracticeFromHandoff = true
                    }
                )
            }
        }
        .confirmationDialog(
            "You have unsaved edits in this section.",
            isPresented: Binding(
                get: { pendingExit != nil },
                set: { if !$0 { pendingExit = nil } }
            ),
            titleVisibility: .visible
        ) {
            unsavedExitDialogActions
        } message: {
            unsavedExitDialogMessage
        }
        .confirmationDialog(
            "Split Cuts Through Exact Phrase",
            isPresented: Binding(
                get: { pendingExactPhraseSplit != nil },
                set: { if !$0 { pendingExactPhraseSplit = nil } }
            ),
            titleVisibility: .visible
        ) {
            exactPhraseSplitDialogActions
        } message: {
            exactPhraseSplitDialogMessage
        }
        .onAppear { loadDraftIfNeeded(force: false) }
        .onChange(of: sectionID) { _, _ in
            statusBanner = nil
            loadDraftIfNeeded(force: true)
        }
        .onChange(of: presentation.currentRevisionID) { _, _ in loadDraftIfNeeded(force: false) }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if hasUnsavedChanges {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    pendingExit = .back
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .fontWeight(.semibold)
                        Text("Back")
                    }
                }
                .accessibilityLabel("Back")
                .accessibilityHint("Prompts to save or discard unsaved section edits.")
                .accessibilityIdentifier("guardedBackButton")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { saveRevision() }
                .disabled(!hasUnsavedChanges)
                .accessibilityIdentifier("saveSectionRevisionButton")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            bottomBarControls
        }
    }

    private func editorForm(for record: SectionRevisionRecord) -> some View {
        Form {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("editorErrorLabel")
                }
            }
            if let statusBanner {
                Section {
                    Label(statusBanner, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("editorStatusBanner")
                }
            }
            if let handoff = handoffContext {
                ScriptEditorHandoffSection(
                    handoff: handoff,
                    handoffCue: $draftHandoffCue,
                    onPresentHandoff: { showingHandoffPreview = true },
                    onStartPractice: startPracticePreservingDraft
                )
            }
            ScriptEditorDetailsSection(
                title: $draftTitle,
                speaker: $draftSpeaker,
                speakerRole: $draftSpeakerRole,
                purpose: $draftPurpose,
                knownSpeakers: store.knownSpeakers(in: presentation)
            )
            ScriptEditorScriptSection(
                text: $draftText,
                selection: $textSelection,
                canSplitAtCursor: cursorSplitIndex != nil,
                canSplitAtLine: !PresentationStore.lineSplitOptions(in: draftText).isEmpty,
                canMarkExactPhrase: selectedNonEmptyText != nil,
                onSplitAtCursor: {
                    if let splitIndex = cursorSplitIndex { requestSplit(at: splitIndex) }
                },
                onOpenLineSplit: { showingLineSplitSheet = true },
                onMarkExactPhrase: {
                    if let selected = selectedNonEmptyText { draftExactPhrase = selected }
                }
            )
            ScriptEditorExactPhraseSection(scriptText: draftText, exactPhrase: $draftExactPhrase)
            ScriptEditorCueWordsSection(cueWords: $draftCueWords, newCueWord: $newCueWord)
            revisionFooterSection(for: record)
        }
    }

    private func revisionFooterSection(for record: SectionRevisionRecord) -> some View {
        Section("Revision") {
            LabeledContent("Talk Revision", value: "Revision \(currentTalkRevisionNumber)")
            if let index = currentSectionIndex {
                LabeledContent("Position", value: "Section \(index + 1) of \(orderedSections.count)")
            }
            LabeledContent("Status", value: hasUnsavedChanges ? "Unsaved changes" : "Saved")
            LabeledContent("Section ID", value: String(record.sectionID.uuidString.prefix(8)))
        }
    }

    @ViewBuilder
    private var bottomBarControls: some View {
        Button {
            if let previousSectionID { requestNavigation(to: previousSectionID) }
        } label: {
            Label("Previous Section", systemImage: "chevron.left")
        }
        .disabled(previousSectionID == nil)
        .accessibilityIdentifier("previousSectionButton")

        Spacer()

        Button("Handoff") { showingHandoffPreview = true }
            .accessibilityLabel("Present Handoff")
            .accessibilityIdentifier("toolbarPresentHandoffButton")

        Spacer()

        Button {
            startPracticePreservingDraft()
        } label: {
            Label("Practice", systemImage: "mic.fill")
        }
        .disabled(currentSection == nil)
        .accessibilityLabel("Practice Section")
        .accessibilityHint("Opens offline practice without discarding unsaved script edits.")
        .accessibilityIdentifier("toolbarPracticeSectionButton")

        Spacer()

        Button {
            if let nextSectionID { requestNavigation(to: nextSectionID) }
        } label: {
            Label("Next Section", systemImage: "chevron.right")
        }
        .disabled(nextSectionID == nil)
        .accessibilityIdentifier("nextSectionButton")
    }

    private func handlePendingHandoffPractice() {
        guard pendingStartPracticeFromHandoff else { return }
        pendingStartPracticeFromHandoff = false
        startPracticePreservingDraft()
    }

    private func startPracticePreservingDraft() {
        guard let talkRevision = store.currentTalkRevision(for: presentation),
              let section = currentSection else {
            return
        }
        let target = PracticeTarget(
            presentationID: presentation.id,
            sectionID: section.sectionID,
            talkRevisionID: talkRevision.id,
            sectionRevisionID: section.revisionID,
            initialMode: .cueWords,
            hasUnsavedEditorDraft: hasUnsavedChanges
        )
        onPracticeSection(target)
    }
}
