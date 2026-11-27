import Foundation

nonisolated enum AnnotatedScriptInlineParser {
    private static let risingPitchSymbols: Set<Character> = ["\u{2197}", "\u{2191}", "\u{2934}"]
    private static let fallingPitchSymbols: Set<Character> = ["\u{2198}", "\u{2193}", "\u{2935}"]
    private static let pausePrecedingPunctuation: Set<Character> = [
        "!", "?", "\u{2026}", ",", ";", ":", "\u{2014}", "\u{2013}",
        "\u{201D}", "\"", "\u{2019}", "'", ")"
    ]

    struct LineParseResult: Sendable {
        let blocks: [AnnotatedScriptBlock]
        let spokenLine: String?
        let stageDirections: [String]
    }

    static func parseLine(_ rawLine: String, startingBlockID: Int) -> LineParseResult {
        let line = stripLineEnding(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return LineParseResult(blocks: [], spokenLine: nil, stageDirections: [])
        }

        let directionRanges = findBracketedDirectionRanges(in: line)
        var blocks: [AnnotatedScriptBlock] = []
        var spokenParts: [String] = []
        var directions: [String] = []
        var nextID = startingBlockID
        var cursor = line.startIndex

        for range in directionRanges {
            let before = String(line[cursor ..< range.lowerBound])
            appendSpeechSegment(
                before,
                blocks: &blocks,
                spokenParts: &spokenParts,
                nextID: &nextID
            )

            let rawBracketed = String(line[range])
            let innerStart = line.index(after: range.lowerBound)
            let innerEnd = line.index(before: range.upperBound)
            let content = String(line[innerStart ..< innerEnd]).trimmingCharacters(in: .whitespaces)
            directions.append(rawBracketed)
            blocks.append(.direction(id: nextID, rawBracketed: rawBracketed, content: content))
            nextID += 1
            cursor = range.upperBound
        }

        if cursor < line.endIndex {
            appendSpeechSegment(
                String(line[cursor...]),
                blocks: &blocks,
                spokenParts: &spokenParts,
                nextID: &nextID
            )
        }

        let combinedSpoken = normalizeSpokenSpacing(spokenParts.joined(separator: " "))
        return LineParseResult(
            blocks: blocks,
            spokenLine: combinedSpoken.isEmpty ? nil : combinedSpoken,
            stageDirections: directions
        )
    }

    static func accessibleDescription(for tokens: [AnnotatedInlineToken]) -> String {
        var pieces: [String] = []
        for token in tokens {
            switch token {
            case .text(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pieces.append(trimmed)
                }
            case .pause(let kind):
                pieces.append("(\(kind.accessibleLabel))")
            case .pitch(let direction, _):
                pieces.append("(\(direction.accessibleLabel))")
            }
        }
        return pieces.joined(separator: " ")
    }

    static func findBracketedDirectionRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var openIndex: String.Index?
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]
            if char == "[" {
                openIndex = index
            } else if char == "]", let start = openIndex {
                let innerStart = line.index(after: start)
                let inner = line[innerStart ..< index]
                if !inner.trimmingCharacters(in: .whitespaces).isEmpty {
                    let upper = line.index(after: index)
                    ranges.append(start ..< upper)
                }
                openIndex = nil
            }
            index = line.index(after: index)
        }
        return ranges
    }

    static func parseInlineTokens(in segment: String) -> [AnnotatedInlineToken] {
        let protectedURLRanges = findURLRanges(in: segment)
        var tokens: [AnnotatedInlineToken] = []
        var literalBuffer = ""
        var cursor = segment.startIndex

        func flushLiteral() {
            guard !literalBuffer.isEmpty else { return }
            tokens.append(.text(literalBuffer))
            literalBuffer = ""
        }

        while cursor < segment.endIndex {
            if let urlRange = protectedURLRanges.first(where: { $0.lowerBound == cursor }) {
                literalBuffer.append(contentsOf: segment[urlRange])
                cursor = urlRange.upperBound
                continue
            }

            let char = segment[cursor]
            if let pitch = pitchDirection(for: char) {
                flushLiteral()
                tokens.append(.pitch(pitch, symbol: String(char)))
                cursor = segment.index(after: cursor)
                continue
            }

            if char == "/",
               let pauseMatch = matchPause(at: cursor, in: segment, protectedRanges: protectedURLRanges) {
                flushLiteral()
                tokens.append(.pause(pauseMatch.kind))
                cursor = pauseMatch.endIndex
                continue
            }

            literalBuffer.append(char)
            cursor = segment.index(after: cursor)
        }

        flushLiteral()
        return tokens
    }

    static func spokenString(from tokens: [AnnotatedInlineToken]) -> String {
        var result = ""
        for token in tokens {
            switch token {
            case .text(let value):
                result.append(value)
            case .pause, .pitch:
                if let last = result.last, !last.isWhitespace {
                    result.append(" ")
                }
            }
        }
        return normalizeSpokenSpacing(result)
    }

    static func accessibleSpeechDescription(from tokens: [AnnotatedInlineToken]) -> String {
        var parts: [String] = []
        for token in tokens {
            switch token {
            case .text(let value):
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
            case .pause(let kind):
                parts.append("(\(kind.accessibleLabel))")
            case .pitch(let direction, _):
                parts.append("(\(direction.accessibleLabel))")
            }
        }
        return parts.joined(separator: " ")
    }

    static func stripLineEnding(_ rawLine: String) -> String {
        var scalars = rawLine.unicodeScalars
        if scalars.last == "\n" {
            scalars.removeLast()
            if scalars.last == "\r" {
                scalars.removeLast()
            }
        } else if scalars.last == "\r" {
            scalars.removeLast()
        }
        return String(scalars)
    }
}

