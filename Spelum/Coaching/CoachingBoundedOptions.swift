import Foundation

nonisolated enum CoachingPassageRole: String, Codable, Equatable, Hashable, Sendable {
    case markedExactPhrase
    case handoffCue
    case spokenSentence
    case observationAnchor
}

nonisolated struct CoachingPassageOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let phrase: String
    let fromHandoff: Bool
    let role: CoachingPassageRole
}

nonisolated struct CoachingAbstentionOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let summaryForModel: String
    let renderedAction: String
    let renderedRationale: String
}

nonisolated struct CoachingPreparationActionOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let techniqueID: String
    let summaryForModel: String
    let renderedAction: String
    let allowsHandoffPassage: Bool
    let allowsScriptPassage: Bool
}

nonisolated struct PreparationCoachingOptionSet: Equatable, Sendable {
    let candidateTechniques: [CoachingTechnique]
    let passageOptions: [CoachingPassageOption]
    let actionOptions: [CoachingPreparationActionOption]
    let abstentionOptions: [CoachingAbstentionOption]
    let mustAbstain: Bool

    static func build(for request: PreparationCoachingRequest) -> PreparationCoachingOptionSet {
        let techniques: [CoachingTechnique]
        if let pinnedID = request.selectedTechniqueID {
            techniques = request.candidateTechniques.filter { $0.id == pinnedID }
        } else {
            techniques = request.candidateTechniques
        }

        let passages = CoachingPassageExtractor.extractPassages(
            scriptText: request.scriptText,
            exactPhrase: request.exactPhrase,
            handoffCueText: request.handoffCueText,
            observations: []
        )
        let actions = techniques.flatMap { Self.actionOptions(for: $0) }
        let abstentions = buildAbstentionOptions(for: request, passages: passages)
        let mustAbstain = passages.isEmpty || techniques.isEmpty || actions.isEmpty

        return PreparationCoachingOptionSet(
            candidateTechniques: techniques,
            passageOptions: passages,
            actionOptions: actions,
            abstentionOptions: abstentions,
            mustAbstain: mustAbstain
        )
    }

    static func isMinimalClosingLine(_ request: PreparationCoachingRequest) -> Bool {
        request.selectedTechniqueID == nil
            && request.purpose == .closing
            && !request.isSpeakerChangeHandoff
            && CoachingPassageExtractor.spokenWordCount(in: request.scriptText) <= 8
    }

    func renderRationale(
        technique: CoachingTechnique,
        passage: CoachingPassageOption,
        request: PreparationCoachingRequest
    ) -> String {
        if passage.fromHandoff || (technique.appliesToHandoff && request.isSpeakerChangeHandoff) {
            return "Fits the handoff into \(request.sectionTitle) while keeping your wording intact " +
                "(Macworld 2007, \(technique.sourceTimestamp))."
        }
        if passage.role == .markedExactPhrase {
            return "Anchors your marked exact phrase to this \(request.purpose.displayName.lowercased()) " +
                "technique from Macworld 2007 (\(technique.sourceTimestamp))."
        }
        return "Matches this \(request.purpose.displayName.lowercased()) passage " +
            "using the Macworld 2007 reference (\(technique.sourceTimestamp))."
    }

    private static func buildAbstentionOptions(
        for request: PreparationCoachingRequest,
        passages: [CoachingPassageOption]
    ) -> [CoachingAbstentionOption] {
        if passages.isEmpty {
            return [
                CoachingAbstentionOption(
                    id: "abstain.prep.no-spoken-passage",
                    summaryForModel: "No spoken script passage is available for a delivery cue.",
                    renderedAction:
                        "No delivery cue offered yet — add spoken lines to this section before rehearsing a technique.",
                    renderedRationale: "Only stage directions or empty text were present in this section."
                )
            ]
        }
        if isMinimalClosingLine(request) {
            return [
                CoachingAbstentionOption(
                    id: "abstain.prep.minimal-signoff",
                    summaryForModel: "Brief thank-you or sign-off line where keeping delivery simple fits best.",
                    renderedAction:
                        "Keep this brief sign-off plain and unhurried — no extra delivery technique needed.",
                    renderedRationale:
                        "A short closing sign-off works best cleanly on its own without adding extra mechanics."
                )
            ]
        }
        return []
    }

    private static func actionOptions(for technique: CoachingTechnique) -> [CoachingPreparationActionOption] {
        let base = CoachingPreparationActionOption(
            id: "\(technique.id).core",
            techniqueID: technique.id,
            summaryForModel: "Core \(technique.title) instruction",
            renderedAction: technique.deliveryInstruction,
            allowsHandoffPassage: technique.appliesToHandoff,
            allowsScriptPassage: true
        )
        return [base, TechniqueLibrary.secondaryPreparationAction(for: technique)]
    }
}

