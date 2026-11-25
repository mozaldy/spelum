import Foundation

nonisolated enum TimingObservationsEngine {
    static let defaultMinimumGapDuration: TimeInterval = 0.6
    static let defaultSeekLeadIn: TimeInterval = 0.5
    private static let boundaryOverlapEpsilon: TimeInterval = 0.000_001
    private static let tailDurationTolerance: TimeInterval = 0.25

    struct GapDetectionContext {
        let overlappingIDs: Set<UUID>
        let elapsedAudioDuration: TimeInterval
        let minimumGapDuration: TimeInterval
        let hasMultipleSpeakersOrHandoff: Bool
        let hasInteriorStageDirection: Bool
    }

    static func analyze(
        _ input: TimingAnalysisInput,
        minimumGapDuration: TimeInterval = defaultMinimumGapDuration
    ) -> TimingAnalysisResult {
        let safeDuration = (input.elapsedAudioDuration.isFinite && input.elapsedAudioDuration > 0)
            ? input.elapsedAudioDuration
            : 0
        let safeMinGap = max(0.05, minimumGapDuration.isFinite ? minimumGapDuration : defaultMinimumGapDuration)
        guard safeDuration > 0 else {
            return makeEmptyResult(input: input, elapsedDuration: 0)
        }

        let tokenizedSegments = sanitizeAndTokenizeSegments(
            input.segments,
            elapsedAudioDuration: safeDuration,
            fallbackLocale: input.localeIdentifier
        )
        guard !tokenizedSegments.isEmpty else {
            return makeEmptyResult(input: input, elapsedDuration: safeDuration)
        }

        return buildCompletedResult(
            input: input,
            segments: tokenizedSegments,
            elapsedDuration: safeDuration,
            minimumGapDuration: safeMinGap
        )
    }

    private static func buildCompletedResult(
        input: TimingAnalysisInput,
        segments: [TokenizedTimedSegment],
        elapsedDuration: TimeInterval,
        minimumGapDuration: TimeInterval
    ) -> TimingAnalysisResult {
        let overlappingIDs = detectOverlappingSegmentIDs(in: segments)
        let hasOverlap = !overlappingIDs.isEmpty
        let totalWords = segments.reduce(0) { $0 + $1.tokens.count }
        let scriptStructure = EnglishWordTokenizer.extractScriptStructure(from: input.scriptText)
        let gapContext = GapDetectionContext(
            overlappingIDs: overlappingIDs,
            elapsedAudioDuration: elapsedDuration,
            minimumGapDuration: minimumGapDuration,
            hasMultipleSpeakersOrHandoff: input.hasMultipleSpeakersOrHandoff,
            hasInteriorStageDirection: scriptStructure.hasInteriorStageDirection
        )

        let gapObservations = detectBoundedPhraseGaps(segments: segments, context: gapContext)
        let contextualNotes = collectContextualNotes(
            input: input,
            scriptStructure: scriptStructure,
            segments: segments,
            gapContext: gapContext
        )
        let alignmentOutcome = alignPhrases(
            input: input,
            scriptStructure: scriptStructure,
            segments: segments,
            overlappingIDs: overlappingIDs
        )
        let sortedObservations = (gapObservations + alignmentOutcome.observations).sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
        }

        return TimingAnalysisResult(
            analysisVersion: input.analysisVersion,
            attemptID: input.attemptID,
            talkRevisionID: input.talkRevisionID,
            sectionRevisionID: input.sectionRevisionID,
            analyzedAt: input.analyzedAt,
            localeIdentifier: input.localeIdentifier,
            outcome: .completed,
            elapsedAudioDuration: elapsedDuration,
            recognizedWordCount: totalWords,
            timingGranularity: resolveGranularity(for: segments),
            estimatedWordsPerMinute: computeEstimatedWPM(
                wordCount: totalWords,
                elapsedDuration: elapsedDuration,
                localeIdentifier: input.localeIdentifier,
                hasOverlap: hasOverlap,
                hasUntimedFinalText: input.hasUntimedFinalText
            ),
            observations: sortedObservations,
            ambiguousNotes: contextualNotes + alignmentOutcome.notes,
            finalizedSegmentCount: segments.count,
            hasOverlappingSegments: hasOverlap,
            hasUntimedFinalText: input.hasUntimedFinalText
        )
    }

    private static func computeEstimatedWPM(
        wordCount: Int,
        elapsedDuration: TimeInterval,
        localeIdentifier: String,
        hasOverlap: Bool,
        hasUntimedFinalText: Bool
    ) -> Double? {
        guard isEnglishLocaleIdentifier(localeIdentifier),
              !hasOverlap,
              !hasUntimedFinalText,
              wordCount > 0,
              elapsedDuration > 0 else {
            return nil
        }
        return Double(wordCount) * 60.0 / elapsedDuration
    }

    private static func sanitizeAndTokenizeSegments(
        _ segments: [TimedTranscriptSegment],
        elapsedAudioDuration: TimeInterval,
        fallbackLocale: String
    ) -> [TokenizedTimedSegment] {
        var result: [TokenizedTimedSegment] = []
        for segment in segments {
            guard segment.isFinal,
                  segment.isValidTimeRange,
                  segment.startTime < elapsedAudioDuration,
                  segment.endTime <= elapsedAudioDuration + tailDurationTolerance else {
                continue
            }
            let localeID = segment.localeIdentifier.isEmpty ? fallbackLocale : segment.localeIdentifier
            let tokens = EnglishWordTokenizer.tokenize(segment.text, localeIdentifier: localeID)
            guard !tokens.isEmpty else { continue }
            let clampedEnd = min(segment.endTime, elapsedAudioDuration)
            guard clampedEnd > segment.startTime else { continue }
            result.append(
                TokenizedTimedSegment(
                    id: segment.id,
                    rawText: segment.text,
                    startTime: segment.startTime,
                    endTime: clampedEnd,
                    tokens: tokens
                )
            )
        }
        return result.sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
        }
    }

    private static func detectOverlappingSegmentIDs(in segments: [TokenizedTimedSegment]) -> Set<UUID> {
        var overlapping: Set<UUID> = []
        var activeMaxEnd: TimeInterval = -1
        var activeMaxSegmentID: UUID?

        for segment in segments {
            if let priorID = activeMaxSegmentID,
               segment.startTime + boundaryOverlapEpsilon < activeMaxEnd {
                overlapping.insert(priorID)
                overlapping.insert(segment.id)
            }
            if segment.endTime >= activeMaxEnd {
                activeMaxEnd = segment.endTime
                activeMaxSegmentID = segment.id
            }
        }
        return overlapping
    }

    private static func resolveGranularity(for segments: [TokenizedTimedSegment]) -> TimingGranularity {
        guard !segments.isEmpty else { return .none }
        return segments.allSatisfy { $0.tokens.count == 1 } ? .wordLevel : .phraseLevel
    }

    private static func isEnglishLocaleIdentifier(_ identifier: String) -> Bool {
        let locale = Locale(identifier: identifier)
        if let code = locale.language.languageCode?.identifier.lowercased() {
            return code == "en"
        }
        let lower = identifier.lowercased()
        return lower == "en" || lower.hasPrefix("en_") || lower.hasPrefix("en-")
    }
}

