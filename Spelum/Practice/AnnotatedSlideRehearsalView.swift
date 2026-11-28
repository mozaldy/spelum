import CoreGraphics
import SwiftUI

struct RehearsalChromeOptions: Sendable, Equatable {
    let showsHeader: Bool
    let showsArtwork: Bool
    let showsRevealButton: Bool

    static let full = RehearsalChromeOptions(
        showsHeader: true,
        showsArtwork: true,
        showsRevealButton: true
    )

    static let scriptOnly = RehearsalChromeOptions(
        showsHeader: false,
        showsArtwork: false,
        showsRevealButton: false
    )
}

struct AnnotatedSlideRehearsalView: View {
    let slides: [ResolvedRehearsalSlide]
    let activeSlideIndex: Int
    let sectionPositionLabel: String?
    let sectionTitle: String
    let exactPhrase: String?
    let cueWords: [String]
    let practiceMode: PracticeMode
    let isScriptRevealed: Bool
    let revealCount: Int
    let isActiveTake: Bool
    let isAccessibilitySize: Bool
    let theme: RehearsalSurfaceTheme
    let chrome: RehearsalChromeOptions
    let storageRootURL: URL
    let fillsAvailableHeight: Bool
    let scriptScrollMaxHeight: CGFloat?
    let scriptAccessibilityIdentifier: String
    let revealButtonAccessibilityIdentifier: String
    let canGoPrevious: Bool
    let previousButtonLabel: String
    let onPrevious: (() -> Void)?
    let canGoNext: Bool
    let nextButtonLabel: String
    let onNext: (() -> Void)?
    let onSelectSlideIndex: ((Int) -> Void)?
    let onToggleReveal: () -> Void

    init(
        slides: [ResolvedRehearsalSlide],
        activeSlideIndex: Int,
        sectionPositionLabel: String? = nil,
        sectionTitle: String,
        exactPhrase: String?,
        cueWords: [String],
        practiceMode: PracticeMode,
        isScriptRevealed: Bool,
        revealCount: Int,
        isActiveTake: Bool,
        isAccessibilitySize: Bool,
        theme: RehearsalSurfaceTheme,
        chrome: RehearsalChromeOptions = .full,
        storageRootURL: URL = SlideDeckStorage.defaultStorageRootURL(),
        fillsAvailableHeight: Bool = false,
        scriptScrollMaxHeight: CGFloat? = nil,
        scriptAccessibilityIdentifier: String = "practiceRevealedScriptText",
        revealButtonAccessibilityIdentifier: String = "revealScriptButton",
        canGoPrevious: Bool = false,
        previousButtonLabel: String = "Previous",
        onPrevious: (() -> Void)? = nil,
        canGoNext: Bool = false,
        nextButtonLabel: String = "Next",
        onNext: (() -> Void)? = nil,
        onSelectSlideIndex: ((Int) -> Void)? = nil,
        onToggleReveal: @escaping () -> Void
    ) {
        self.slides = slides
        self.activeSlideIndex = activeSlideIndex
        self.sectionPositionLabel = sectionPositionLabel
        self.sectionTitle = sectionTitle
        self.exactPhrase = exactPhrase
        self.cueWords = cueWords
        self.practiceMode = practiceMode
        self.isScriptRevealed = isScriptRevealed
        self.revealCount = revealCount
        self.isActiveTake = isActiveTake
        self.isAccessibilitySize = isAccessibilitySize
        self.theme = theme
        self.chrome = chrome
        self.storageRootURL = storageRootURL
        self.fillsAvailableHeight = fillsAvailableHeight
        self.scriptScrollMaxHeight = scriptScrollMaxHeight
        self.scriptAccessibilityIdentifier = scriptAccessibilityIdentifier
        self.revealButtonAccessibilityIdentifier = revealButtonAccessibilityIdentifier
        self.canGoPrevious = canGoPrevious
        self.previousButtonLabel = previousButtonLabel
        self.onPrevious = onPrevious
        self.canGoNext = canGoNext
        self.nextButtonLabel = nextButtonLabel
        self.onNext = onNext
        self.onSelectSlideIndex = onSelectSlideIndex
        self.onToggleReveal = onToggleReveal
    }

    private var clampedSlideIndex: Int {
        guard !slides.isEmpty else { return 0 }
        return min(max(activeSlideIndex, 0), slides.count - 1)
    }

