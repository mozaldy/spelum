import Foundation
import NaturalLanguage

nonisolated struct AnnotatedRawLine {
    let rawSlice: String
    let content: String
}

nonisolated struct AnnotatedRawSectionAccumulator {
    let isExplicitSection: Bool
    let rawHeadingLine: String?
    let rawHeadingTitle: String
    var bodyLines: [AnnotatedRawLine]
}

nonisolated struct AnnotatedRawSlideAccumulator {
    let isExplicitSlide: Bool
    let rawHeadingLine: String?
    let rawHeadingTitle: String
    var bodyLines: [AnnotatedRawLine]
}

nonisolated extension AnnotatedScriptParser {
    static func splitPreservingLineEndings(_ text: String) -> [AnnotatedRawLine] {
        guard !text.isEmpty else { return [] }
        var lines: [AnnotatedRawLine] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let range = text.lineRange(for: cursor ..< cursor)
            let rawSlice = String(text[range])
            let content = AnnotatedScriptInlineParser.stripLineEnding(rawSlice)
            lines.append(AnnotatedRawLine(rawSlice: rawSlice, content: content))
            cursor = range.upperBound
        }
        return lines
    }

    static func groupIntoSections(_ lines: [AnnotatedRawLine]) -> [AnnotatedRawSectionAccumulator] {
        let hasAnySectionHeading = lines.contains { isSectionHeading($0.content) }
        guard hasAnySectionHeading else {
            return [
                AnnotatedRawSectionAccumulator(
                    isExplicitSection: false,
                    rawHeadingLine: nil,
                    rawHeadingTitle: "",
                    bodyLines: lines
                )
            ]
        }

        var sections: [AnnotatedRawSectionAccumulator] = []
        var leadingLines: [AnnotatedRawLine] = []
        var current: AnnotatedRawSectionAccumulator?

        for line in lines {
            if isSectionHeading(line.content) {
                if let active = current {
                    sections.append(active)
                } else if hasSubstantiveContent(leadingLines) {
                    sections.append(
                        AnnotatedRawSectionAccumulator(
                            isExplicitSection: false,
                            rawHeadingLine: nil,
                            rawHeadingTitle: "",
                            bodyLines: leadingLines
                        )
                    )
                }
                leadingLines = []
                let title = String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                current = AnnotatedRawSectionAccumulator(
                    isExplicitSection: true,
                    rawHeadingLine: line.rawSlice,
                    rawHeadingTitle: title,
                    bodyLines: []
                )
            } else if current != nil {
                current?.bodyLines.append(line)
            } else {
                leadingLines.append(line)
            }
        }

        if let active = current {
            sections.append(active)
        }
        return sections
    }

    static func buildRawSectionText(for section: AnnotatedRawSectionAccumulator) -> String {
        let body = section.bodyLines.map(\.rawSlice).joined()
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        if let headingLine = section.rawHeadingLine {
            return headingLine
        }
        return body
    }

    static func buildSlides(
        from bodyLines: [AnnotatedRawLine],
        sectionIndex: Int,
        sectionTitle: String,
        nextExplicitSlideIndex: inout Int
    ) -> [ParsedScriptSlide] {
        let rawSlides = groupIntoSlides(bodyLines)
        var parsedSlides: [ParsedScriptSlide] = []

        for (localIndex, rawSlide) in rawSlides.enumerated() {
            let explicitIndex: Int?
            if rawSlide.isExplicitSlide {
                explicitIndex = nextExplicitSlideIndex
                nextExplicitSlideIndex += 1
            } else {
                explicitIndex = nil
            }

            let displayTitle: String
            if rawSlide.isExplicitSlide {
                let fallbackNumber = (explicitIndex ?? localIndex) + 1
                displayTitle = rawSlide.rawHeadingTitle.isEmpty
                    ? "Slide \(fallbackNumber)"
                    : rawSlide.rawHeadingTitle
            } else if rawSlides.count > 1 {
                displayTitle = "Intro Notes"
            } else {
                displayTitle = sectionTitle
            }

            var blocks: [AnnotatedScriptBlock] = []
            var spokenLines: [String] = []
            var stageDirections: [String] = []
            var nextBlockID = 0

            for line in rawSlide.bodyLines {
                let parsedLine = AnnotatedScriptInlineParser.parseLine(
                    line.rawSlice,
                    startingBlockID: nextBlockID
                )
                nextBlockID += parsedLine.blocks.count
                blocks.append(contentsOf: parsedLine.blocks)
                if let spoken = parsedLine.spokenLine {
                    spokenLines.append(spoken)
                }
                stageDirections.append(contentsOf: parsedLine.stageDirections)
            }

            let rawBody = rawSlide.bodyLines.map(\.rawSlice).joined()
            let rawSlice = (rawSlide.rawHeadingLine ?? "") + rawBody
            parsedSlides.append(
                ParsedScriptSlide(
                    id: "s\(sectionIndex)-sl\(localIndex)",
                    sectionIndex: sectionIndex,
                    indexInSection: localIndex,
                    explicitSlideIndex: explicitIndex,
                    isExplicitSlide: rawSlide.isExplicitSlide,
                    rawHeadingLine: rawSlide.rawHeadingLine,
                    rawHeadingTitle: rawSlide.rawHeadingTitle,
                    displayTitle: displayTitle,
                    rawBodyText: rawBody,
                    rawSliceText: rawSlice,
                    blocks: blocks,
                    spokenLines: spokenLines,
                    stageDirections: stageDirections
                )
            )
        }
        return parsedSlides
    }

    static func groupIntoSlides(_ bodyLines: [AnnotatedRawLine]) -> [AnnotatedRawSlideAccumulator] {
        let hasAnySlideHeading = bodyLines.contains { isSlideHeading($0.content) }
        guard hasAnySlideHeading else {
            return [
                AnnotatedRawSlideAccumulator(
                    isExplicitSlide: false,
                    rawHeadingLine: nil,
                    rawHeadingTitle: "",
                    bodyLines: bodyLines
                )
            ]
        }

        var slides: [AnnotatedRawSlideAccumulator] = []
        var leadingLines: [AnnotatedRawLine] = []
        var current: AnnotatedRawSlideAccumulator?

        for line in bodyLines {
            if isSlideHeading(line.content) {
                if let active = current {
                    slides.append(active)
                } else if hasSubstantiveContent(leadingLines) {
                    slides.append(
                        AnnotatedRawSlideAccumulator(
                            isExplicitSlide: false,
                            rawHeadingLine: nil,
                            rawHeadingTitle: "",
                            bodyLines: leadingLines
                        )
                    )
                }
                leadingLines = []
                let title = String(line.content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                current = AnnotatedRawSlideAccumulator(
                    isExplicitSlide: true,
                    rawHeadingLine: line.rawSlice,
                    rawHeadingTitle: title,
                    bodyLines: []
                )
            } else if current != nil {
                current?.bodyLines.append(line)
            } else {
                leadingLines.append(line)
            }
        }

        if let active = current {
            slides.append(active)
        }
        return slides
    }

    static func hasSubstantiveContent(_ lines: [AnnotatedRawLine]) -> Bool {
        lines.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func resolvedSectionTitle(rawTitle: String, sectionIndex: Int) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Section \(sectionIndex + 1)" : trimmed
    }

    static func extractSpokenCandidatePhrases(
        from spokenLines: [String],
        knownSpeakerNames: Set<String>
    ) -> [String] {
        var phrases: [String] = []
        for rawLine in spokenLines {
            let trimmed = stripKnownSpeakerPrefix(from: rawLine, knownSpeakerNames: knownSpeakerNames)
            guard !trimmed.isEmpty else { continue }
            let sentenceTokenizer = NLTokenizer(unit: .sentence)
            sentenceTokenizer.string = trimmed
            sentenceTokenizer.setLanguage(.english)
            sentenceTokenizer.enumerateTokens(in: trimmed.startIndex ..< trimmed.endIndex) { range, _ in
                let sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if EnglishWordTokenizer.tokenize(sentence).count >= 2 {
                    phrases.append(sentence)
                }
                return true
            }
        }
        return phrases
    }

    static func stripKnownSpeakerPrefix(
        from line: String,
        knownSpeakerNames: Set<String>
    ) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !knownSpeakerNames.isEmpty,
              let colonIndex = trimmed.firstIndex(of: ":") else {
            return trimmed
        }
        let prefix = String(trimmed[..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard knownSpeakerNames.contains(prefix) else {
            return trimmed
        }
        let remainderIndex = trimmed.index(after: colonIndex)
        let remainder = String(trimmed[remainderIndex...]).trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? trimmed : remainder
    }
}
