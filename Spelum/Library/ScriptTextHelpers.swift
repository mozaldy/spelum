import Foundation

extension PresentationStore {
    static func finalNonEmptyLine(in text: String) -> String? {
        var lastLine: String?
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lastLine = trimmed
            }
        }
        return lastLine
    }

    static func defaultTitle(fromText text: String, fallback: String = "Untitled Presentation") -> String {
        let parsed = AnnotatedScriptParser.parseDocument(text)
        if parsed.hasStructuredHeadings {
            return parsed.defaultPresentationTitle
        }
        var firstNonEmpty: String?
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                firstNonEmpty = trimmed
                stop = true
            }
        }
        guard let firstNonEmpty else { return fallback }
        if firstNonEmpty.count <= 48 {
            return firstNonEmpty
        }
        let endIndex = firstNonEmpty.index(firstNonEmpty.startIndex, offsetBy: 45)
        return String(firstNonEmpty[..<endIndex]).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func displaySnippet(for text: String) -> String {
        if let firstSpoken = AnnotatedScriptParser.firstSpokenLine(in: text), !firstSpoken.isEmpty {
            return firstSpoken
        }
        var firstNonEmpty: String?
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                firstNonEmpty = trimmed
                stop = true
            }
        }
        return firstNonEmpty ?? ""
    }

    static func lineSplitOptions(in text: String) -> [LineSplitOption] {
        var lineStarts: [String.Index] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            lineStarts.append(cursor)
            let range = text.lineRange(for: cursor ..< cursor)
            cursor = range.upperBound
        }

        guard lineStarts.count > 1 else {
            return []
        }

        var options: [LineSplitOption] = []
        for idx in 1 ..< lineStarts.count {
            let splitIndex = lineStarts[idx]
            let before = text[..<splitIndex]
            let after = text[splitIndex...]
            guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let beforeLine = finalNonEmptyLine(in: String(before)) ?? ""
            let afterLine = displaySnippet(for: String(after))
            options.append(
                LineSplitOption(
                    id: idx,
                    lineNumber: idx + 1,
                    beforePreview: beforeLine,
                    afterPreview: afterLine,
                    splitIndex: splitIndex
                )
            )
        }
        return options
    }

    static func resolvedTitle(explicit: String?, fallbackText: String) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        return defaultTitle(fromText: fallbackText)
    }

    static func normalizedOptionalText(
        _ value: String?,
        preserveOuterSpaces: Bool = false
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return preserveOuterSpaces ? value : trimmed
    }

    static func normalizedSpeakerKey(_ section: SectionRevisionRecord) -> String {
        let normalizedName = section.speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(section.speakerRole.rawValue)::\(normalizedName)"
    }

    static func isValidSplitIndex(_ splitIndex: String.Index, in text: String) -> Bool {
        guard splitIndex > text.startIndex, splitIndex < text.endIndex else {
            return false
        }
        let before = text[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text[splitIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
        return !before.isEmpty && !after.isEmpty
    }

    static func exactPhraseSplitConflict(
        in text: String,
        exactPhrase: String?,
        at splitIndex: String.Index
    ) -> ExactPhraseSplitConflict? {
        guard isValidSplitIndex(splitIndex, in: text),
              let normalized = normalizedOptionalText(exactPhrase, preserveOuterSpaces: true) else {
            return nil
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedPhrase: String
        if text.contains(normalized) {
            matchedPhrase = normalized
        } else if text.contains(trimmed) {
            matchedPhrase = trimmed
        } else {
            return nil
        }

        let firstText = String(text[..<splitIndex])
        let secondText = String(text[splitIndex...])
        if firstText.contains(matchedPhrase) || secondText.contains(matchedPhrase) {
            return nil
        }

        guard let phraseRange = text.range(of: matchedPhrase) else {
            return nil
        }
        let beforeIndex = isValidSplitIndex(phraseRange.lowerBound, in: text) ? phraseRange.lowerBound : nil
        let afterIndex = isValidSplitIndex(phraseRange.upperBound, in: text) ? phraseRange.upperBound : nil
        return ExactPhraseSplitConflict(
            phrase: normalized,
            beforePhraseSplitIndex: beforeIndex,
            afterPhraseSplitIndex: afterIndex
        )
    }

    static func partitionExactPhrase(
        _ phrase: String?,
        in originalText: String,
        at splitIndex: String.Index,
        policy: ExactPhraseSplitPolicy
    ) throws -> (String?, String?) {
        guard let normalized = normalizedOptionalText(phrase, preserveOuterSpaces: true) else {
            return (nil, nil)
        }
        let firstText = String(originalText[..<splitIndex])
        let secondText = String(originalText[splitIndex...])
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        if firstText.contains(normalized) || firstText.contains(trimmed) {
            return (normalized, nil)
        }
        if secondText.contains(normalized) || secondText.contains(trimmed) {
            return (nil, normalized)
        }
        if exactPhraseSplitConflict(in: originalText, exactPhrase: normalized, at: splitIndex) != nil {
            switch policy {
            case .protect:
                throw SectionEditError.splitCrossesExactPhrase
            case .clearExactPhrase:
                return (nil, nil)
            }
        }
        // Phrase was not verbatim in original text; preserve it on the first section rather than dropping it.
        return (normalized, nil)
    }

    static func partitionCueWords(
        _ cueWords: [String],
        firstText: String,
        secondText: String
    ) -> ([String], [String]) {
        var firstCues: [String] = []
        var secondCues: [String] = []
        for rawCue in cueWords {
            let cue = rawCue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cue.isEmpty else { continue }
            let inFirst = firstText.localizedCaseInsensitiveContains(cue)
            let inSecond = secondText.localizedCaseInsensitiveContains(cue)
            if inSecond && !inFirst {
                secondCues.append(cue)
            } else {
                firstCues.append(cue)
            }
        }
        return (firstCues, secondCues)
    }
}
