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
    let storageRootURL: URL
    let canGoPrevious: Bool
    let previousButtonLabel: String
    let onPrevious: (() -> Void)?
    let canGoNext: Bool
    let nextButtonLabel: String
    let onNext: (() -> Void)?
    let onSelectSlideIndex: ((Int) -> Void)?
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
        storageRootURL: URL = SlideDeckStorage.defaultStorageRootURL(),
        canGoPrevious: Bool = false,
        previousButtonLabel: String = "Previous",
        onPrevious: (() -> Void)? = nil,
        canGoNext: Bool = false,
        nextButtonLabel: String = "Next",
        onNext: (() -> Void)? = nil,
        onSelectSlideIndex: ((Int) -> Void)? = nil,
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
        self.storageRootURL = storageRootURL
        self.canGoPrevious = canGoPrevious
        self.previousButtonLabel = previousButtonLabel
        self.onPrevious = onPrevious
        self.canGoNext = canGoNext
        self.nextButtonLabel = nextButtonLabel
        self.onNext = onNext
        self.onSelectSlideIndex = onSelectSlideIndex
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
            storageRootURL: storageRootURL,
            fillsAvailableHeight: !isAccessibilitySize,
            scriptScrollMaxHeight: nil,
            scriptAccessibilityIdentifier: "fullRunFullscreenScriptText",
            revealButtonAccessibilityIdentifier: "fullRunFullscreenRevealButton",
            canGoPrevious: canGoPrevious,
            previousButtonLabel: previousButtonLabel,
            onPrevious: onPrevious,
            canGoNext: canGoNext,
            nextButtonLabel: nextButtonLabel,
            onNext: onNext,
            onSelectSlideIndex: onSelectSlideIndex,
            onToggleReveal: onToggleReveal
        )
    }

    var visiblePromptState: RehearsalVisiblePromptState {
        rehearsalView.visiblePromptState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            rehearsalView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
}