private nonisolated extension AnnotatedScriptInlineParser {
    struct PauseMatch {
        let kind: ScriptPauseKind
        let endIndex: String.Index
    }

    static func appendSpeechSegment(
        _ segment: String,
        blocks: inout [AnnotatedScriptBlock],
        spokenParts: inout [String],
        nextID: inout Int
    ) {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let tokens = parseInlineTokens(in: trimmed)
        let spoken = spokenString(from: tokens)
        if !spoken.isEmpty {
            spokenParts.append(spoken)
        }
        if !tokens.isEmpty {
            blocks.append(.speech(id: nextID, tokens: tokens, spokenLine: spoken))
            nextID += 1
        }
    }

    static func pitchDirection(for character: Character) -> ScriptPitchDirection? {
        if risingPitchSymbols.contains(character) { return .rising }
        if fallingPitchSymbols.contains(character) { return .falling }
        return nil
    }

    static func findURLRanges(in text: String) -> [Range<String.Index>] {
        let pattern = #"(?i)(?:(?:https?|ftp|file)://\S+|mailto:\S+|www\.\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard var range = Range(match.range, in: text) else { return nil }
            while range.lowerBound < range.upperBound {
                let lastIdx = text.index(before: range.upperBound)
                let lastChar = text[lastIdx]
                if ".,;:!?)\"'”’".contains(lastChar) {
                    range = range.lowerBound ..< lastIdx
                } else {
                    break
                }
            }
            return range.isEmpty ? nil : range
        }
    }

    static func matchPause(
        at start: String.Index,
        in text: String,
        protectedRanges: [Range<String.Index>]
    ) -> PauseMatch? {
        if protectedRanges.contains(where: { $0.contains(start) }) {
            return nil
        }

        var end = start
        var slashCount = 0
        while end < text.endIndex, text[end] == "/" {
            slashCount += 1
            end = text.index(after: end)
        }

        guard (1 ... 3).contains(slashCount) else {
            return nil
        }

        let prevIndex = start > text.startIndex ? text.index(before: start) : nil
        let prevChar = prevIndex.map { text[$0] }
        let nextChar = end < text.endIndex ? text[end] : nil

        let prevIsWhitespaceOrStart = prevChar == nil || prevChar?.isWhitespace == true
        let prevIsPitch = prevChar.flatMap(pitchDirection(for:)) != nil
        let nextIsWhitespaceOrEnd = nextChar == nil || nextChar?.isWhitespace == true
        let nextIsPitch = nextChar.flatMap(pitchDirection(for:)) != nil

        let isValidPause: Bool
        if prevIsWhitespaceOrStart || prevIsPitch {
            // Standalone `/`, `//`, `///` bounded on the right by whitespace, end, or pitch arrow.
            isValidPause = nextIsWhitespaceOrEnd || nextIsPitch
        } else if let prevChar, let prevIndex, isValidPrecedingPunctuation(prevChar, at: prevIndex, in: text) {
            // Slash touching terminal/clause punctuation (e.g. `Wait./`, `Wait.// Next`, `Wait?///`).
            isValidPause = true
        } else {
            // Alphanumeric before slash (e.g. `and/or`, `24/7`, `word/`). Keep literal!
            isValidPause = false
        }

        guard isValidPause else { return nil }

        let kind: ScriptPauseKind = switch slashCount {
        case 1: .short
        case 2: .medium
        default: .long
        }
        return PauseMatch(kind: kind, endIndex: end)
    }

    static func isValidPrecedingPunctuation(
        _ char: Character,
        at index: String.Index,
        in text: String
    ) -> Bool {
        if pausePrecedingPunctuation.contains(char) {
            return true
        }
        if char == "." {
            guard index > text.startIndex else { return false }
            let beforeDot = text[text.index(before: index)]
            // Reject `./path` and `../path`: require word character, dot, or closing quote before `.`
            return beforeDot.isLetter
                || beforeDot.isNumber
                || beforeDot == "."
                || beforeDot == "\u{201D}"
                || beforeDot == "\""
                || beforeDot == ")"
        }
        return false
    }

    static func normalizeSpokenSpacing(_ raw: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(raw.count)
        var previousWasSpace = false

        for char in raw {
            if char.isWhitespace {
                if !previousWasSpace && !collapsed.isEmpty {
                    collapsed.append(" ")
                    previousWasSpace = true
                }
            } else {
                if previousWasSpace,
                   ",.;:!?".contains(char),
                   collapsed.last == " " {
                    collapsed.removeLast()
                }
                collapsed.append(char)
                previousWasSpace = false
            }
        }

        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
