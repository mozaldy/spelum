import Foundation

nonisolated enum SlidePairingRowStatus: Equatable, Hashable, Sendable {
    case scriptOnly
    case paired
    case unmatchedHeading
    case unmatchedPDFPage
}

nonisolated struct SlidePairingPreviewRow: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let orderIndex: Int
    let status: SlidePairingRowStatus
    let sectionTitle: String?
    let slideHeadingTitle: String?
    let firstSpokenLine: String?
    let hasOnlyDirectionsOrNoSpeech: Bool
    let pdfPageIndex: Int?
    let pdfAspectRatio: Double?
}

nonisolated struct SlidePairingPlan: Equatable, Sendable {
    let parsedScript: ParsedAnnotatedScript
    let pdfPageCount: Int?
    let rows: [SlidePairingPreviewRow]
    let explicitHeadingCount: Int
    let pairedCount: Int
    let unmatchedHeadingCount: Int
    let unmatchedPageCount: Int
    let isValidForImport: Bool
    let mismatchSummary: String?

    var hasPDF: Bool {
        pdfPageCount != nil
    }

    var hasMismatch: Bool {
        hasPDF && !isValidForImport
    }

    static func build(
        scriptText: String,
        pdfPageCount: Int?,
        pdfAspectRatios: [Double] = []
    ) -> SlidePairingPlan {
        let parsed = AnnotatedScriptParser.parseDocument(scriptText)
        let isScriptNonEmpty = !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let explicitSlides = parsed.explicitSlides
        let sectionTitleByIndex = Dictionary(
            uniqueKeysWithValues: parsed.sections.map { ($0.index, $0.title) }
        )

        guard let pageCount = pdfPageCount else {
            return buildScriptOnlyPlan(
                parsed: parsed,
                explicitSlides: explicitSlides,
                sectionTitleByIndex: sectionTitleByIndex,
                isScriptNonEmpty: isScriptNonEmpty
            )
        }

        let headingCount = explicitSlides.count
        let pairedCount = min(headingCount, pageCount)
        let unmatchedHeadings = max(0, headingCount - pageCount)
        let unmatchedPages = max(0, pageCount - headingCount)
        let rows = buildPairedRows(
            explicitSlides: explicitSlides,
            sectionTitleByIndex: sectionTitleByIndex,
            pageCount: pageCount,
            pdfAspectRatios: pdfAspectRatios
        )
        let isValid = isScriptNonEmpty && headingCount > 0 && headingCount == pageCount
        let summary = buildMismatchSummary(
            headingCount: headingCount,
            pageCount: pageCount,
            unmatchedHeadings: unmatchedHeadings,
            unmatchedPages: unmatchedPages
        )
        return SlidePairingPlan(
            parsedScript: parsed,
            pdfPageCount: pageCount,
            rows: rows,
            explicitHeadingCount: headingCount,
            pairedCount: pairedCount,
            unmatchedHeadingCount: unmatchedHeadings,
            unmatchedPageCount: unmatchedPages,
            isValidForImport: isValid,
            mismatchSummary: summary
        )
    }

    private static func buildScriptOnlyPlan(
        parsed: ParsedAnnotatedScript,
        explicitSlides: [ParsedScriptSlide],
        sectionTitleByIndex: [Int: String],
        isScriptNonEmpty: Bool
    ) -> SlidePairingPlan {
        let rows = explicitSlides.enumerated().map { index, slide in
            SlidePairingPreviewRow(
                id: "script-\(index)",
                orderIndex: index,
                status: .scriptOnly,
                sectionTitle: sectionTitleByIndex[slide.sectionIndex],
                slideHeadingTitle: slide.displayTitle,
                firstSpokenLine: slide.firstSpokenLine,
                hasOnlyDirectionsOrNoSpeech: slide.hasOnlyDirectionsOrNoSpeech,
                pdfPageIndex: nil,
                pdfAspectRatio: nil
            )
        }
        return SlidePairingPlan(
            parsedScript: parsed,
            pdfPageCount: nil,
            rows: rows,
            explicitHeadingCount: explicitSlides.count,
            pairedCount: 0,
            unmatchedHeadingCount: 0,
            unmatchedPageCount: 0,
            isValidForImport: isScriptNonEmpty,
            mismatchSummary: nil
        )
    }

    private static func buildPairedRows(
        explicitSlides: [ParsedScriptSlide],
        sectionTitleByIndex: [Int: String],
        pageCount: Int,
        pdfAspectRatios: [Double]
    ) -> [SlidePairingPreviewRow] {
        let headingCount = explicitSlides.count
        let totalRows = max(headingCount, pageCount)
        return (0 ..< totalRows).map { index in
            let slide = index < headingCount ? explicitSlides[index] : nil
            let pageIndex = index < pageCount ? index : nil
            let aspectRatio = (pageIndex != nil && index < pdfAspectRatios.count)
                ? pdfAspectRatios[index]
                : nil
            let status: SlidePairingRowStatus
            if slide != nil && pageIndex != nil {
                status = .paired
            } else if slide != nil {
                status = .unmatchedHeading
            } else {
                status = .unmatchedPDFPage
            }
            return SlidePairingPreviewRow(
                id: "pair-\(index)",
                orderIndex: index,
                status: status,
                sectionTitle: slide.flatMap { sectionTitleByIndex[$0.sectionIndex] },
                slideHeadingTitle: slide?.displayTitle,
                firstSpokenLine: slide?.firstSpokenLine,
                hasOnlyDirectionsOrNoSpeech: slide?.hasOnlyDirectionsOrNoSpeech ?? false,
                pdfPageIndex: pageIndex,
                pdfAspectRatio: aspectRatio
            )
        }
    }

    private static func buildMismatchSummary(
        headingCount: Int,
        pageCount: Int,
        unmatchedHeadings: Int,
        unmatchedPages: Int
    ) -> String? {
        guard headingCount != pageCount || headingCount == 0 else { return nil }
        let pageNoun = pageCount == 1 ? "page" : "pages"
        let headingNoun = headingCount == 1 ? "slide heading" : "slide headings"
        if headingCount == 0 {
            return "PDF has \(pageCount) \(pageNoun), but the script has no ## slide headings. " +
                "Add one ## heading per slide or remove the PDF to import script-only."
        }
        if unmatchedHeadings > 0 {
            let extraNoun = unmatchedHeadings == 1 ? "heading" : "headings"
            return "\(headingCount) \(headingNoun) for \(pageCount) PDF \(pageNoun): " +
                "\(unmatchedHeadings) unmatched \(extraNoun). Edit the script, replace the PDF, or remove the PDF."
        }
        let extraNoun = unmatchedPages == 1 ? "page" : "pages"
        return "\(headingCount) \(headingNoun) for \(pageCount) PDF \(pageNoun): " +
            "\(unmatchedPages) unmatched \(extraNoun). Add ## headings, replace the PDF, or remove the PDF."
    }
}
