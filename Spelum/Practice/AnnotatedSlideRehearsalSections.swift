import SwiftUI

extension AnnotatedSlideRehearsalView {
    var slideNavigationRow: some View {
        HStack(spacing: 10) {
            if let onPrevious {
                Button(action: onPrevious) {
                    Label(previousButtonLabel, systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(navButtonForeground(enabled: canGoPrevious))
                        .background(navButtonBackground(enabled: canGoPrevious), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canGoPrevious)
                .accessibilityLabel(previousButtonLabel)
                .accessibilityIdentifier("rehearsalPreviousSlideButton")
            }

            if let onNext {
                Button(action: onNext) {
                    HStack(spacing: 4) {
                        Text(nextButtonLabel)
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(navButtonForeground(enabled: canGoNext))
                    .background(navButtonBackground(enabled: canGoNext), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canGoNext)
                .accessibilityLabel(nextButtonLabel)
                .accessibilityIdentifier("rehearsalNextSlideButton")
            }
        }
    }

    @ViewBuilder
    func scriptContentContainer(promptState: RehearsalVisiblePromptState) -> some View {
        let needsInternalScroll = fillsAvailableHeight
            || (scriptScrollMaxHeight != nil && activeSlide?.hasSlideArtwork == true)
        if needsInternalScroll {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear
                            .frame(height: 0)
                            .id("rehearsalSlideScriptTop")
                        promptContent(promptState: promptState)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.visible)
                .frame(
                    maxWidth: .infinity,
                    minHeight: fillsAvailableHeight ? 120 : min(220, scriptScrollMaxHeight ?? 260),
                    idealHeight: fillsAvailableHeight ? nil : scriptScrollMaxHeight,
                    maxHeight: fillsAvailableHeight ? .infinity : scriptScrollMaxHeight
                )
                .onChange(of: activeSlide?.id) { _, _ in
                    proxy.scrollTo("rehearsalSlideScriptTop", anchor: .top)
                }
            }
        } else {
            promptContent(promptState: promptState)
        }
    }

    @ViewBuilder
    func promptContent(promptState: RehearsalVisiblePromptState) -> some View {
        if promptState.showsMemoryHiddenPrompt {
            memoryHiddenPrompt
        } else {
            if let exactPhraseText = promptState.visibleExactPhrase {
                exactPhraseBlock(exactPhraseText)
            }
            if practiceMode == .cueWords {
                cueWordsSection(
                    words: promptState.visibleCueWords,
                    showEmptyNotice: promptState.showsCueWordsEmptyNotice
                )
                if promptState.showsAnnotatedScript {
                    Divider()
                        .overlay(theme.isDarkStage ? Color.white.opacity(0.25) : Color.clear)
                    annotatedScriptBlocks(blocks: promptState.visibleBlocks)
                }
            } else {
                if promptState.showsAnnotatedScript {
                    annotatedScriptBlocks(blocks: promptState.visibleBlocks)
                }
                cueWordsSection(words: promptState.visibleCueWords, showEmptyNotice: false)
            }
        }
    }

    @ViewBuilder
    func annotatedScriptBlocks(blocks: [AnnotatedScriptBlock]) -> some View {
        if let slide = activeSlide {
            AnnotatedScriptBlocksView(
                blocks: blocks,
                hasOnlyDirectionsOrNoSpeech: slide.hasOnlyDirectionsOrNoSpeech,
                isAccessibilitySize: isAccessibilitySize,
                theme: theme,
                scriptAccessibilityIdentifier: scriptAccessibilityIdentifier
            )
        }
    }

    func exactPhraseBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Exact Phrase", systemImage: "quote.opening")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.isDarkStage ? Color(red: 0.72, green: 0.90, blue: 1.0) : .accentColor)
            Text(text)
                .font(.body.weight(.semibold))
                .foregroundStyle(primaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            theme.isDarkStage ? Color.white.opacity(0.14) : Color.accentColor.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    func cueWordsSection(words: [String], showEmptyNotice: Bool) -> some View {
        if !words.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Cue Words", systemImage: "tag")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryColor)
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    Text("• \(word)")
                        .font(theme.isDarkStage && !isAccessibilitySize ? .title3.weight(.medium) : .body)
                        .foregroundStyle(primaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if showEmptyNotice {
            Text("No cue words saved for this section yet. Reveal the script below if you need a prompt.")
                .font(.footnote)
                .foregroundStyle(secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var memoryHiddenPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Script Hidden for Recall", systemImage: "eye.slash")
                .font(.headline)
                .foregroundStyle(primaryColor)
            Text("Deliver from memory. Tap Reveal Script only if you get stuck.")
                .font(.subheadline)
                .foregroundStyle(secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.isDarkStage ? 14 : 4)
        .background(
            theme.isDarkStage ? Color.white.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memoryHiddenPrompt")
    }

    var revealControlButton: some View {
        Group {
            if theme.isDarkStage {
                Button(action: onToggleReveal) {
                    revealLabel
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onToggleReveal) {
                    revealLabel
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityLabel(isScriptRevealed ? "Hide Script" : "Reveal Script")
        .accessibilityValue(revealCount == 1 ? "1 reveal" : "\(revealCount) reveals")
        .accessibilityHint(
            isScriptRevealed
                ? "Hides the full script again."
                : "Shows the script and counts one reveal during an active take."
        )
        .accessibilityIdentifier(revealButtonAccessibilityIdentifier)
    }

    var revealLabel: some View {
        Label(
            isScriptRevealed ? "Hide Script" : "Reveal Script",
            systemImage: isScriptRevealed ? "eye.slash" : "eye"
        )
    }

    var primaryColor: Color {
        theme.isDarkStage ? .white : .primary
    }

    var secondaryColor: Color {
        theme.isDarkStage ? .white.opacity(0.82) : .secondary
    }

    func navButtonForeground(enabled: Bool) -> Color {
        if theme.isDarkStage {
            return enabled ? .white : .white.opacity(0.35)
        }
        return enabled ? Color.accentColor : Color.secondary.opacity(0.5)
    }

    func navButtonBackground(enabled: Bool) -> Color {
        if theme.isDarkStage {
            return Color.white.opacity(enabled ? 0.16 : 0.06)
        }
        return enabled ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemGroupedBackground)
    }
}
