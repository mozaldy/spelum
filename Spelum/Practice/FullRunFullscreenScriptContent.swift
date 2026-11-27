import SwiftUI

struct FullRunFullscreenScriptContent: View {
    let section: FullRunSectionSnapshot
    let practiceMode: PracticeMode
    let isScriptRevealed: Bool
    let revealCount: Int
    let isAccessibilitySize: Bool
    let onToggleReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitleHeader

            if let handoffCue = section.handoffCueText, !handoffCue.isEmpty {
                handoffCueCard(cue: handoffCue)
            }

            if section.purpose == .demonstration {
                Label(
                    "Demonstration — intentional silence stays in the continuous recording timeline.",
                    systemImage: "play.display"
                )
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fullRunFullscreenSilentDemoNote")
            }

            promptContent

            if practiceMode.supportsReveal {
                revealButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("fullRunFullscreenScriptContent")
    }

    private var sectionTitleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(section.talkSectionIndex + 1). \(section.title)")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Label(section.speakerSummary, systemImage: section.speakerRole.symbolName)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
            } else {
                HStack(spacing: 12) {
                    Label(section.speakerSummary, systemImage: section.speakerRole.symbolName)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private func handoffCueCard(cue: String) -> some View {
        let heading: String
        if section.handoffIsSpeakerChange, let prevSpeaker = section.handoffPrecedingSpeaker {
            heading = "Handoff from \(prevSpeaker)"
        } else if let prevTitle = section.handoffPrecedingSectionTitle {
            heading = "Previous line (\(prevTitle))"
        } else {
            heading = "Handoff Cue"
        }

        return VStack(alignment: .leading, spacing: 6) {
            Label(heading, systemImage: "arrow.triangle.turn.up.right.diamond")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.72, green: 0.90, blue: 1.0))
            Text("“\(cue)”")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullRunFullscreenHandoffCue")
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
                    .overlay(Color.white.opacity(0.25))
                scriptBodyText
            }
        case .memory:
            if isScriptRevealed {
                exactPhraseBlock
                scriptBodyText
                cueWordsBlock
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Script Hidden for Recall", systemImage: "eye.slash")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Deliver this section from memory. Tap Reveal Script only if needed.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var exactPhraseBlock: some View {
        if let exactPhrase = section.exactPhrase,
           !exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Exact Phrase", systemImage: "quote.opening")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.72, green: 0.90, blue: 1.0))
                Text(exactPhrase)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.26), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var cueWordsBlock: some View {
        if !section.cueWords.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Cue Words", systemImage: "tag")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                ForEach(Array(section.cueWords.enumerated()), id: \.offset) { _, word in
                    Text("• \(word)")
                        .font(isAccessibilitySize ? .body : .title3.weight(.medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var cueWordsOrEmpty: some View {
        if section.cueWords.isEmpty {
            Text("No cue words saved for this section. Reveal the script below if needed.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            cueWordsBlock
        }
    }

    private var scriptBodyText: some View {
        Text(section.text)
            .font(isAccessibilitySize ? .body : .title3)
            .lineSpacing(6)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("fullRunFullscreenScriptText")
    }

    private var revealButton: some View {
        Button(action: onToggleReveal) {
            Label(
                isScriptRevealed ? "Hide Script" : "Reveal Script",
                systemImage: isScriptRevealed ? "eye.slash" : "eye"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isScriptRevealed ? "Hide Script" : "Reveal Script")
        .accessibilityValue(revealCount == 1 ? "1 reveal" : "\(revealCount) reveals")
        .accessibilityHint(
            isScriptRevealed
                ? "Hides the script for this section."
                : "Shows the current section script and increments the run reveal counter."
        )
        .accessibilityIdentifier("fullRunFullscreenRevealButton")
    }
}
