import SwiftUI

struct FullRunScopeCard: View {
    let selectedStartKind: FullRunStartKind
    let selectedHandoffSectionID: UUID?
    let handoffCandidates: [SectionRevisionRecord]
    let totalSectionCount: Int
    let isEnabled: Bool
    let isAccessibilitySize: Bool
    let onSelectStartKind: (FullRunStartKind) -> Void
    let onSelectHandoffSection: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Scope")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if totalSectionCount <= 1 {
                Label("Single-section talk (1 section)", systemImage: "play.square.stack")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                scopePicker
                if selectedStartKind == .fromHandoff && !handoffCandidates.isEmpty {
                    handoffStartPicker
                }
            }

            Text(scopeGuidanceText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("fullRunScopeCard")
    }

    @ViewBuilder
    private var scopePicker: some View {
        if isAccessibilitySize {
            VStack(spacing: 8) {
                ForEach(FullRunStartKind.allCases) { kind in
                    Button {
                        onSelectStartKind(kind)
                    } label: {
                        HStack {
                            Label(kind.displayName, systemImage: kind.symbolName)
                            Spacer()
                            if selectedStartKind == kind {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(
                            selectedStartKind == kind
                                ? Color.accentColor.opacity(0.15)
                                : Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .accessibilityAddTraits(selectedStartKind == kind ? .isSelected : [])
                    .accessibilityIdentifier("fullRunScope_\(kind.rawValue)")
                }
            }
        } else {
            Picker(
                "Run Scope",
                selection: Binding(
                    get: { selectedStartKind },
                    set: { onSelectStartKind($0) }
                )
            ) {
                ForEach(FullRunStartKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!isEnabled)
            .accessibilityLabel("Run Scope")
            .accessibilityIdentifier("fullRunScopePicker")
        }
    }

    private var handoffStartPicker: some View {
        let currentSelection = selectedHandoffSectionID ?? handoffCandidates.first?.sectionID ?? UUID()
        return Menu {
            ForEach(handoffCandidates, id: \.sectionID) { candidate in
                Button {
                    onSelectHandoffSection(candidate.sectionID)
                } label: {
                    let prefix = candidate.speakerRole == .presenter ? "Presenter" : "Teammate"
                    Text("\(candidate.title) (\(candidate.speaker) · \(prefix))")
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start at Handoff")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedCandidateTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!isEnabled)
        .accessibilityLabel("Start at Handoff Section")
        .accessibilityValue(selectedCandidateTitle)
        .accessibilityIdentifier("fullRunHandoffStartPicker_\(currentSelection.uuidString)")
    }

    private var selectedCandidateTitle: String {
        if let selectedHandoffSectionID,
           let matched = handoffCandidates.first(where: { $0.sectionID == selectedHandoffSectionID }) {
            return "\(matched.title) · \(matched.speaker)"
        }
        if let first = handoffCandidates.first {
            return "\(first.title) · \(first.speaker)"
        }
        return "Choose section"
    }

    private var scopeGuidanceText: String {
        switch selectedStartKind {
        case .entireTalk:
            "Records one continuous audio timeline across every section in the snapshotted order."
        case .fromHandoff:
            "Shows the preceding speaker’s handoff cue and records continuously from your handoff through the close."
        }
    }
}

struct FullRunStageCard: View {
    let section: FullRunSectionSnapshot
    let totalInRun: Int
    let practiceMode: PracticeMode
    let isScriptRevealed: Bool
    let revealCount: Int
    let isActiveTake: Bool
    let isAccessibilitySize: Bool
    let onToggleReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader

            if let handoffCue = section.handoffCueText, !handoffCue.isEmpty {
                handoffCueBox(cue: handoffCue)
            }

            if section.purpose == .demonstration {
                Label(
                    "Demonstration — intentional silence stays in the continuous recording timeline.",
                    systemImage: "play.display"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fullRunSilentDemoNote")
            }

            promptContent

            if practiceMode.supportsReveal {
                revealButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("fullRunStageCard")
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(section.talkSectionIndex + 1). \(section.title)")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(section.speakerSummary, systemImage: section.speakerRole.symbolName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(section.talkSectionIndex + 1). \(section.title)")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text("\(section.runIndex + 1)/\(totalInRun)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label(section.speakerSummary, systemImage: section.speakerRole.symbolName)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func handoffCueBox(cue: String) -> some View {
        let heading: String
        if section.handoffIsSpeakerChange, let prevSpeaker = section.handoffPrecedingSpeaker {
            heading = "Handoff from \(prevSpeaker)"
        } else if let prevTitle = section.handoffPrecedingSectionTitle {
            heading = "Previous line (\(prevTitle))"
        } else {
            heading = "Handoff Cue"
        }

        return VStack(alignment: .leading, spacing: 4) {
            Label(heading, systemImage: "arrow.triangle.turn.up.right.diamond")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text("“\(cue)”")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullRunStageHandoffCue")
    }

    @ViewBuilder
    private var promptContent: some View {
        switch practiceMode {
        case .fullScript:
            exactPhraseBlock
            scriptBodyText
            cueWordsBlock
        case .cueWords:
            exactPhraseBlock
            cueWordsOrEmpty
            if isScriptRevealed {
                Divider()
                scriptBodyText
            }
        case .memory:
            if isScriptRevealed {
                exactPhraseBlock
                scriptBodyText
                cueWordsBlock
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Script Hidden for Recall", systemImage: "eye.slash")
                        .font(.subheadline.weight(.semibold))
                    Text("Deliver this section from memory. Tap Reveal Script only if needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var exactPhraseBlock: some View {
        if let exactPhrase = section.exactPhrase,
           !exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Exact Phrase", systemImage: "quote.opening")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(exactPhrase)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var cueWordsBlock: some View {
        if !section.cueWords.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Cue Words", systemImage: "tag")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(section.cueWords.enumerated()), id: \.offset) { _, word in
                    Text("• \(word)")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var cueWordsOrEmpty: some View {
        if section.cueWords.isEmpty {
            Text("No cue words saved for this section. Reveal the script below if needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            cueWordsBlock
        }
    }

    private var scriptBodyText: some View {
        Text(section.text)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("fullRunRevealedScriptText")
    }

    private var revealButton: some View {
        Button(action: onToggleReveal) {
            Label(
                isScriptRevealed ? "Hide Script" : "Reveal Script",
                systemImage: isScriptRevealed ? "eye.slash" : "eye"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(isScriptRevealed ? "Hide Script" : "Reveal Script")
        .accessibilityValue(revealCount == 1 ? "1 reveal" : "\(revealCount) reveals")
        .accessibilityHint(
            isScriptRevealed
                ? "Hides the script for this section."
                : "Shows the current section script and increments the run reveal counter."
        )
        .accessibilityIdentifier("fullRunRevealScriptButton")
    }
}