    var activeSlide: ResolvedRehearsalSlide? {
        guard slides.indices.contains(clampedSlideIndex) else { return nil }
        return slides[clampedSlideIndex]
    }

    var visiblePromptState: RehearsalVisiblePromptState {
        RehearsalVisiblePromptState.resolve(
            slide: activeSlide,
            exactPhrase: exactPhrase,
            cueWords: cueWords,
            practiceMode: practiceMode,
            isScriptRevealed: isScriptRevealed
        )
    }

    private var shouldConcealSlideTitle: Bool {
        visiblePromptState.shouldConcealSlideTitle
    }

    private var showSlidePositionHeader: Bool {
        slides.count > 1
            || activeSlide?.isExplicitSlide == true
            || activeSlide?.hasSlideArtwork == true
            || sectionPositionLabel != nil
    }

    private var showNavigationControls: Bool {
        onPrevious != nil || onNext != nil
    }

    var body: some View {
        let promptState = visiblePromptState
        VStack(alignment: .leading, spacing: 12) {
            if chrome.showsHeader, showSlidePositionHeader, let slide = activeSlide {
                positionAndNavigationHeader(for: slide, promptState: promptState)
            }

            if chrome.showsArtwork,
               let slide = activeSlide,
               let pdfURL = slide.resolvedDeckURL(storageRootURL: storageRootURL),
               let pageIndex = slide.pdfPageIndex {
                SlideArtworkView(
                    pdfURL: pdfURL,
                    pageIndex: pageIndex,
                    aspectRatio: slide.aspectRatio,
                    slideNumber: slide.slideIndex + 1,
                    totalSlides: slide.totalSlidesInSection,
                    visibleSlideTitle: promptState.visibleSlideTitle,
                    maxHeight: artworkMaxHeight,
                    isDarkStage: theme.isDarkStage
                )
            }

            scriptContentContainer(promptState: promptState)

            if chrome.showsRevealButton, practiceMode.supportsReveal {
                revealControlButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("annotatedSlideRehearsalView")
    }

    private var artworkMaxHeight: CGFloat {
        if theme.isDarkStage {
            return isAccessibilitySize ? 150 : 210
        }
        return isAccessibilitySize ? 160 : 220
    }

    private func positionAndNavigationHeader(
        for slide: ResolvedRehearsalSlide,
        promptState: RehearsalVisiblePromptState
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(positionSummaryText(for: slide))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(secondaryColor)
                        .accessibilityIdentifier("rehearsalSlidePositionLabel")

                    if let visibleTitle = promptState.visibleSlideTitle {
                        Text(visibleTitle)
                            .font(.headline)
                            .foregroundStyle(primaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("rehearsalSlideTitleLabel")
                    }
                }

                Spacer(minLength: 6)

                if let onSelectSlideIndex, slides.count > 1 {
                    slidePickerMenu(onSelect: onSelectSlideIndex)
                }
            }

            if showNavigationControls {
                slideNavigationRow
            }
        }
    }

    private func positionSummaryText(for slide: ResolvedRehearsalSlide) -> String {
        var parts: [String] = []
        if let sectionPositionLabel, !sectionPositionLabel.isEmpty {
            parts.append(sectionPositionLabel)
        }
        if slides.count > 1 || slide.isExplicitSlide || slide.hasSlideArtwork {
            parts.append(slide.positionLabel)
        }
        if let pageIndex = slide.pdfPageIndex {
            parts.append("Page \(pageIndex + 1)")
        }
        return parts.joined(separator: " · ")
    }

    private func slidePickerMenu(onSelect: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(slides) { item in
                Button {
                    onSelect(item.slideIndex)
                } label: {
                    let label = shouldConcealSlideTitle
                        ? item.positionLabel
                        : "\(item.slideIndex + 1). \(item.slideTitle)"
                    if item.slideIndex == clampedSlideIndex {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Label("Slides", systemImage: "rectangle.stack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.isDarkStage ? .white : Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    theme.isDarkStage ? Color.white.opacity(0.16) : Color.accentColor.opacity(0.12),
                    in: Capsule()
                )
        }
        .accessibilityLabel("Jump to slide in \(sectionTitle)")
        .accessibilityIdentifier("rehearsalSlidePickerMenu")
    }
}