nonisolated enum CoachingPassageExtractor {
    private struct PassageCollector {
        var options: [CoachingPassageOption] = []
        var seen: Set<String> = []

        mutating func append(
            id: String,
            candidate: String?,
            source: String?,
            fromHandoff: Bool,
            role: CoachingPassageRole
        ) {
            guard let candidate, let source else { return }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !seen.contains(trimmed),
                  CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(trimmed, in: source) else {
                return
            }
            seen.insert(trimmed)
            options.append(CoachingPassageOption(id: id, phrase: trimmed, fromHandoff: fromHandoff, role: role))
        }
    }

    static func extractPassages(
        scriptText: String,
        exactPhrase: String?,
        handoffCueText: String?,
        observations: [TimingObservation]
    ) -> [CoachingPassageOption] {
        var collector = PassageCollector()
        collector.append(
            id: "passage.exact",
            candidate: exactPhrase,
            source: scriptText,
            fromHandoff: false,
            role: .markedExactPhrase
        )
        for (idx, sentence) in extractSpokenSentences(in: scriptText).prefix(6).enumerated() {
            collector.append(
                id: "passage.sentence.\(idx + 1)",
                candidate: sentence,
                source: scriptText,
                fromHandoff: false,
                role: .spokenSentence
            )
        }
        for (idx, obs) in observations.enumerated() {
            collector.append(
                id: "passage.obs.\(idx + 1)",
                candidate: obs.matchedPhrase,
                source: scriptText,
                fromHandoff: false,
                role: .observationAnchor
            )
            collector.append(
                id: "passage.obs.follow.\(idx + 1)",
                candidate: obs.followingContext,
                source: scriptText,
                fromHandoff: false,
                role: .observationAnchor
            )
        }
        collector.append(
            id: "passage.handoff",
            candidate: handoffCueText,
            source: handoffCueText,
            fromHandoff: true,
            role: .handoffCue
        )
        return collector.options
    }

    static func firstSpokenSentence(in text: String) -> String? {
        extractSpokenSentences(in: text).first
    }

    static func extractSpokenSentences(in text: String) -> [String] {
        let chunks = splitOutsideStageDirections(in: text)
        var sentences: [String] = []
        for chunk in chunks {
            var remaining = chunk[...]
            while !remaining.isEmpty {
                if let sepIndex = remaining.firstIndex(where: { ".!?\n".contains($0) }) {
                    let endIdx = remaining[sepIndex] == "\n" ? sepIndex : remaining.index(after: sepIndex)
                    let candidate = String(remaining[..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isVerifiedSpokenVerbatimMatch(candidate, in: text) {
                        sentences.append(candidate)
                    }
                    remaining = remaining[remaining.index(after: sepIndex)...]
                } else {
                    let candidate = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isVerifiedSpokenVerbatimMatch(candidate, in: text) {
                        sentences.append(candidate)
                    }
                    break
                }
            }
        }
        return sentences
    }

    static func spokenWordCount(in text: String) -> Int {
        splitOutsideStageDirections(in: text)
            .flatMap { normalizedWords(in: $0) }
            .count
    }

    static func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func isVerifiedSpokenVerbatimMatch(_ candidate: String, in source: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsStageDirectionBrackets(trimmed) else {
            return false
        }
        let words = normalizedWords(in: trimmed)
        guard !words.isEmpty,
              words.count >= 2 || (words[0].count >= 3) else {
            return false
        }
        return containsAtWordBoundaries(trimmed, in: source)
    }

    static func containsStageDirectionBrackets(_ text: String) -> Bool {
        text.contains("[") || text.contains("]")
    }

    static func containsAtWordBoundaries(_ needle: String, in haystack: String) -> Bool {
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let leadingOK: Bool
            if range.lowerBound == haystack.startIndex {
                leadingOK = true
            } else {
                let prevChar = haystack[haystack.index(before: range.lowerBound)]
                let firstNeedle = needle[needle.startIndex]
                leadingOK = !(isWordCharacter(prevChar) && isWordCharacter(firstNeedle))
            }

            let trailingOK: Bool
            if range.upperBound == haystack.endIndex {
                trailingOK = true
            } else {
                let nextChar = haystack[range.upperBound]
                let lastNeedle = needle[needle.index(before: needle.endIndex)]
                trailingOK = !(isWordCharacter(nextChar) && isWordCharacter(lastNeedle))
            }

            if leadingOK && trailingOK {
                return true
            }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func splitOutsideStageDirections(in text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var bracketDepth = 0

        for char in text {
            if char == "[" {
                if bracketDepth == 0 {
                    let cleaned = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { segments.append(cleaned) }
                    current = ""
                }
                bracketDepth += 1
            } else if char == "]" {
                if bracketDepth > 0 { bracketDepth -= 1 }
            } else if bracketDepth == 0 {
                current.append(char)
            }
        }
        let cleaned = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { segments.append(cleaned) }
        return segments
    }
}
