import SwiftUI

struct FullRunFullscreenScriptContent: View {
    let section: FullRunSectionSnapshot
    let slides: [ResolvedRehearsalSlide]
    let activeSlideIndex: Int
    let totalInRun: Int
    let practiceMode: PracticeMode
    let isScriptRevealed: Bool
    let revealCount: Int
    let isActiveTake: Bool
    let isAccessibilitySize: Bool
    let usesStageScroll: Bool
    let showsSlidePreview: Bool
    let storageRootURL: URL
    let onToggleReveal: () -> Void

    init(
        section: FullRunSectionSnapshot,
        slides: [ResolvedRehearsalSlide]? = nil,
        activeSlideIndex: Int = 0,
        totalInRun: Int = 1,
        practiceMode: PracticeMode,
        isScriptRevealed: Bool,
        revealCount: Int,
        isActiveTake: Bool = false,
        isAccessibilitySize: Bool,
        usesStageScroll: Bool,
        showsSlidePreview: Bool = true,
        storageRootURL: URL = SlideDeckStorage.defaultStorageRootURL(),
        onToggleReveal: @escaping () -> Void
    ) {
        self.section = section
        self.slides = slides ?? RehearsalSlideResolver.resolveSlides(for: section)
        self.activeSlideIndex = activeSlideIndex
        self.totalInRun = totalInRun
        self.practiceMode = practiceMode
        self.isScriptRevealed = isScriptRevealed
        self.revealCount = revealCount
        self.isActiveTake = isActiveTake
        self.isAccessibilitySize = isAccessibilitySize
        self.usesStageScroll = usesStageScroll
        self.showsSlidePreview = showsSlidePreview
        self.storageRootURL = storageRootURL
        self.onToggleReveal = onToggleReveal
    }

    var rehearsalView: AnnotatedSlideRehearsalView {
        AnnotatedSlideRehearsalView(
            slides: slides,
            activeSlideIndex: activeSlideIndex,
            sectionPositionLabel: "Section \(section.runIndex + 1) of \(max(totalInRun, 1))",
            sectionTitle: section.title,
            exactPhrase: section.exactPhrase,
            cueWords: section.cueWords,
            practiceMode: practiceMode,
            isScriptRevealed: isScriptRevealed,
            revealCount: revealCount,
            isActiveTake: isActiveTake,
            isAccessibilitySize: isAccessibilitySize,
            theme: .fullscreenStage,
            chrome: .scriptOnly,
            storageRootURL: storageRootURL,
            fillsAvailableHeight: !usesStageScroll,
            scriptScrollMaxHeight: nil,
            scriptAccessibilityIdentifier: "fullRunFullscreenScriptText",
            revealButtonAccessibilityIdentifier: "fullRunFullscreenRevealButton",
            onToggleReveal: onToggleReveal
        )
    }

    var visiblePromptState: RehearsalVisiblePromptState {
        rehearsalView.visiblePromptState
    }

    private var activeSlide: ResolvedRehearsalSlide? {
        rehearsalView.activeSlide
    }

    var body: some View {
        let promptState = visiblePromptState
        VStack(alignment: .leading, spacing: 10) {
            compactHeader(promptState: promptState)

            if let handoffCue = section.handoffCueText, !handoffCue.isEmpty {
                handoffCueCard(cue: handoffCue)
            }

            if section.purpose == .demonstration {
                Label(
                    "Demonstration — intentional silence stays in the recording.",
                    systemImage: "play.display"
                )
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fullRunFullscreenSilentDemoNote")
            }

            rehearsalView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("fullRunFullscreenScriptContent")
    }

    @ViewBuilder
    private func compactHeader(promptState: RehearsalVisiblePromptState) -> some View {
        if showsSlidePreview,
           let slide = activeSlide,
           let pdfURL = slide.resolvedDeckURL(storageRootURL: storageRootURL),
           let pageIndex = slide.pdfPageIndex {
            slideThumbnailHeader(
                slide: slide,
                pdfURL: pdfURL,
                pageIndex: pageIndex,
                promptState: promptState
            )
        } else {
            textOnlyHeader(promptState: promptState)
        }
    }

    @ViewBuilder
    private func slideThumbnailHeader(
        slide: ResolvedRehearsalSlide,
        pdfURL: URL,
        pageIndex: Int,
        promptState: RehearsalVisiblePromptState
    ) -> some View {
        let artwork = SlideArtworkView(
            pdfURL: pdfURL,
            pageIndex: pageIndex,
            aspectRatio: slide.aspectRatio,
            slideNumber: slide.slideIndex + 1,
            totalSlides: slide.totalSlidesInSection,
            visibleSlideTitle: promptState.visibleSlideTitle,
            maxHeight: isAccessibilitySize ? 104 : 64,
            isDarkStage: true,
            compact: true
        )

        let titleColumn = VStack(alignment: .leading, spacing: 2) {
            Text("\(section.talkSectionIndex + 1). \(section.title)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(isAccessibilitySize ? 2 : 1)
                .accessibilityAddTraits(.isHeader)

            if let visibleTitle = promptState.visibleSlideTitle, !visibleTitle.isEmpty {
                Text(visibleTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rehearsalSlideTitleLabel")

                Text("Page \(pageIndex + 1)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
            } else {
                Text("Slide \(slide.slideIndex + 1) of \(max(slide.totalSlidesInSection, 1)) · Page \(pageIndex + 1)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.70))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    artwork
                    titleColumn
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    artwork
                    titleColumn
                }
            }
        }
        .padding(.bottom, 2)
    }

    private func textOnlyHeader(promptState: RehearsalVisiblePromptState) -> some View {
        let slideTitle = promptState.visibleSlideTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDistinctSlideTitle = !(slideTitle?.isEmpty ?? true) && slideTitle != section.title
        return VStack(alignment: .leading, spacing: 2) {
            if hasDistinctSlideTitle, let slideTitle {
                Text("\(section.talkSectionIndex + 1). \(section.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(isAccessibilitySize ? 2 : 1)
                    .accessibilityAddTraits(.isHeader)

                Text(slideTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rehearsalSlideTitleLabel")
            } else {
                Text("\(section.talkSectionIndex + 1). \(section.title)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
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

        return VStack(alignment: .leading, spacing: 4) {
            Label(heading, systemImage: "arrow.triangle.turn.up.right.diamond")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(red: 0.72, green: 0.90, blue: 1.0))
            Text("“\(cue)”")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullRunFullscreenHandoffCue")
    }
}
