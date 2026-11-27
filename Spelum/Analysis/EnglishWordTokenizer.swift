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

    static func extractScriptStructure(
        from scriptText: String,
        knownSpeakerNames: [String] = []
    ) -> ScriptStructure {
        AnnotatedScriptParser.extractTimingStructure(
            from: scriptText,
            knownSpeakerNames: knownSpeakerNames
        )
    }

    static func stripStageDirections(from text: String) -> String {
        extractScriptStructure(from: text).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
