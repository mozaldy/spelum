import Foundation

nonisolated struct PhraseAlignmentOutcome: Sendable {
    let observations: [TimingObservation]
    let notes: [AmbiguousEvidenceNote]
}

nonisolated extension TimingObservationsEngine {
    private struct TimedBoundaryInfo {
        let segmentID: UUID
        let startTime: TimeInterval
        let endTime: TimeInterval
        let isFirstInSegment: Bool
        let isLastInSegment: Bool
    }

    private enum WordUnitTiming {
        case timed(TimedBoundaryInfo)
        case untimedBarrier
    }

    private struct TranscriptWordUnit {
        let normalized: String
        let timing: WordUnitTiming
    }

    private struct AlignmentContext {
        let timeline: [TranscriptWordUnit]
        let overlappingIDs: Set<UUID>
        let hasIncompleteTiming: Bool
        let localeIdentifier: String
    }

    private struct CandidatePhrase {
        let displayPhrase: String
        let normalizedTokens: [String]
        let kind: TimingObservationKind
        let emitMissingNote: Bool
    }

    static func alignPhrases(
        input: TimingAnalysisInput,
        scriptStructure: ScriptStructure,
        stream: SanitizedTranscriptStream,
        overlappingIDs: Set<UUID>
    ) -> PhraseAlignmentOutcome {
        guard !stream.hasUnlocatedUntimedText else {
            return PhraseAlignmentOutcome(observations: [], notes: [])
        }
        let timeline = buildTimeline(from: stream.entries)
        guard !timeline.isEmpty else {
            return PhraseAlignmentOutcome(observations: [], notes: [])
        }

        let context = AlignmentContext(
            timeline: timeline,
            overlappingIDs: overlappingIDs,
            hasIncompleteTiming: stream.hasIncompleteTiming,
            localeIdentifier: input.localeIdentifier
        )

        var observations: [TimingObservation] = []
        var notes: [AmbiguousEvidenceNote] = []
        var evaluatedKeys: Set<[String]> = []

        if let exactCandidate = makeCandidate(
            rawPhrase: input.exactPhrase,
            kind: .alignedExactPhrase,
            emitMissingNote: true,
            localeIdentifier: input.localeIdentifier,
            evaluatedKeys: &evaluatedKeys
        ) {
            evaluateCandidate(exactCandidate, context: context, observations: &observations, notes: &notes)
        }

        for rawCue in input.cueWords {
            if let cueCandidate = makeCandidate(
                rawPhrase: rawCue,
                kind: .alignedCuePhrase,
                emitMissingNote: false,
                localeIdentifier: input.localeIdentifier,
                evaluatedKeys: &evaluatedKeys
            ) {
                evaluateCandidate(cueCandidate, context: context, observations: &observations, notes: &notes)
            }
        }

        if observations.isEmpty && notes.isEmpty {
            alignFallbackScriptPhrases(
                candidates: scriptStructure.spokenCandidatePhrases,
                context: context,
                evaluatedKeys: &evaluatedKeys,
                observations: &observations,
                notes: &notes
            )
        }

        return PhraseAlignmentOutcome(observations: observations, notes: notes)
    }

    private static func makeCandidate(
        rawPhrase: String?,
        kind: TimingObservationKind,
        emitMissingNote: Bool,
        localeIdentifier: String,
        evaluatedKeys: inout Set<[String]>
    ) -> CandidatePhrase? {
        guard let trimmed = rawPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        // Preserve explicitly marked exact phrases and cue words verbatim (including parentheticals & colons).
        let key = EnglishWordTokenizer.tokenize(trimmed, localeIdentifier: localeIdentifier).map(\.normalized)
        guard !key.isEmpty, evaluatedKeys.insert(key).inserted else {
            return nil
        }
        return CandidatePhrase(
            displayPhrase: trimmed,
            normalizedTokens: key,
            kind: kind,
            emitMissingNote: emitMissingNote
        )
    }

    private static func buildTimeline(from entries: [TranscriptStreamEntry]) -> [TranscriptWordUnit] {
        var units: [TranscriptWordUnit] = []
        for entry in entries {
            switch entry {
            case .timed(let segment):
                let lastIndex = segment.tokens.count - 1
                for (index, token) in segment.tokens.enumerated() {
                    units.append(
                        TranscriptWordUnit(
                            normalized: token.normalized,
                            timing: .timed(
                                TimedBoundaryInfo(
                                    segmentID: segment.id,
                                    startTime: segment.startTime,
                                    endTime: segment.endTime,
                                    isFirstInSegment: index == 0,
                                    isLastInSegment: index == lastIndex
                                )
                            )
                        )
                    )
                }
            case .untimedBarrier(let tokens):
                if tokens.isEmpty {
                    units.append(TranscriptWordUnit(normalized: "", timing: .untimedBarrier))
                } else {
                    for token in tokens {
                        units.append(
                            TranscriptWordUnit(
                                normalized: token.normalized,
                                timing: .untimedBarrier
                            )
                        )
                    }
                }
            }
        }
        return units
    }

    private static func evaluateCandidate(
        _ candidate: CandidatePhrase,
        context: AlignmentContext,
        observations: inout [TimingObservation],
        notes: inout [AmbiguousEvidenceNote]
    ) {
        let matchStarts = findContiguousMatches(of: candidate.normalizedTokens, in: context.timeline)
        if matchStarts.isEmpty {
            if candidate.emitMissingNote {
                notes.append(makeUnmatchedNote(for: candidate.displayPhrase))
            }
            return
        }
        if matchStarts.count > 1 {
            notes.append(makeRepeatedNote(for: candidate.displayPhrase, count: matchStarts.count))
            return
        }
        recordUniqueMatch(
            candidate: candidate,
            startIndex: matchStarts[0],
            context: context,
            observations: &observations,
            notes: &notes
        )
    }

    private static func recordUniqueMatch(
        candidate: CandidatePhrase,
        startIndex: Int,
        context: AlignmentContext,
        observations: inout [TimingObservation],
        notes: inout [AmbiguousEvidenceNote]
    ) {
        let endIndex = startIndex + candidate.normalizedTokens.count - 1
        let matchedSlice = context.timeline[startIndex ... endIndex]
        var timedInfos: [TimedBoundaryInfo] = []
        timedInfos.reserveCapacity(matchedSlice.count)

        for unit in matchedSlice {
            switch unit.timing {
            case .timed(let info):
                guard !context.overlappingIDs.contains(info.segmentID) else { return }
                timedInfos.append(info)
            case .untimedBarrier:
                // Never invent timestamps across an untimed or dropped finalized word.
                return
            }
        }

        guard let firstInfo = timedInfos.first,
              let lastInfo = timedInfos.last else {
            return
        }
        guard firstInfo.isFirstInSegment && lastInfo.isLastInSegment else {
            if candidate.emitMissingNote && !context.hasIncompleteTiming {
                notes.append(makeCoarseBoundaryNote(for: candidate.displayPhrase))
            }
            return
        }
        observations.append(
            TimingObservation(
                kind: candidate.kind,
                title: observationTitle(for: candidate.kind, displayPhrase: candidate.displayPhrase),
                detail: "“\(candidate.displayPhrase)” matched once in finalized on-device transcript.",
                startTime: firstInfo.startTime,
                endTime: lastInfo.endTime,
                matchedPhrase: candidate.displayPhrase
            )
        )
    }

    private static func alignFallbackScriptPhrases(
        candidates: [String],
        context: AlignmentContext,
        evaluatedKeys: inout Set<[String]>,
        observations: inout [TimingObservation],
        notes: inout [AmbiguousEvidenceNote]
    ) {
        let maxFallbackObservations = 5
        for phrase in candidates where observations.count < maxFallbackObservations {
            let tokens = EnglishWordTokenizer.tokenize(phrase, localeIdentifier: context.localeIdentifier)
            let key = tokens.map(\.normalized)
            guard key.count >= 2, evaluatedKeys.insert(key).inserted else { continue }
            let candidate = CandidatePhrase(
                displayPhrase: phrase,
                normalizedTokens: key,
                kind: .alignedScriptPhrase,
                emitMissingNote: false
            )
            evaluateCandidate(candidate, context: context, observations: &observations, notes: &notes)
        }

        if observations.isEmpty && notes.isEmpty && !candidates.isEmpty && !context.hasIncompleteTiming {
            notes.append(
                AmbiguousEvidenceNote(
                    reason: .paraphrasedOrMissingWords,
                    title: "Script wording diverged from transcript",
                    explanation: "No script phrases matched uniquely word-for-word in the finalized " +
                        "transcript. Use playback and manual markers to review paraphrased delivery.",
                    suggestedMarkerLabel: "Check delivery"
                )
            )
        }
    }

    private static func findContiguousMatches(
        of target: [String],
        in timeline: [TranscriptWordUnit]
    ) -> [Int] {
        guard !target.isEmpty, target.count <= timeline.count else { return [] }
        let lastPossibleStart = timeline.count - target.count
        var matches: [Int] = []
        for startIndex in 0 ... lastPossibleStart {
            var matched = true
            for offset in 0 ..< target.count where timeline[startIndex + offset].normalized != target[offset] {
                matched = false
                break
            }
            if matched {
                matches.append(startIndex)
            }
        }
        return matches
    }

    private static func observationTitle(for kind: TimingObservationKind, displayPhrase: String) -> String {
        switch kind {
        case .alignedExactPhrase: "Exact Phrase (Estimate)"
        case .alignedCuePhrase: "Cue “\(displayPhrase)” (Estimate)"
        case .alignedScriptPhrase: "Aligned Phrase (Estimate)"
        case .phraseGap: "Estimated Gap"
        }
    }

    private static func makeUnmatchedNote(for displayPhrase: String) -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .paraphrasedOrMissingWords,
            title: "Phrase not uniquely matched",
            explanation: "“\(displayPhrase)” was not matched word-for-word in the finalized transcript " +
                "(it may have been paraphrased, partially spoken, or misheard on-device). " +
                "Replay and place a manual marker instead.",
            suggestedMarkerLabel: "Check \(shortenedLabel(for: displayPhrase))"
        )
    }

    private static func makeRepeatedNote(for displayPhrase: String, count: Int) -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .repeatedPhrase,
            title: "Repeated wording not auto-linked",
            explanation: "“\(displayPhrase)” appeared \(count) times in the finalized transcript, so Spelum " +
                "avoided guessing which occurrence to link. Replay or drop a manual marker at the moment " +
                "you want to review.",
            suggestedMarkerLabel: "Check \(shortenedLabel(for: displayPhrase))"
        )
    }

    private static func makeCoarseBoundaryNote(for displayPhrase: String) -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .incompleteTimingCoverage,
            title: "Coarse timestamp boundaries",
            explanation: "“\(displayPhrase)” fell inside a multi-word timed segment without exact word " +
                "boundaries, so Spelum did not guess its timestamps.",
            suggestedMarkerLabel: "Check \(shortenedLabel(for: displayPhrase))"
        )
    }

    private static func shortenedLabel(for phrase: String) -> String {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 24 ? trimmed : String(trimmed.prefix(23)) + "…"
    }
}
