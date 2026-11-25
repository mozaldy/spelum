import Foundation

nonisolated extension TimingObservationsEngine {
    struct ContextualNoteContext {
        let input: TimingAnalysisInput
        let scriptStructure: ScriptStructure
        let stream: SanitizedTranscriptStream
        let granularity: TimingGranularity
        let gapContext: GapDetectionContext
        let alignmentNotes: [AmbiguousEvidenceNote]
    }

    static func collectContextualNotes(
        _ context: ContextualNoteContext
    ) -> [AmbiguousEvidenceNote] {
        var notes: [AmbiguousEvidenceNote] = []

        if !context.gapContext.overlappingIDs.isEmpty {
            notes.append(makeOverlappingRangesNote())
        }
        if context.stream.hasIncompleteTiming {
            notes.append(makeIncompleteTimingNote())
        } else if context.granularity == .phraseLevel,
                  !context.alignmentNotes.contains(where: { $0.reason == .incompleteTimingCoverage }) {
            notes.append(makeCoarseGranularityNote())
        }
        if shouldEmitTrailingStageDirectionNote(context) {
            notes.append(makeTrailingStageDirectionNote())
        }
        if context.input.hasMultipleSpeakersOrHandoff {
            notes.append(makeMultiSpeakerBoundaryNote())
        }
        return notes
    }

    static func makeEmptyResult(
        input: TimingAnalysisInput,
        elapsedDuration: TimeInterval,
        hasIncompleteTiming: Bool
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
        if hasIncompleteTiming {
            notes.append(
                AmbiguousEvidenceNote(
                    reason: .incompleteTimingCoverage,
                    title: "Incomplete word timestamps",
                    explanation: "Finalized speech lacked valid audio time ranges, so timing estimates " +
                        "were omitted. Replay the take or place a manual marker.",
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
            hasUntimedFinalText: hasIncompleteTiming
        )
    }

    static func detectBoundedPhraseGaps(
        stream: SanitizedTranscriptStream,
        context: GapDetectionContext
    ) -> [TimingObservation] {
        guard !stream.hasUnlocatedUntimedText,
              stream.timedSegments.count >= 2 else {
            return []
        }

        var gaps: [TimingObservation] = []
        var lastTimed: TokenizedTimedSegment?
        var sawBarrierSinceLastTimed = false

        for entry in stream.entries {
            switch entry {
            case .untimedBarrier:
                sawBarrierSinceLastTimed = true
            case .timed(let current):
                if let preceding = lastTimed,
                   !sawBarrierSinceLastTimed,
                   let gap = makeGapObservation(between: preceding, and: current, context: context) {
                    gaps.append(gap)
                }
                lastTimed = current
                sawBarrierSinceLastTimed = false
            }
        }
        return gaps
    }

    private static func shouldEmitTrailingStageDirectionNote(_ context: ContextualNoteContext) -> Bool {
        guard context.scriptStructure.hasTrailingStageDirection,
              !context.stream.hasTrailingBarrier,
              !context.stream.hasUnlocatedUntimedText,
              let lastSegment = context.stream.timedSegments.last else {
            return false
        }
        return (context.gapContext.elapsedAudioDuration - lastSegment.endTime) >= context.gapContext.minimumGapDuration
    }

    private static func makeGapObservation(
        between preceding: TokenizedTimedSegment,
        and following: TokenizedTimedSegment,
        context: GapDetectionContext
    ) -> TimingObservation? {
        guard !context.overlappingIDs.contains(preceding.id),
              !context.overlappingIDs.contains(following.id) else {
            return nil
        }
        let gapDuration = following.startTime - preceding.endTime
        guard gapDuration.isFinite,
              gapDuration >= context.minimumGapDuration,
              preceding.endTime <= context.elapsedAudioDuration,
              following.startTime <= context.elapsedAudioDuration else {
            return nil
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

        return TimingObservation(
            kind: .phraseGap,
            title: "Estimated \(formattedGap) s Gap",
            detail: detail,
            startTime: preceding.endTime,
            endTime: following.startTime,
            gapDuration: gapDuration,
            precedingContext: precedingWord,
            followingContext: followingWord
        )
    }

    private static func makeOverlappingRangesNote() -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .overlappingRanges,
            title: "Overlapping speech timestamps",
            explanation: "On-device speech reported overlapping time ranges, so Spelum omitted " +
                "affected pace and alignment estimates. Replay the audio or add a manual marker.",
            suggestedMarkerLabel: "Check timing"
        )
    }

    private static func makeIncompleteTimingNote() -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .incompleteTimingCoverage,
            title: "Incomplete word timestamps",
            explanation: "Some finalized spoken words lacked valid in-bounds audio timestamps, so pace " +
                "and dependent timing estimates were omitted. Replay the take or place a manual marker.",
            suggestedMarkerLabel: "Check moment"
        )
    }

    private static func makeCoarseGranularityNote() -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .incompleteTimingCoverage,
            title: "Coarse phrase-level timestamps",
            explanation: "On-device speech reported multi-word time ranges rather than per-word timing, " +
                "so speaking pace was omitted. Replay the audio or place a manual marker.",
            suggestedMarkerLabel: "Check pace"
        )
    }

    private static func makeTrailingStageDirectionNote() -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .stageDirectionSilence,
            title: "Stage direction followed by trailing silence",
            explanation: "Your script ends with a stage direction and silence without a following " +
                "spoken phrase, so Spelum did not report a phrase gap. Replay to check demo timing.",
            suggestedMarkerLabel: "Check stage direction"
        )
    }

    private static func makeMultiSpeakerBoundaryNote() -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: .multiSpeakerBoundary,
            title: "Handoff and speaker boundaries",
            explanation: "On-device transcript timing cannot attribute pauses to a specific speaker. " +
                "Replay the transition or add a manual marker to judge the handoff.",
            suggestedMarkerLabel: "Check handoff"
        )
    }
}
