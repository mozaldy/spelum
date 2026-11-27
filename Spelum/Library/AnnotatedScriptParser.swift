import Foundation

nonisolated enum AnnotatedScriptParser {
    static func parseDocument(_ sourceText: String) -> ParsedAnnotatedScript {
        let lines = splitPreservingLineEndings(sourceText)
        let rawSections = groupIntoSections(lines)
        let hasStructuredHeadings = lines.contains {
            isSectionHeading($0.content) || isSlideHeading($0.content)
        }

        var sections: [ParsedScriptSection] = []
        var allExplicitSlides: [ParsedScriptSlide] = []
        var nextExplicitSlideIndex = 0

        for (sectionIndex, rawSection) in rawSections.enumerated() {
            let sectionTitle = resolvedSectionTitle(
                rawTitle: rawSection.rawHeadingTitle,
                sectionIndex: sectionIndex
            )
            let rawSectionText = buildRawSectionText(for: rawSection)
            let slides = buildSlides(
                from: rawSection.bodyLines,
                sectionIndex: sectionIndex,
                sectionTitle: sectionTitle,
                nextExplicitSlideIndex: &nextExplicitSlideIndex
            )
            allExplicitSlides.append(contentsOf: slides.filter(\.isExplicitSlide))
            sections.append(
                ParsedScriptSection(
                    index: sectionIndex,
                    isExplicitSection: rawSection.isExplicitSection,
                    rawHeadingLine: rawSection.rawHeadingLine,
                    rawHeadingTitle: rawSection.rawHeadingTitle,
                    title: sectionTitle,
                    rawText: rawSectionText,
                    slides: slides
                )
            )
        }

        return ParsedAnnotatedScript(
            sourceText: sourceText,
            sections: sections,
            explicitSlides: allExplicitSlides,
            hasStructuredHeadings: hasStructuredHeadings
        )
    }

    static func parseSection(
        _ sectionText: String,
        sectionTitle: String = "Section 1",
        sectionIndex: Int = 0
    ) -> ParsedScriptSection {
        let lines = splitPreservingLineEndings(sectionText)
        let filteredBodyLines = lines.filter { !isSectionHeading($0.content) }
        var nextExplicitSlideIndex = 0
        let slides = buildSlides(
            from: filteredBodyLines,
            sectionIndex: sectionIndex,
            sectionTitle: sectionTitle,
            nextExplicitSlideIndex: &nextExplicitSlideIndex
        )
        return ParsedScriptSection(
            index: sectionIndex,
            isExplicitSection: false,
            rawHeadingLine: nil,
            rawHeadingTitle: sectionTitle,
            title: sectionTitle,
            rawText: sectionText,
            slides: slides
        )
    }

    static func spokenText(from text: String) -> String {
        parseDocument(text).spokenText
    }

    static func firstSpokenLine(in text: String) -> String? {
        parseDocument(text).firstSpokenLine
    }

    static func lastSpokenLine(in text: String) -> String? {
        parseDocument(text).lastSpokenLine
    }

    static func extractTimingStructure(
        from scriptText: String,
        knownSpeakerNames: [String] = []
    ) -> ScriptStructure {
        let lines = splitPreservingLineEndings(scriptText)
        let normalizedSpeakers = Set(
            knownSpeakerNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        var spokenLines: [String] = []
        var directionRecords: [(raw: String, spokenIndexBefore: Int)] = []
        var spokenTokenCountSoFar = 0

        for rawLine in lines {
            if isSectionHeading(rawLine.content) || isSlideHeading(rawLine.content) {
                continue
            }
            let parsed = AnnotatedScriptInlineParser.parseLine(rawLine.rawSlice, startingBlockID: 0)
            for block in parsed.blocks {
                switch block {
                case .speech(_, _, let spoken):
                    if !spoken.isEmpty {
                        spokenTokenCountSoFar += EnglishWordTokenizer.tokenize(spoken).count
                    }
                case .direction(_, let rawBracketed, _):
                    directionRecords.append((raw: rawBracketed, spokenIndexBefore: spokenTokenCountSoFar))
                }
            }
            if let combined = parsed.spokenLine, !combined.isEmpty {
                spokenLines.append(combined)
            }
        }

        let totalSpokenTokens = spokenTokenCountSoFar
        var hasInterior = false
        var hasTrailing = false
        for record in directionRecords {
            let beforeHasWord = record.spokenIndexBefore > 0
            let afterHasWord = record.spokenIndexBefore < totalSpokenTokens
            if beforeHasWord && afterHasWord {
                hasInterior = true
            } else if beforeHasWord && !afterHasWord {
                hasTrailing = true
            }
        }

        let spokenText = spokenLines.joined(separator: "\n")
        let candidatePhrases = extractSpokenCandidatePhrases(
            from: spokenLines,
            knownSpeakerNames: normalizedSpeakers
        )
        return ScriptStructure(
            spokenText: spokenText,
            stageDirections: directionRecords.map(\.raw),
            hasInteriorStageDirection: hasInterior,
            hasTrailingStageDirection: hasTrailing,
            spokenCandidatePhrases: candidatePhrases
        )
    }

    static func isSectionHeading(_ lineContent: String) -> Bool {
        lineContent == "#" || lineContent.hasPrefix("# ")
    }

    static func isSlideHeading(_ lineContent: String) -> Bool {
        lineContent == "##" || lineContent.hasPrefix("## ")
    }
}
