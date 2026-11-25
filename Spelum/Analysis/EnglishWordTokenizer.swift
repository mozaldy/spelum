import Foundation
import NaturalLanguage

nonisolated struct TokenizedTimedSegment: Sendable {
    let id: UUID
    let rawText: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let tokens: [EnglishWordToken]
}

nonisolated struct EnglishWordToken: Equatable, Hashable, Sendable {
    let raw: String
    let normalized: String
}

nonisolated struct ScriptStructure: Equatable, Sendable {
    let spokenText: String
    let stageDirections: [String]
    let hasInteriorStageDirection: Bool
    let hasTrailingStageDirection: Bool
    let spokenCandidatePhrases: [String]
}

nonisolated enum EnglishWordTokenizer {
    static func tokenize(
        _ text: String,
        localeIdentifier: String = "en_US"
    ) -> [EnglishWordToken] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.english)

        let locale = Locale(identifier: localeIdentifier)
        var tokens: [EnglishWordToken] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty,
                  raw.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
                return true
            }
            let normalized = normalizeToken(raw, locale: locale)
            if !normalized.isEmpty {
                tokens.append(EnglishWordToken(raw: raw, normalized: normalized))
            }
            return true
        }
        return tokens
    }

    static func normalizeToken(_ raw: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        let foldedApostrophes = raw
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
        let lowercased = foldedApostrophes.lowercased(with: locale)
        return lowercased.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    static func extractScriptStructure(from scriptText: String) -> ScriptStructure {
        let ranges = findStageDirectionRanges(in: scriptText)
        guard !ranges.isEmpty else {
            return ScriptStructure(
                spokenText: scriptText,
                stageDirections: [],
                hasInteriorStageDirection: false,
                hasTrailingStageDirection: false,
                spokenCandidatePhrases: extractSpokenCandidatePhrases(from: scriptText)
            )
        }

        var spoken = ""
        var stageDirections: [String] = []
        var cursor = scriptText.startIndex
        var hasInterior = false
        var hasTrailing = false

        for directionRange in ranges {
            spoken.append(String(scriptText[cursor ..< directionRange.lowerBound]))
            let directionText = String(scriptText[directionRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stageDirections.append(directionText)

            let beforeHasWord = !tokenize(String(scriptText[..<directionRange.lowerBound])).isEmpty
            let afterHasWord = !tokenize(String(scriptText[directionRange.upperBound...])).isEmpty
            if beforeHasWord && afterHasWord {
                hasInterior = true
            } else if beforeHasWord && !afterHasWord {
                hasTrailing = true
            }
            cursor = directionRange.upperBound
        }
        spoken.append(String(scriptText[cursor...]))

        return ScriptStructure(
            spokenText: spoken,
            stageDirections: stageDirections,
            hasInteriorStageDirection: hasInterior,
            hasTrailingStageDirection: hasTrailing,
            spokenCandidatePhrases: extractSpokenCandidatePhrases(from: spoken)
        )
    }

    static func stripStageDirections(from text: String) -> String {
        extractScriptStructure(from: text).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func findStageDirectionRanges(in text: String) -> [Range<String.Index>] {
        let pattern = #"\[[^\[\]\n]+\]|\([^\(\)\n]+\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            Range(match.range, in: text)
        }
    }

    private static func extractSpokenCandidatePhrases(from spokenText: String) -> [String] {
        let lines = spokenText.components(separatedBy: .newlines)
        var phrases: [String] = []

        for rawLine in lines {
            let trimmed = stripLeadingSpeakerPrefix(from: rawLine)
            guard !trimmed.isEmpty else { continue }
            let sentenceTokenizer = NLTokenizer(unit: .sentence)
            sentenceTokenizer.string = trimmed
            sentenceTokenizer.setLanguage(.english)
            sentenceTokenizer.enumerateTokens(in: trimmed.startIndex ..< trimmed.endIndex) { range, _ in
                let sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if tokenize(sentence).count >= 2 {
                    phrases.append(sentence)
                }
                return true
            }
        }
        return phrases
    }

    private static func stripLeadingSpeakerPrefix(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return trimmed }
        let prefix = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let prefixTokens = tokenize(prefix)
        guard !prefixTokens.isEmpty,
              prefixTokens.count <= 3,
              prefix.count <= 32 else {
            return trimmed
        }
        let remainderIndex = trimmed.index(after: colonIndex)
        return String(trimmed[remainderIndex...]).trimmingCharacters(in: .whitespaces)
    }
}
