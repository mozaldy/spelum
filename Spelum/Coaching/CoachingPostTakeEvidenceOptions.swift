import Foundation

extension PostTakeCoachingOptionSet {
    static func buildEvidenceOptions(
        for request: PostTakeCoachingRequest,
        observations: [TimingObservation],
        passages: [CoachingPassageOption]
    ) -> [CoachingEvidenceOption] {
        let scriptPassageIDs = Set(passages.filter { !$0.fromHandoff }.map(\.id))
        let allTechIDs = Set(request.candidateTechniques.map(\.id))
        guard !scriptPassageIDs.isEmpty, !allTechIDs.isEmpty else { return [] }

        var options: [CoachingEvidenceOption] = []
        let primaryAligned = observations.first {
            $0.kind == .alignedExactPhrase || $0.kind == .alignedCuePhrase || $0.kind == .alignedScriptPhrase
        }

        for (idx, obs) in observations.enumerated() {
            if let option = makeObservationEvidence(
                index: idx + 1,
                obs: obs,
                passages: passages,
                allTechIDs: allTechIDs
            ) {
                options.append(option)
            }
        }

        appendPaceEvidence(
            for: request,
            primaryAligned: primaryAligned,
            passages: passages,
            scriptPassageIDs: scriptPassageIDs,
            allTechIDs: allTechIDs,
            to: &options
        )
        appendFactEvidence(
            for: request,
            primaryAligned: primaryAligned,
            scriptPassageIDs: scriptPassageIDs,
            allTechIDs: allTechIDs,
            to: &options
        )
        return options
    }
}

private extension PostTakeCoachingOptionSet {
    static func makeObservationEvidence(
        index: Int,
        obs: TimingObservation,
        passages: [CoachingPassageOption],
        allTechIDs: Set<String>
    ) -> CoachingEvidenceOption? {
        let matchedPassages = semanticallyMatchingPassageIDs(for: obs, in: passages)
        guard !matchedPassages.isEmpty else { return nil }

        let obsKey = "obs.\(index)"
        switch obs.kind {
        case .phraseGap:
            guard let gap = obs.gapDuration else { return nil }
            let formatted = String(format: "%.1f", gap)
            return CoachingEvidenceOption(
                id: obsKey,
                kind: .phraseGap(
                    observationID: obs.id,
                    gapSeconds: gap,
                    startTime: obs.startTime,
                    endTime: obs.endTime
                ),
                observationID: obs.id,
                summaryForModel:
                    "Estimated \(formatted)s phrase gap (\(String(format: "%.1f", obs.startTime))s-" +
                    "\(String(format: "%.1f", obs.endTime))s)",
                compatiblePassageIDs: matchedPassages,
                compatibleTechniqueIDs: allTechIDs
            )
        case .alignedExactPhrase, .alignedCuePhrase, .alignedScriptPhrase:
            let clock = RehearsalTimeFormatter.clockString(for: obs.startTime)
            return CoachingEvidenceOption(
                id: obsKey,
                kind: .alignedPhrase(
                    observationID: obs.id,
                    kind: obs.kind,
                    startTime: obs.startTime,
                    endTime: obs.endTime
                ),
                observationID: obs.id,
                summaryForModel: "Aligned passage at \(clock) (\(obs.kind.rawValue))",
                compatiblePassageIDs: matchedPassages,
                compatibleTechniqueIDs: allTechIDs
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func appendPaceEvidence(
        for request: PostTakeCoachingRequest,
        primaryAligned: TimingObservation?,
        passages: [CoachingPassageOption],
        scriptPassageIDs: Set<String>,
        allTechIDs: Set<String>,
        to options: inout [CoachingEvidenceOption]
    ) {
        guard let wpm = reliableEstimatedWPM(for: request) else { return }
        let rounded = Int(wpm.rounded())
        let alignedIDs = primaryAligned.map { semanticallyMatchingPassageIDs(for: $0, in: passages) } ?? []
        let compatiblePassages = alignedIDs.isEmpty ? scriptPassageIDs : alignedIDs

        if isFastPace(for: request) {
            options.append(
                CoachingEvidenceOption(
                    id: "fact.pace.fast",
                    kind: .fastPace(estimatedWPM: rounded, anchorObservationID: primaryAligned?.id),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Estimated fast speaking pace near \(rounded) WPM",
                    compatiblePassageIDs: compatiblePassages,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        } else if isSlowPace(for: request) {
            options.append(
                CoachingEvidenceOption(
                    id: "fact.pace.slow",
                    kind: .slowPace(estimatedWPM: rounded, anchorObservationID: primaryAligned?.id),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Estimated slow speaking pace near \(rounded) WPM",
                    compatiblePassageIDs: compatiblePassages,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        }
    }

    static func appendFactEvidence(
        for request: PostTakeCoachingRequest,
        primaryAligned: TimingObservation?,
        scriptPassageIDs: Set<String>,
        allTechIDs: Set<String>,
        to options: inout [CoachingEvidenceOption]
    ) {
        if request.revealCount > 0 {
            options.append(
                CoachingEvidenceOption(
                    id: "fact.reveals",
                    kind: .scriptReveals(count: request.revealCount, anchorObservationID: primaryAligned?.id),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Recorded \(request.revealCount) script reveal(s) during take",
                    compatiblePassageIDs: scriptPassageIDs,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        }
        for (idx, marker) in request.markers.prefix(3).enumerated() {
            let clock = RehearsalTimeFormatter.clockString(for: marker.timestamp)
            options.append(
                CoachingEvidenceOption(
                    id: "fact.marker.\(idx)",
                    kind: .manualMarker(
                        timestamp: marker.timestamp,
                        label: marker.label,
                        anchorObservationID: primaryAligned?.id
                    ),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Manual marker at \(clock) (\(marker.label))",
                    compatiblePassageIDs: scriptPassageIDs,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        }
    }

    static func semanticallyMatchingPassageIDs(
        for observation: TimingObservation,
        in passages: [CoachingPassageOption]
    ) -> Set<String> {
        let scriptPassages = passages.filter { !$0.fromHandoff }
        let contextSnippets: [String]
        switch observation.kind {
        case .phraseGap:
            contextSnippets = [observation.followingContext, observation.precedingContext]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .alignedExactPhrase, .alignedCuePhrase, .alignedScriptPhrase:
            contextSnippets = [observation.matchedPhrase]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard !contextSnippets.isEmpty else { return [] }

        var matched: Set<String> = []
        for passage in scriptPassages {
            let passageWords = CoachingPassageExtractor.normalizedWords(in: passage.phrase)
            guard !passageWords.isEmpty else { continue }
            for snippet in contextSnippets {
                let snippetWords = CoachingPassageExtractor.normalizedWords(in: snippet)
                guard !snippetWords.isEmpty else { continue }
                if containsContiguousSubsequence(snippetWords, in: passageWords)
                    || containsContiguousSubsequence(passageWords, in: snippetWords) {
                    matched.insert(passage.id)
                    break
                }
            }
        }
        return matched
    }

    static func containsContiguousSubsequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let limit = haystack.count - needle.count
        for start in 0...limit where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
