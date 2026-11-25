import SwiftUI

struct HandoffAttributionView: View {
    let context: HandoffContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if context.isFirstSection {
                Label("Opening Section", systemImage: "flag.fill")
                    .font(.subheadline.weight(.semibold))
                Text("No preceding section in this talk.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if context.isSpeakerChange {
                Label(
                    "Handoff from \(context.precedingSpeaker ?? "Previous Speaker")",
                    systemImage: "arrow.turn.down.right"
                )
                .font(.subheadline.weight(.semibold))
                Text(attributionSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Previous Line · \(context.precedingSpeaker ?? "Speaker")",
                    systemImage: "arrow.down.to.line"
                )
                .font(.subheadline.weight(.semibold))
                Text(context.isSingleSpeakerTalk ? "Solo talk continuation" : "Same speaker continuation")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var attributionSubtitle: String {
        let role = context.precedingSpeakerRole?.displayName ?? ""
        let title = context.precedingSectionTitle ?? ""
        if !role.isEmpty && !title.isEmpty {
            return "\(role) · \(title)"
        }
        return !role.isEmpty ? role : title
    }
}

struct LineSplitPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let options: [LineSplitOption]
    let sourceText: String
    let exactPhrase: String?
    let cueWordCount: Int
    let onSelect: (String.Index) -> Void

    init(
        options: [LineSplitOption],
        sourceText: String = "",
        exactPhrase: String? = nil,
        cueWordCount: Int = 0,
        onSelect: @escaping (String.Index) -> Void
    ) {
        self.options = options
        self.sourceText = sourceText
        self.exactPhrase = exactPhrase
        self.cueWordCount = cueWordCount
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            Group {
                if options.isEmpty {
                    ContentUnavailableView(
                        "No Line Breaks Available",
                        systemImage: "text.alignleft",
                        description: Text("Add a new line or place the cursor in the script to split.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(options) { option in
                                splitOptionRow(option)
                            }
                        } footer: {
                            if cueWordCount > 0 {
                                Text(
                                    "Cue words matching the second half move there automatically; " +
                                    "other cue words stay in the first section."
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Split at Line Break")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func splitOptionRow(_ option: LineSplitOption) -> some View {
        let crossesExactPhrase = PresentationStore.exactPhraseSplitConflict(
            in: sourceText,
            exactPhrase: exactPhrase,
            at: option.splitIndex
        ) != nil

        return Button {
            onSelect(option.splitIndex)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Split before line \(option.lineNumber)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Ends section 1: \(option.beforePreview)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Starts section 2: \(option.afterPreview)")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .lineLimit(2)
                if crossesExactPhrase {
                    Label("Cuts through marked exact phrase", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("splitOptionLine\(option.lineNumber)")
    }
}

struct HandoffPresentationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentationTitle: String
    let revisionNumber: Int
    let sectionDraft: SectionDraft
    let handoffContext: HandoffContext
    let totalSections: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    handoffCard
                    sectionMetadataCard
                    if let exactPhrase = sectionDraft.exactPhrase,
                       !exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        exactPhraseCard(exactPhrase)
                    }
                    if !sectionDraft.cueWords.isEmpty {
                        cueWordsCard
                    }
                    scriptCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Handoff Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("doneHandoffPreviewButton")
                }
            }
        }
    }

    private var handoffCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HandoffAttributionView(context: handoffContext)

            if let cueText = handoffContext.effectiveCueText, !cueText.isEmpty {
                Text("“\(cueText)”")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("handoffPreviewCueText")

                if handoffContext.isCustomCue {
                    Text("Custom handoff cue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Start from the opening of your presentation.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sectionMetadataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sectionDraft.title.isEmpty ? "Current Section" : sectionDraft.title)
                .font(.headline)
            Text(
                "\(presentationTitle) · Section \(handoffContext.sectionIndex + 1) of \(totalSections) · " +
                "Revision \(revisionNumber)"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Label(speakerDisplayLabel, systemImage: sectionDraft.speakerRole.symbolName)
                .font(.subheadline)

            Label(sectionDraft.purpose.displayName, systemImage: sectionDraft.purpose.symbolName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var speakerDisplayLabel: String {
        let trimmed = sectionDraft.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleName = sectionDraft.speakerRole.displayName
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(roleName) == .orderedSame {
            return roleName
        }
        return "\(trimmed) (\(roleName))"
    }

    private func exactPhraseCard(_ phrase: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Exact Phrase", systemImage: "quote.opening")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text(phrase)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var cueWordsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cue Words", systemImage: "tag")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(sectionDraft.cueWords.enumerated()), id: \.offset) { _, word in
                Text("• \(word)")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your Section Script", systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
            Text(sectionDraft.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("handoffPreviewScriptText")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
