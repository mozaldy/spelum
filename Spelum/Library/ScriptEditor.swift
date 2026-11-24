import SwiftData
import SwiftUI

struct ScriptEditor: View {
    @Environment(\.modelContext) private var modelContext

    let presentation: PresentationRecord
    let sectionID: UUID
    let onNavigateToSection: (UUID) -> Void

    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var draftSpeaker = ""
    @State private var draftSpeakerRole: SpeakerRole = .presenter
    @State private var draftPurpose: SectionPurpose = .general
    @State private var draftCueWords: [String] = []
    @State private var newCueWord = ""
    @State private var draftExactPhrase = ""
    @State private var draftHandoffCue = ""
    @State private var loadedRevisionID: UUID?
    @State private var loadedTalkRevisionID: UUID?
    @State private var textSelection: TextSelection?

    @State private var showingLineSplitSheet = false
    @State private var showingHandoffPreview = false
    @State private var pendingNavigationSectionID: UUID?
    @State private var statusBanner: String?
    @State private var errorMessage: String?

    private var store: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var orderedSections: [SectionRevisionRecord] {
        store.orderedSections(for: presentation)
    }

    private var currentSectionIndex: Int? {
        orderedSections.firstIndex { $0.sectionID == sectionID }
    }

    private var currentSection: SectionRevisionRecord? {
        guard let index = currentSectionIndex else { return nil }
        return orderedSections[index]
    }

    private var handoffContext: HandoffContext? {
        store.handoffContext(forSectionID: sectionID, in: presentation)
    }

    private var currentTalkRevisionNumber: Int {
        store.currentTalkRevision(for: presentation)?.revisionNumber ?? 1
    }

    private var previousSectionID: UUID? {
        guard let index = currentSectionIndex, index > 0 else { return nil }
        return orderedSections[index - 1].sectionID
    }

    private var nextSectionID: UUID? {
        guard let index = currentSectionIndex, index + 1 < orderedSections.count else { return nil }
        return orderedSections[index + 1].sectionID
    }

    private var hasUnsavedChanges: Bool {
        guard let currentSection else { return false }
        return normalizedDraft != normalizedBaseline(SectionDraft(record: currentSection))
    }

    private var normalizedDraft: SectionDraft {
        let trimmedHandoff = draftHandoffCue.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedLine = handoffContext?.derivedFinalLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let handoffOverride = (trimmedHandoff.isEmpty || trimmedHandoff == derivedLine) ? nil : trimmedHandoff
        let exactPhrase = draftExactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : draftExactPhrase
        let cleanedCues = draftCueWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return SectionDraft(
            title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            text: draftText,
            speaker: draftSpeaker.trimmingCharacters(in: .whitespacesAndNewlines),
            speakerRole: draftSpeakerRole,
            purpose: draftPurpose,
            cueWords: cleanedCues,
            exactPhrase: exactPhrase,
            handoffCueOverride: handoffOverride
        )
    }

