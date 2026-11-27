import Foundation

nonisolated enum ScriptPauseKind: String, Codable, Equatable, Hashable, Sendable {
    case short
    case medium
    case long

    var displayMark: String {
        switch self {
        case .short: "/"
        case .medium: "//"
        case .long: "///"
        }
    }

    var accessibleLabel: String {
        switch self {
        case .short: "short pause"
        case .medium: "medium pause"
        case .long: "long pause"
        }
    }
}

nonisolated enum ScriptPitchDirection: String, Codable, Equatable, Hashable, Sendable {
    case rising
    case falling

    var accessibleLabel: String {
        switch self {
        case .rising: "rising pitch"
        case .falling: "falling pitch"
        }
    }
}

nonisolated enum AnnotatedInlineToken: Equatable, Hashable, Sendable {
    case text(String)
    case pause(ScriptPauseKind)
    case pitch(ScriptPitchDirection, symbol: String)
}

nonisolated enum AnnotatedScriptBlock: Identifiable, Equatable, Hashable, Sendable {
    case speech(id: Int, tokens: [AnnotatedInlineToken], spokenLine: String)
    case direction(id: Int, rawBracketed: String, content: String)

    var id: Int {
        switch self {
        case .speech(let id, _, _): id
        case .direction(let id, _, _): id
        }
    }

    var isSpeech: Bool {
        if case .speech = self { return true }
        return false
    }

    var directionContent: String? {
        if case .direction(_, _, let content) = self { return content }
        return nil
    }
}

nonisolated struct ParsedScriptSlide: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let sectionIndex: Int
    let indexInSection: Int
    let explicitSlideIndex: Int?
    let isExplicitSlide: Bool
    let rawHeadingLine: String?
    let rawHeadingTitle: String
    let displayTitle: String
    let rawBodyText: String
    let rawSliceText: String
    let blocks: [AnnotatedScriptBlock]
    let spokenLines: [String]
    let stageDirections: [String]

    var spokenText: String {
        spokenLines.joined(separator: "\n")
    }

    var firstSpokenLine: String? {
        spokenLines.first
    }

    var lastSpokenLine: String? {
        spokenLines.last
    }

    var hasSpokenContent: Bool {
        !spokenLines.isEmpty
    }

    var hasOnlyDirectionsOrNoSpeech: Bool {
        spokenLines.isEmpty
    }
}

nonisolated struct ParsedScriptSection: Identifiable, Equatable, Hashable, Sendable {
    var id: Int { index }

    let index: Int
    let isExplicitSection: Bool
    let rawHeadingLine: String?
    let rawHeadingTitle: String
    let title: String
    let rawText: String
    let slides: [ParsedScriptSlide]

    var explicitSlides: [ParsedScriptSlide] {
        slides.filter(\.isExplicitSlide)
    }

    var spokenLines: [String] {
        slides.flatMap(\.spokenLines)
    }

    var spokenText: String {
        spokenLines.joined(separator: "\n")
    }

    var firstSpokenLine: String? {
        spokenLines.first
    }

    var lastSpokenLine: String? {
        spokenLines.last
    }

    var stageDirections: [String] {
        slides.flatMap(\.stageDirections)
    }
}

nonisolated struct ParsedAnnotatedScript: Equatable, Hashable, Sendable {
    let sourceText: String
    let sections: [ParsedScriptSection]
    let explicitSlides: [ParsedScriptSlide]
    let hasStructuredHeadings: Bool

    var spokenLines: [String] {
        sections.flatMap(\.spokenLines)
    }

    var spokenText: String {
        spokenLines.joined(separator: "\n")
    }

    var firstSpokenLine: String? {
        spokenLines.first
    }

    var lastSpokenLine: String? {
        spokenLines.last
    }

    var defaultPresentationTitle: String {
        if let explicitSection = sections.first(where: { $0.isExplicitSection && !$0.rawHeadingTitle.isEmpty }) {
            return Self.truncatedTitle(explicitSection.rawHeadingTitle)
        }
        if let firstExplicitSlide = explicitSlides.first(where: { !$0.rawHeadingTitle.isEmpty }) {
            return Self.truncatedTitle(firstExplicitSlide.rawHeadingTitle)
        }
        if let firstSpoken = firstSpokenLine {
            return Self.truncatedTitle(firstSpoken)
        }
        var firstNonEmpty: String?
        sourceText.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                firstNonEmpty = trimmed
                stop = true
            }
        }
        return firstNonEmpty.map(Self.truncatedTitle) ?? "Untitled Presentation"
    }

    private static func truncatedTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled Presentation" }
        guard trimmed.count > 48 else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 45)
        return String(trimmed[..<endIndex]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
