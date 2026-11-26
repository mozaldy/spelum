import SwiftUI

struct CoachingEditCueSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let originalAction: String
    let initialText: String
    let footerNotice: String?
    let onSave: (String) -> Void

    @State private var draftText: String

    init(
        title: String,
        originalAction: String,
        initialText: String,
        footerNotice: String? = nil,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.originalAction = originalAction
        self.initialText = initialText
        self.footerNotice = footerNotice
        self.onSave = onSave
        self._draftText = State(initialValue: initialText)
    }

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draftText)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Coaching cue text")
                        .accessibilityIdentifier("coachingCueEditTextEditor")
                } header: {
                    Text("Delivery Experiment")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Editing this cue updates only your coaching note. " +
                            "Your original script and take evidence stay unchanged."
                        )
                        if let footerNotice, !footerNotice.isEmpty {
                            Label(footerNotice, systemImage: "eye.slash")
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("coachingEditCueRevealNotice")
                        }
                    }
                }

                if trimmedDraft != originalAction {
                    Section {
                        Button("Restore Suggested Wording") {
                            draftText = originalAction
                        }
                        .accessibilityIdentifier("restoreSuggestedCueWordingButton")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("cancelEditCueButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmedDraft)
                        dismiss()
                    }
                    .disabled(trimmedDraft.isEmpty)
                    .accessibilityIdentifier("saveEditedCueButton")
                }
            }
        }
    }
}

struct CoachingOriginBadgesView: View {
    let cue: CoachingSuggestion
    let isAccessibilitySize: Bool

    var body: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                originLabel
                if cue.isUserEdited {
                    editedBadge
                }
                if cue.isAbstention {
                    abstentionBadge
                }
            }
        } else {
            HStack(spacing: 8) {
                originLabel
                if cue.isUserEdited {
                    editedBadge
                }
                if cue.isAbstention {
                    abstentionBadge
                }
            }
        }
    }

    private var originLabel: some View {
        Label(cue.origin.badgeLabel, systemImage: cue.origin.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(originColor)
            .accessibilityIdentifier("coachingOriginBadge")
    }

    private var editedBadge: some View {
        Label("Edited", systemImage: "pencil")
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .accessibilityIdentifier("coachingEditedBadge")
    }

    private var abstentionBadge: some View {
        Label("Withheld", systemImage: "checkmark.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .accessibilityIdentifier("coachingAbstainedBadge")
    }

    private var originColor: Color {
        switch cue.origin {
        case .authoredBaseline: .secondary
        case .onDeviceModel: .blue
        case .authoredFallback: .orange
        }
    }
}

struct CoachingProvenanceDisclosure: View {
    let cue: CoachingSuggestion

    @State private var isExpanded = false

    var body: some View {
        if let sourceWork = cue.sourceWork,
           let timestamp = cue.sourceTimestamp,
           let passage = cue.sourcePassageSummary {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(sourceWork) · \(timestamp)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(passage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Label("Reference Moment (\(timestamp))", systemImage: "book.pages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("coachingProvenanceDisclosure")
        }
    }
}

struct CoachingQuotedPassageBox: View {
    let phrase: String
    let fromHandoff: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                fromHandoff ? "Verbatim Handoff Cue" : "Verbatim Script Passage",
                systemImage: "quote.opening"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)

            Text("“\(phrase)”")
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coachingQuotedPassage")
    }
}