    private var cursorSplitIndex: String.Index? {
        guard let range = selectedRange else { return nil }
        let candidate = range.lowerBound
        guard candidate > draftText.startIndex, candidate < draftText.endIndex else {
            return nil
        }
        let before = draftText[..<candidate].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = draftText[candidate...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (!before.isEmpty && !after.isEmpty) ? candidate : nil
    }

    private var selectedNonEmptyText: String? {
        guard let range = selectedRange,
              range.lowerBound < range.upperBound,
              range.upperBound <= draftText.endIndex else {
            return nil
        }
        let substring = String(draftText[range])
        return substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : substring
    }

    private var selectedRange: Range<String.Index>? {
        guard let selection = textSelection else { return nil }
        switch selection.indices {
        case .selection(let range): return range
        case .multiSelection(let rangeSet): return rangeSet.ranges.first
        @unknown default: return nil
        }
    }

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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveRevision() }
                    .disabled(!hasUnsavedChanges)
                    .accessibilityIdentifier("saveSectionRevisionButton")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                bottomBarControls
            }
        }
        .sheet(isPresented: $showingLineSplitSheet) {
            LineSplitPickerSheet(options: PresentationStore.lineSplitOptions(in: draftText)) { index in
                performSplit(at: index)
            }
        }
        .sheet(isPresented: $showingHandoffPreview) {
            if let handoffContext {
                HandoffPresentationSheet(
                    presentationTitle: presentation.title,
                    revisionNumber: currentTalkRevisionNumber,
                    sectionDraft: normalizedDraft,
                    handoffContext: previewHandoffContext(from: handoffContext),
                    totalSections: orderedSections.count
                )
            }
        }
        .confirmationDialog(
            "You have unsaved edits in this section.",
            isPresented: Binding(
                get: { pendingNavigationSectionID != nil },
                set: { if !$0 { pendingNavigationSectionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save Revision & Continue") {
                if let targetID = pendingNavigationSectionID {
                    pendingNavigationSectionID = nil
                    if saveRevision() { onNavigateToSection(targetID) }
                }
            }
            Button("Discard Edits & Continue", role: .destructive) {
                if let targetID = pendingNavigationSectionID {
                    pendingNavigationSectionID = nil
                    onNavigateToSection(targetID)
                }
            }
            Button("Cancel", role: .cancel) { pendingNavigationSectionID = nil }
        }
        .onAppear { loadDraftIfNeeded(force: false) }
        .onChange(of: sectionID) { _, _ in
            statusBanner = nil
            loadDraftIfNeeded(force: true)
        }
        .onChange(of: presentation.currentRevisionID) { _, _ in loadDraftIfNeeded(force: false) }
    }

    private func editorForm(for record: SectionRevisionRecord) -> some View {
        Form {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if let statusBanner {
                Section {
                    Label(statusBanner, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let handoff = handoffContext {
                ScriptEditorHandoffSection(
                    handoff: handoff,
                    handoffCue: $draftHandoffCue,
                    onPresentHandoff: { showingHandoffPreview = true }
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
                    if let splitIndex = cursorSplitIndex { performSplit(at: splitIndex) }
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
            if let nextSectionID { requestNavigation(to: nextSectionID) }
        } label: {
            Label("Next Section", systemImage: "chevron.right")
        }
        .disabled(nextSectionID == nil)
        .accessibilityIdentifier("nextSectionButton")
    }
}

private extension ScriptEditor {
    func loadDraftIfNeeded(force: Bool) {
        guard let record = currentSection else { return }
        let talkRevID = presentation.currentRevisionID
        guard force || loadedRevisionID != record.revisionID || loadedTalkRevisionID != talkRevID else {
            return
        }
        loadedRevisionID = record.revisionID
        loadedTalkRevisionID = talkRevID
        draftTitle = record.title
        draftText = record.text
        draftSpeaker = record.speaker
        draftSpeakerRole = record.speakerRole
        draftPurpose = record.purpose
        draftCueWords = record.cueWords
        draftExactPhrase = record.exactPhrase ?? ""
        draftHandoffCue = handoffContext?.effectiveCueText ?? ""
        textSelection = nil
        errorMessage = nil
    }

    func normalizedBaseline(_ baseline: SectionDraft) -> SectionDraft {
        SectionDraft(
            title: baseline.title.trimmingCharacters(in: .whitespacesAndNewlines),
            text: baseline.text,
            speaker: baseline.speaker.trimmingCharacters(in: .whitespacesAndNewlines),
            speakerRole: baseline.speakerRole,
            purpose: baseline.purpose,
            cueWords: baseline.cueWords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            exactPhrase: baseline.exactPhrase,
            handoffCueOverride: baseline.handoffCueOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult
    func saveRevision() -> Bool {
        errorMessage = nil
        statusBanner = nil
        do {
            let revision = try store.saveSectionEdit(
                in: presentation,
                sectionID: sectionID,
                draft: normalizedDraft
            )
            loadDraftIfNeeded(force: true)
            statusBanner = "Saved Revision \(revision.revisionNumber)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func performSplit(at splitIndex: String.Index) {
        errorMessage = nil
        statusBanner = nil
        do {
            let result = try store.splitSection(
                in: presentation,
                sectionID: sectionID,
                at: splitIndex,
                pendingDraft: normalizedDraft
            )
            loadDraftIfNeeded(force: true)
            statusBanner = "Split into “\(result.firstSection.title)” and “\(result.secondSection.title)” " +
                "(Revision \(result.talkRevision.revisionNumber))"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestNavigation(to targetSectionID: UUID) {
        if hasUnsavedChanges {
            pendingNavigationSectionID = targetSectionID
        } else {
            onNavigateToSection(targetSectionID)
        }
    }

    func previewHandoffContext(from base: HandoffContext) -> HandoffContext {
        let draftOverride = normalizedDraft.handoffCueOverride
        return HandoffContext(
            sectionID: base.sectionID,
            sectionIndex: base.sectionIndex,
            precedingSectionID: base.precedingSectionID,
            precedingSectionTitle: base.precedingSectionTitle,
            precedingSpeaker: base.precedingSpeaker,
            precedingSpeakerRole: base.precedingSpeakerRole,
            derivedFinalLine: base.derivedFinalLine,
            customCue: draftOverride,
            effectiveCueText: draftOverride ?? base.derivedFinalLine,
            isCustomCue: draftOverride != nil,
            isFirstSection: base.isFirstSection,
            isSpeakerChange: base.isSpeakerChange,
            isSingleSpeakerTalk: base.isSingleSpeakerTalk
        )
    }
}
