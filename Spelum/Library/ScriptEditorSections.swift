import SwiftUI

struct ScriptEditorHandoffSection: View {
    let handoff: HandoffContext
    @Binding var handoffCue: String
    let onPresentHandoff: () -> Void
    let onStartPractice: (() -> Void)?

    init(
        handoff: HandoffContext,
        handoffCue: Binding<String>,
        onPresentHandoff: @escaping () -> Void,
        onStartPractice: (() -> Void)? = nil
    ) {
        self.handoff = handoff
        self._handoffCue = handoffCue
        self.onPresentHandoff = onPresentHandoff
        self.onStartPractice = onStartPractice
    }

    var body: some View {
        Section {
            HandoffAttributionView(context: handoff)
            TextField(
                handoff.isFirstSection ? "Optional opening cue" : "Preceding section’s final line",
                text: $handoffCue,
                axis: .vertical
            )
            .accessibilityLabel("Handoff cue")
            .accessibilityHint(
                handoff.isFirstSection
                    ? "Optional cue before the opening section."
                    : "Shows the preceding section’s final line. Edit to customize."
            )
            .accessibilityIdentifier("handoffCueTextField")

            statusRow

            Button(action: onPresentHandoff) {
                Label("Present Handoff", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("presentHandoffButton")

            if let onStartPractice {
                Button(action: onStartPractice) {
                    Label("Practice Section", systemImage: "mic.fill")
                }
                .accessibilityIdentifier("practiceSectionFromEditorButton")
            }
        } header: {
            Text("Handoff Cue")
        } footer: {
            Text("Shows the preceding section’s final line even when rehearsing alone.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        let trimmedDraft = handoffCue.trimmingCharacters(in: .whitespacesAndNewlines)
        let derived = handoff.derivedFinalLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDraft.isEmpty && trimmedDraft != derived {
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom handoff cue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let derivedLine = handoff.derivedFinalLine {
                    Button("Reset to Preceding Line") {
                        handoffCue = derivedLine
                    }
                    .font(.callout)
                    .accessibilityIdentifier("resetHandoffCueButton")
                } else {
                    Button("Clear Opening Cue", role: .destructive) {
                        handoffCue = ""
                    }
                    .font(.callout)
                }
            }
        } else if !handoff.isFirstSection, handoff.derivedFinalLine != nil {
            Text("Derived from preceding section’s final line")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScriptEditorScriptSection: View {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let canSplitAtCursor: Bool
    let canSplitAtLine: Bool
    let canMarkExactPhrase: Bool
    let onSplitAtCursor: () -> Void
    let onOpenLineSplit: () -> Void
    let onMarkExactPhrase: () -> Void

    var body: some View {
        Section {
            TextEditor(text: $text, selection: $selection)
                .frame(minHeight: 190)
                .accessibilityLabel("Section script text")
                .accessibilityIdentifier("sectionScriptTextEditor")

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(
                    SectionEditError.emptySectionText.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("sectionTextValidationError")
            }

            Button(action: onSplitAtCursor) {
                Label("Split at Cursor", systemImage: "scissors")
            }
            .disabled(!canSplitAtCursor)
            .accessibilityHint("Splits this section at the current cursor position in the script.")
            .accessibilityIdentifier("splitAtCursorButton")

            Button(action: onOpenLineSplit) {
                Label("Split at Line Break…", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(!canSplitAtLine)
            .accessibilityHint("Choose a line boundary to split this section into two sections.")
            .accessibilityIdentifier("splitAtLineButton")

            Button(action: onMarkExactPhrase) {
                Label("Mark Selection as Exact Phrase", systemImage: "quote.opening")
            }
            .disabled(!canMarkExactPhrase)
            .accessibilityIdentifier("markExactPhraseButton")
        } header: {
            Text("Script")
        } footer: {
            Text("Original wording, blank lines, curly quotes, and emoji are preserved verbatim.")
        }
    }
}

struct ScriptEditorExactPhraseSection: View {
    let scriptText: String
    @Binding var exactPhrase: String

    var body: some View {
        Section {
            TextField("Optional phrase to deliver word-for-word", text: $exactPhrase, axis: .vertical)
                .accessibilityLabel("Exact phrase")
                .accessibilityIdentifier("exactPhraseField")

            let trimmed = exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if scriptText.contains(exactPhrase) || scriptText.contains(trimmed) {
                    Label("Matches script verbatim", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Not found verbatim in this section’s script", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("Clear Exact Phrase", role: .destructive) {
                    exactPhrase = ""
                }
            }
        } header: {
            Text("Exact Phrase")
        } footer: {
            Text("Mark one key phrase to keep word-for-word while paraphrasing the rest.")
        }
    }
}

struct ScriptEditorCueWordsSection: View {
    @Binding var cueWords: [EditableCueWord]
    @Binding var newCueWord: String
    @FocusState private var focusedCueID: UUID?

    var body: some View {
        Section {
            ForEach(cueWords) { item in
                let position = (cueWords.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
                HStack {
                    TextField("Cue word", text: textBinding(for: item.id))
                        .focused($focusedCueID, equals: item.id)
                        .accessibilityLabel("Cue word \(position)")
                        .accessibilityIdentifier("cueWordField_\(position)")

                    Button(role: .destructive) {
                        var currentFocus = focusedCueID
                        CueWordListHelper.remove(id: item.id, from: &cueWords, focusedID: &currentFocus)
                        focusedCueID = currentFocus
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove cue \(item.text)")
                    .accessibilityIdentifier("removeCueWordButton_\(position)")
                }
            }
            .onDelete { offsets in
                var currentFocus = focusedCueID
                CueWordListHelper.remove(at: offsets, from: &cueWords, focusedID: &currentFocus)
                focusedCueID = currentFocus
            }

            HStack {
                TextField("Add cue word or short prompt", text: $newCueWord)
                    .onSubmit(addCueWord)
                    .accessibilityLabel("New cue word")
                    .accessibilityIdentifier("newCueWordField")

                Button("Add", action: addCueWord)
                    .disabled(newCueWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("addCueWordButton")
            }
        } header: {
            Text("Cue Words")
        } footer: {
            Text(
                "Short memory triggers for this section. When splitting, cue words matching " +
                "the second half move there automatically."
            )
        }
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { cueWords.first { $0.id == id }?.text ?? "" },
            set: { newValue in
                CueWordListHelper.updateText(newValue, for: id, in: &cueWords)
            }
        )
    }

    private func addCueWord() {
        let trimmed = newCueWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cueWords.append(EditableCueWord(text: trimmed))
        newCueWord = ""
    }
}

struct ScriptEditorDetailsSection: View {
    @Binding var title: String
    @Binding var speaker: String
    @Binding var speakerRole: SpeakerRole
    @Binding var purpose: SectionPurpose
    let knownSpeakers: [String]

    var body: some View {
        Section("Section Details") {
            TextField("Section title", text: $title)
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Section title")
                .accessibilityIdentifier("sectionTitleField")

            VStack(alignment: .leading, spacing: 6) {
                TextField("Speaker name", text: $speaker)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("Speaker name")
                    .accessibilityIdentifier("speakerNameField")

                if !knownSpeakers.isEmpty {
                    Menu("Choose Existing Speaker") {
                        ForEach(knownSpeakers, id: \.self) { existingSpeaker in
                            Button(existingSpeaker) {
                                speaker = existingSpeaker
                            }
                        }
                    }
                    .font(.callout)
                }
            }

            Picker("Role", selection: $speakerRole) {
                ForEach(SpeakerRole.allCases) { role in
                    Label(role.displayName, systemImage: role.symbolName)
                        .tag(role)
                }
            }
            .accessibilityIdentifier("speakerRolePicker")

            Picker("Purpose", selection: $purpose) {
                ForEach(SectionPurpose.allCases) { sectionPurpose in
                    Label(sectionPurpose.displayName, systemImage: sectionPurpose.symbolName)
                        .tag(sectionPurpose)
                }
            }
            .accessibilityIdentifier("sectionPurposePicker")
        }
    }
}