nonisolated extension TimingObservationsEngine {
    static func collectContextualNotes(
        input: TimingAnalysisInput,
        scriptStructure: ScriptStructure,
        segments: [TokenizedTimedSegment],
        gapContext: GapDetectionContext
    ) -> [AmbiguousEvidenceNote] {
        var notes: [AmbiguousEvidenceNote] = []

        if !gapContext.overlappingIDs.isEmpty {
            notes.append(
                AmbiguousEvidenceNote(
                    reason: .overlappingRanges,
                    title: "Overlapping speech timestamps",
                    explanation: "On-device speech reported overlapping time ranges, so Spelum omitted " +
                        "affected pace and alignment estimates. Replay the audio or add a manual marker.",
                    suggestedMarkerLabel: "Check timing"
                )
            )
        }
        if input.hasUntimedFinalText {
            notes.append(
                AmbiguousEvidenceNote(
                    reason: .incompleteTimingCoverage,
                    title: "Incomplete word timestamps",
                    explanation: "Some recognized words did not include audio timestamps, so pace and " +
                        "affected alignments were omitted. Replay the take or place a manual marker.",
                    suggestedMarkerLabel: "Check moment"
                )
            )
        }
        if scriptStructure.hasTrailingStageDirection,
           let lastSegment = segments.last,
           (gapContext.elapsedAudioDuration - lastSegment.endTime) >= gapContext.minimumGapDuration {
            notes.append(
                AmbiguousEvidenceNote(
                    reason: .stageDirectionSilence,
                    title: "Stage direction followed by trailing silence",
                    explanation: "Your script ends with a stage direction and silence without a following " +
                        "spoken phrase, so Spelum did not report a phrase gap. Replay to check demo timing.",
                    suggestedMarkerLabel: "Check stage direction"
                )
            )
        }
        if input.hasMultipleSpeakersOrHandoff {
            notes.append(
                AmbiguousEvidenceNote(
                    reason: .multiSpeakerBoundary,
                    title: "Handoff and speaker boundaries",
                    explanation: "On-device transcript timing cannot attribute pauses to a specific speaker. " +
                        "Replay the transition or add a manual marker to judge the handoff.",
                    suggestedMarkerLabel: "Check handoff"
                )
            )
        }
        return notes
    }

    static func makeEmptyResult(
        input: TimingAnalysisInput,
        elapsedDuration: TimeInterval
    ) -> TimingAnalysisResult {
        var notes: [AmbiguousEvidenceNote] = [
            AmbiguousEvidenceNote(
                reason: .emptyTranscript,
                title: "No timed speech recognized",
                explanation: "No finalized English speech segments with timestamps were detected in this " +
                    "recording. Playback and manual markers remain available.",
                suggestedMarkerLabel: "Marked moment",
                offersManualMarking: elapsedDuration > 0
            )
        ]
        if input.hasUntimedFinalText {
            notes.append(
                AmbiguousEvidenceNote(
                    reason: .incompleteTimingCoverage,
                    title: "Incomplete word timestamps",
                    explanation: "Speech text was returned without audio time ranges, so timing estimates " +
                        "were omitted.",
                    suggestedMarkerLabel: "Check moment",
                    offersManualMarking: elapsedDuration > 0
                )
            )
        }
        return TimingAnalysisResult(
            analysisVersion: input.analysisVersion,
            attemptID: input.attemptID,
            talkRevisionID: input.talkRevisionID,
            sectionRevisionID: input.sectionRevisionID,
            analyzedAt: input.analyzedAt,
            localeIdentifier: input.localeIdentifier,
            outcome: .completed,
            elapsedAudioDuration: elapsedDuration,
            recognizedWordCount: 0,
            timingGranularity: .none,
            estimatedWordsPerMinute: nil,
            observations: [],
            ambiguousNotes: notes,
            finalizedSegmentCount: 0,
            hasOverlappingSegments: false,
            hasUntimedFinalText: input.hasUntimedFinalText
        )
    }

    static func detectBoundedPhraseGaps(
        segments: [TokenizedTimedSegment],
        context: GapDetectionContext
    ) -> [TimingObservation] {
        guard segments.count >= 2 else { return [] }
        var gaps: [TimingObservation] = []

        for index in 0 ..< (segments.count - 1) {
            let preceding = segments[index]
            let following = segments[index + 1]
            guard !context.overlappingIDs.contains(preceding.id),
                  !context.overlappingIDs.contains(following.id) else {
                continue
            }
            let gapDuration = following.startTime - preceding.endTime
            guard gapDuration.isFinite,
                  gapDuration >= context.minimumGapDuration,
                  preceding.endTime <= context.elapsedAudioDuration,
                  following.startTime <= context.elapsedAudioDuration else {
                continue
            }
            let precedingWord = preceding.tokens.last?.raw ?? preceding.rawText
            let followingWord = following.tokens.first?.raw ?? following.rawText
            let formattedGap = String(format: "%.1f", gapDuration)

            var detail = "Estimated pause between “\(precedingWord)” and “\(followingWord)”."
            if context.hasMultipleSpeakersOrHandoff {
                detail += " Transcript timing cannot assign this pause to a specific speaker."
            } else if context.hasInteriorStageDirection {
                detail += " Script includes a stage direction; replay to judge whether this pause fits."
            }

            gaps.append(
                TimingObservation(
                    kind: .phraseGap,
                    title: "Estimated \(formattedGap) s Gap",
                    detail: detail,
                    startTime: preceding.endTime,
                    endTime: following.startTime,
                    gapDuration: gapDuration,
                    precedingContext: precedingWord,
                    followingContext: followingWord
                )
            )
        }
        return gaps
    }
}
