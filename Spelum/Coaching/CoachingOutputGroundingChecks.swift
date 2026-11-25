import Foundation

nonisolated struct CoachingAllowedNumbers: Sendable {
    let wpmValues: [Double]
    let secondValues: [Double]
    let revealCounts: Set<Int>
    let markerCounts: Set<Int>
    let wordCounts: Set<Int>
}

nonisolated struct VerifiedCoachingPhrase: Sendable {
    let phrase: String
    let fromHandoff: Bool
}

nonisolated enum CoachingObservationLookupError: Error {
    case invalidOrAbsent
}

extension CoachingOutputValidator {
    static func resolveTechnique(
        id: String,
        candidates: [CoachingTechnique],
        pinnedTechniqueID: String?
    ) -> CoachingTechnique? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let pinnedTechniqueID, trimmed != pinnedTechniqueID {
            return nil
        }
        return candidates.first { $0.id == trimmed }
    }

    static func verifyVerbatimPhrase(
        _ candidate: String,
        scriptText: String,
        handoffCueText: String?
    ) -> VerifiedCoachingPhrase? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        if scriptText.contains(trimmed) {
            return VerifiedCoachingPhrase(phrase: trimmed, fromHandoff: false)
        }
        if let handoffCueText, handoffCueText.contains(trimmed) {
            return VerifiedCoachingPhrase(phrase: trimmed, fromHandoff: true)
        }
        return nil
    }

    static func resolveObservationID(
        _ rawID: String?,
        request: PostTakeCoachingRequest
    ) throws -> UUID? {
        guard let rawID else { return nil }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "none" || trimmed.lowercased() == "null" {
            return nil
        }
        guard let uuid = UUID(uuidString: trimmed),
              let analysis = request.timingAnalysis,
              analysis.outcome == .completed,
              analysis.observations.contains(where: { $0.id == uuid }) else {
            throw CoachingObservationLookupError.invalidOrAbsent
        }
        return uuid
    }

    static func allowedPreparationNumbers() -> CoachingAllowedNumbers {
        CoachingAllowedNumbers(
            wpmValues: [],
            secondValues: [],
            revealCounts: [],
            markerCounts: [],
            wordCounts: []
        )
    }

    static func allowedPostTakeNumbers(for request: PostTakeCoachingRequest) -> CoachingAllowedNumbers {
        var wpmValues: [Double] = []
        var secondValues: [Double] = []
        var wordCounts: Set<Int> = []

        if request.playableDuration > 0 {
            secondValues.append(request.playableDuration)
        }
        for marker in request.markers {
            secondValues.append(marker.timestamp)
        }
        if let analysis = request.timingAnalysis, analysis.outcome == .completed {
            if let wpm = analysis.estimatedWordsPerMinute {
                wpmValues.append(wpm)
            }
            if analysis.elapsedAudioDuration > 0 {
                secondValues.append(analysis.elapsedAudioDuration)
            }
            wordCounts.insert(analysis.recognizedWordCount)
            for obs in analysis.observations {
                secondValues.append(obs.startTime)
                secondValues.append(obs.endTime)
                if let gap = obs.gapDuration {
                    secondValues.append(gap)
                }
            }
        }

        return CoachingAllowedNumbers(
            wpmValues: wpmValues,
            secondValues: secondValues,
            revealCounts: [request.revealCount],
            markerCounts: [request.markers.count],
            wordCounts: wordCounts
        )
    }

    static func containsDisallowedClaim(in text: String) -> Bool {
        let lower = text.lowercased()
        let bannedPhrases = [
            "accent", "pronunciation", "enunciation", "articulation",
            "voice cloning", "sound more like steve", "sound like steve",
            "imitate steve", "shadowing", "overall score", "performance score",
            "grade:", "letter grade", "emotion score", "sounded nervous",
            "sounded anxious", "sounded robotic", "monotone voice", "vocal tone"
        ]
        if bannedPhrases.contains(where: { lower.contains($0) }) {
            return true
        }
        let scorePatterns = [
            #"\b\d+(?:\.\d+)?\s*/\s*(?:10|100)\b"#,
            #"\bscore\s*(?:of|is|:)?\s*\d+"#,
            #"\b\d{1,3}\s*%\b"#
        ]
        return scorePatterns.contains { matchesRegex($0, in: lower) }
    }

    static func containsUnsupportedSpeakerJudgment(
        in text: String,
        knownSpeakerNames: [String],
        isMultiSpeaker: Bool
    ) -> Bool {
        let lower = text.lowercased()
        let blameVerbs = [
            "paused", "pause", "rushed", "spoke", "talked", "delayed",
            "hesitated", "interrupted", "waited", "finished", "stumbled", "took too long"
        ]
        guard blameVerbs.contains(where: { lower.contains($0) }) else {
            return false
        }

        if isMultiSpeaker {
            let genericRoles = ["teammate", "co-presenter", "other speaker", "previous speaker"]
            if genericRoles.contains(where: { lower.contains($0) }) {
                return true
            }
        }

        let filteredNames = knownSpeakerNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 && $0 != "presenter" && $0 != "teammate" && $0 != "host" }

        return filteredNames.contains { name in
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"(?:'s|’s)?\b"#
            return matchesRegex(pattern, in: lower)
        }
    }

    static func containsInventedMeasurement(in text: String, allowedNumbers: CoachingAllowedNumbers) -> Bool {
        let lower = text.lowercased()
        return hasInventedWPM(in: lower, allowed: allowedNumbers.wpmValues)
            || hasInventedSeconds(in: lower, allowed: allowedNumbers.secondValues)
            || hasInventedClockTimestamp(in: lower, allowed: allowedNumbers.secondValues)
            || hasInventedCounts(in: lower, allowed: allowedNumbers)
    }

    private static func hasInventedWPM(in lower: String, allowed: [Double]) -> Bool {
        let wpmMatches = extractMatchedNumbers(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:wpm|words\s+per\s+minute)\b"#,
            in: lower
        )
        return wpmMatches.contains { value in
            !allowed.contains { abs($0 - value) <= 2.0 }
        }
    }

    private static func hasInventedSeconds(in lower: String, allowed: [Double]) -> Bool {
        let secMatches = extractMatchedNumbers(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:s|sec|secs|second|seconds)\b"#,
            in: lower
        )
        if secMatches.contains(where: { value in !allowed.contains { abs($0 - value) <= 0.15 } }) {
            return true
        }
        let msMatches = extractMatchedNumbers(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:ms|millisecond|milliseconds)\b"#,
            in: lower
        )
        return msMatches.contains { msValue in
            let seconds = msValue / 1000.0
            return !allowed.contains { abs($0 - seconds) <= 0.15 }
        }
    }

    private static func hasInventedClockTimestamp(in lower: String, allowed: [Double]) -> Bool {
        guard let clockRegex = try? NSRegularExpression(pattern: #"\b(\d+):(\d{2})(?:\.(\d))?\b"#) else {
            return false
        }
        let nsRange = NSRange(lower.startIndex..., in: lower)
        for match in clockRegex.matches(in: lower, range: nsRange) {
            guard let minRange = Range(match.range(at: 1), in: lower),
                  let secRange = Range(match.range(at: 2), in: lower),
                  let mins = Double(lower[minRange]),
                  let secs = Double(lower[secRange]) else {
                continue
            }
            let tenths: Double = if match.range(at: 3).location != NSNotFound,
                                    let tenthRange = Range(match.range(at: 3), in: lower) {
                (Double(lower[tenthRange]) ?? 0) / 10.0
            } else {
                0
            }
            let totalSeconds = mins * 60.0 + secs + tenths
            if !allowed.contains(where: { abs($0 - totalSeconds) <= 0.25 }) {
                return true
            }
        }
        return false
    }

    private static func hasInventedCounts(in lower: String, allowed: CoachingAllowedNumbers) -> Bool {
        let reveals = extractMatchedNumbers(pattern: #"(\d+)\s+(?:script\s+)?reveals?\b"#, in: lower)
        if reveals.contains(where: { !allowed.revealCounts.contains(Int($0.rounded())) }) {
            return true
        }
        let markers = extractMatchedNumbers(pattern: #"(\d+)\s+(?:manual\s+)?markers?\b"#, in: lower)
        return markers.contains { !allowed.markerCounts.contains(Int($0.rounded())) }
    }

    private static func extractMatchedNumbers(pattern: String, in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return Double(text[range])
        }
    }

    private static func matchesRegex(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: nsRange) != nil
    }
}
