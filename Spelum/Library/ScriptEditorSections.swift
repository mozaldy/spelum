import SwiftUI

struct ScriptEditorHandoffSection: View {
    let handoff: HandoffContext
    @Binding var handoffCue: String
    let onPresentHandoff: () -> Void

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
    @Binding var cueWords: [String]
    @Binding var newCueWord: String

    var body: some View {
        Section {
            ForEach(Array(cueWords.indices), id: \.self) { index in
                HStack {
                    TextField(
                        "Cue word",
                        text: Binding(
                            get: { cueWords[index] },
                            set: { cueWords[index] = $0 }
                        )
                    )
                    .accessibilityLabel("Cue word \(index + 1)")

                    Button(role: .destructive) {
                        cueWords.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove cue \(cueWords[index])")
                }
            }
            .onDelete { offsets in
                cueWords.remove(atOffsets: offsets)
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
            Text("Short memory triggers for this section. Saved on each new revision.")
        }
    }

    private func addCueWord() {
        let trimmed = newCueWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cueWords.append(trimmed)
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
