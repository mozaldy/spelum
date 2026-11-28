import CoreGraphics
import Foundation

nonisolated struct ResolvedRehearsalSlide: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let slideIndex: Int
    let totalSlidesInSection: Int
    let sectionTitle: String
    let slideTitle: String
    let isExplicitSlide: Bool
    let blocks: [AnnotatedScriptBlock]
    let hasOnlyDirectionsOrNoSpeech: Bool
    let deckRelativePath: String?
    let pdfPageIndex: Int?
    let aspectRatio: CGFloat

    var hasSlideArtwork: Bool {
        deckRelativePath != nil && pdfPageIndex != nil
    }

    var positionLabel: String {
        "Slide \(slideIndex + 1) of \(max(totalSlidesInSection, 1))"
    }

    func resolvedDeckURL(storageRootURL: URL) -> URL? {
        guard let deckRelativePath else { return nil }
        return try? SlideDeckStorage.resolvedDeckURL(
            for: deckRelativePath,
            storageRootURL: storageRootURL
        )
    }
}

nonisolated enum RehearsalSlideResolver {
    static func resolveSlides(
        sectionIdentifier: String,
        sectionTitle: String,
        rawText: String,
        slideReferences: [SectionSlideReference]
    ) -> [ResolvedRehearsalSlide] {
        let parsedSection = AnnotatedScriptParser.parseSection(
            rawText,
            sectionTitle: sectionTitle
        )
        let parsedSlides = parsedSection.slides
        guard !parsedSlides.isEmpty else {
            let fallbackRef = slideReferences.first
            return [
                ResolvedRehearsalSlide(
                    id: "\(sectionIdentifier)-slide-0",
                    slideIndex: 0,
                    totalSlidesInSection: 1,
                    sectionTitle: sectionTitle,
                    slideTitle: sectionTitle,
                    isExplicitSlide: false,
                    blocks: [],
                    hasOnlyDirectionsOrNoSpeech: true,
                    deckRelativePath: fallbackRef?.deckRelativePath,
                    pdfPageIndex: fallbackRef?.pdfPageIndex,
                    aspectRatio: fallbackRef?.resolvedAspectRatio ?? (16.0 / 9.0)
                )
            ]
        }

        let orderedRefs = slideReferences.sorted { $0.slideOrderIndex < $1.slideOrderIndex }
        let hasExplicitSlides = parsedSlides.contains(where: \.isExplicitSlide)
        let total = parsedSlides.count

        var explicitCursor = 0
        return parsedSlides.enumerated().map { index, slide in
            let reference: SectionSlideReference?
            if slide.isExplicitSlide {
                reference = explicitCursor < orderedRefs.count ? orderedRefs[explicitCursor] : nil
                explicitCursor += 1
            } else if !hasExplicitSlides && total == 1 && orderedRefs.count == 1 {
                reference = orderedRefs[0]
            } else {
                reference = nil
            }

            return ResolvedRehearsalSlide(
                id: "\(sectionIdentifier)-slide-\(index)",
                slideIndex: index,
                totalSlidesInSection: total,
                sectionTitle: sectionTitle,
                slideTitle: slide.displayTitle,
                isExplicitSlide: slide.isExplicitSlide,
                blocks: slide.blocks,
                hasOnlyDirectionsOrNoSpeech: slide.hasOnlyDirectionsOrNoSpeech,
                deckRelativePath: reference?.deckRelativePath,
                pdfPageIndex: reference?.pdfPageIndex,
                aspectRatio: reference?.resolvedAspectRatio ?? (16.0 / 9.0)
            )
        }
    }

    @MainActor
    static func resolveSlides(for section: SectionRevisionRecord) -> [ResolvedRehearsalSlide] {
        resolveSlides(
            sectionIdentifier: section.revisionID.uuidString.lowercased(),
            sectionTitle: section.title,
            rawText: section.text,
            slideReferences: section.slideReferences
        )
    }

    @MainActor
    static func resolveSlides(for section: FullRunSectionSnapshot) -> [ResolvedRehearsalSlide] {
        resolveSlides(
            sectionIdentifier: section.sectionRevisionID.uuidString.lowercased(),
            sectionTitle: section.title,
            rawText: section.text,
            slideReferences: section.resolvedSlideReferences
        )
    }
}

nonisolated struct RehearsalVisiblePromptState: Equatable, Sendable {
    let shouldConcealSlideTitle: Bool
    let visibleSlideTitle: String?
    let visibleExactPhrase: String?
    let visibleCueWords: [String]
    let showsCueWordsEmptyNotice: Bool
    let showsAnnotatedScript: Bool
    let visibleBlocks: [AnnotatedScriptBlock]
    let showsMemoryHiddenPrompt: Bool

    var renderedAccessibilityStrings: [String] {
        var result: [String] = []
        if let visibleSlideTitle {
            result.append(visibleSlideTitle)
        }
        if let visibleExactPhrase {
            result.append(visibleExactPhrase)
        }
        result.append(contentsOf: visibleCueWords)
        if showsMemoryHiddenPrompt {
            result.append("Script Hidden for Recall")
        }
        if showsAnnotatedScript {
            for block in visibleBlocks {
                switch block {
                case .speech(_, let tokens, _):
                    result.append(AnnotatedScriptInlineParser.accessibleDescription(for: tokens))
                case .direction(_, _, let text):
                    result.append("Direction: \(text)")
                }
            }
        }
        return result
    }

    static func resolve(
        slide: ResolvedRehearsalSlide?,
        exactPhrase: String?,
        cueWords: [String],
        practiceMode: PracticeMode,
        isScriptRevealed: Bool
    ) -> RehearsalVisiblePromptState {
        let concealTitle = practiceMode == .memory && !isScriptRevealed
        let visibleTitle: String? = if !concealTitle, let slide,
            slide.isExplicitSlide || slide.totalSlidesInSection > 1 {
            slide.slideTitle
        } else {
            nil
        }
        let trimmedExact = exactPhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyExact = (trimmedExact?.isEmpty == false) ? trimmedExact : nil

        switch practiceMode {
        case .fullScript:
            return RehearsalVisiblePromptState(
                shouldConcealSlideTitle: false,
                visibleSlideTitle: visibleTitle,
                visibleExactPhrase: nonEmptyExact,
                visibleCueWords: cueWords,
                showsCueWordsEmptyNotice: false,
                showsAnnotatedScript: true,
                visibleBlocks: slide?.blocks ?? [],
                showsMemoryHiddenPrompt: false
            )
        case .cueWords:
            return RehearsalVisiblePromptState(
                shouldConcealSlideTitle: false,
                visibleSlideTitle: visibleTitle,
                visibleExactPhrase: nonEmptyExact,
                visibleCueWords: cueWords,
                showsCueWordsEmptyNotice: cueWords.isEmpty,
                showsAnnotatedScript: isScriptRevealed,
                visibleBlocks: isScriptRevealed ? (slide?.blocks ?? []) : [],
                showsMemoryHiddenPrompt: false
            )
        case .memory:
            return RehearsalVisiblePromptState(
                shouldConcealSlideTitle: concealTitle,
                visibleSlideTitle: visibleTitle,
                visibleExactPhrase: isScriptRevealed ? nonEmptyExact : nil,
                visibleCueWords: isScriptRevealed ? cueWords : [],
                showsCueWordsEmptyNotice: false,
                showsAnnotatedScript: isScriptRevealed,
                visibleBlocks: isScriptRevealed ? (slide?.blocks ?? []) : [],
                showsMemoryHiddenPrompt: !isScriptRevealed
            )
        }
    }
}
