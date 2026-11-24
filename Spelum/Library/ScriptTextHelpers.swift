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
}
