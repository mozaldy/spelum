import SwiftUI

struct PracticeHeaderCard: View {
    let presentationTitle: String
    let section: SectionRevisionRecord
    let talkRevisionNumber: Int
    let isOlderRevision: Bool
    let hasUnsavedEditorDraft: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentationTitle)
                    Text("Revision \(talkRevisionNumber)")
                    Label(section.speaker, systemImage: section.speakerRole.symbolName)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text("\(presentationTitle) · Revision \(talkRevisionNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(section.speaker, systemImage: section.speakerRole.symbolName)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if isOlderRevision {
                Label("Practicing snapshotted Revision \(talkRevisionNumber)", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            if hasUnsavedEditorDraft {
                Label(
                    "Rehearsing saved Revision \(talkRevisionNumber). Unsaved edits in the script editor remain intact.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("unsavedDraftPreservedNotice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct PracticeModeCard: View {
    let selectedMode: PracticeMode
    let isEnabled: Bool
    let isAccessibilitySize: Bool
    let onSelectMode: (PracticeMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Practice Mode")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(PracticeMode.allCases) { mode in
                        Button {
                            onSelectMode(mode)
                        } label: {
                            HStack {
                                Label(mode.displayName, systemImage: mode.symbolName)
                                Spacer()
                                if selectedMode == mode {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(
                                selectedMode == mode
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(.tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEnabled)
                        .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                        .accessibilityIdentifier("practiceMode_\(mode.rawValue)")
                    }
                }
            } else {
                Picker(
                    "Practice Mode",
                    selection: Binding(
                        get: { selectedMode },
                        set: { onSelectMode($0) }
                    )
                ) {
                    ForEach(PracticeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!isEnabled)
                .accessibilityLabel("Practice Mode")
                .accessibilityIdentifier("practiceModePicker")
            }

            Text(selectedMode.guidanceText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PracticeHandoffCueCard: View {
    let handoff: HandoffContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HandoffAttributionView(context: handoff)

            if let cueText = handoff.effectiveCueText, !cueText.isEmpty {
                Text("“\(cueText)”")
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("practiceHandoffCueText")
            } else {
                Text("Opening section — begin directly with your first line.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PracticePromptCard: View {
    let section: SectionRevisionRecord
    let practiceMode: PracticeMode
    let isScriptRevealed: Bool
    let revealCount: Int
    let isActiveTake: Bool
    let onToggleReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            switch practiceMode {
            case .fullScript:
                exactPhraseBlock
                scriptBodyText
                cueWordsBlock
            case .cueWords:
                exactPhraseBlock
                cueWordsBlockOrEmpty
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
                    memoryHiddenPrompt
                }
            }

            if practiceMode.supportsReveal {
                revealControlButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(practiceMode.displayName, systemImage: practiceMode.symbolName)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if practiceMode.supportsReveal && (isActiveTake || revealCount > 0) {
                Text(revealCount == 1 ? "1 reveal" : "\(revealCount) reveals")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("practiceRevealCountLabel")
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
            VStack(alignment: .leading, spacing: 6) {
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
    private var cueWordsBlockOrEmpty: some View {
        if section.cueWords.isEmpty {
            Text("No cue words saved for this section yet. Reveal the script below if you need a prompt.")
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
            .accessibilityIdentifier("practiceRevealedScriptText")
    }

    private var memoryHiddenPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Script Hidden for Recall", systemImage: "eye.slash")
                .font(.headline)
            Text(
                "Read the handoff cue above, then deliver this section from memory. " +
                "Tap Reveal Script if you get stuck."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memoryHiddenPrompt")
    }

    private var revealControlButton: some View {
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
                ? "Hides the full script again."
                : "Shows the full section script and counts one reveal during an active take."
        )
        .accessibilityIdentifier("revealScriptButton")
    }
}

struct PracticeHistoryRow: View {
    let attempt: AttemptRecord
    let isCurrentSectionRevision: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerLayout

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(durationLabel)
                    Text(attempt.practiceMode.displayName)
                    Text(revealSummary)
                    if !attempt.markers.isEmpty {
                        Text(markerSummary)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(compactSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !isCurrentSectionRevision {
                Label("Revision \(attempt.talkRevisionNumber) (older)", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens saved take review and playback.")
    }

    @ViewBuilder
    private var headerLayout: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                statusBadge
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
                statusBadge
            }
        }
    }

    private var statusBadge: some View {
        Label(attempt.status.displayName, systemImage: attempt.status.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch attempt.status {
        case .ready: .green
        case .interrupted: .orange
        case .silentCompleted: .blue
        case .inProgress: .secondary
        }
    }

    private var durationLabel: String {
        if attempt.hasPlayableAudio {
            return RehearsalTimeFormatter.clockString(for: attempt.playableDuration)
        }
        if attempt.isSilentRecall {
            return "\(RehearsalTimeFormatter.clockString(for: attempt.elapsedDuration)) silent"
        }
        return "No audio"
    }

    private var revealSummary: String {
        attempt.revealCount == 1 ? "1 reveal" : "\(attempt.revealCount) reveals"
    }

    private var markerSummary: String {
        attempt.markers.count == 1 ? "1 marker" : "\(attempt.markers.count) markers"
    }

    private var compactSummary: String {
        var parts = [durationLabel, attempt.practiceMode.displayName, revealSummary]
        if !attempt.markers.isEmpty {
            parts.append(markerSummary)
        }
        return parts.joined(separator: " · ")
    }
}
