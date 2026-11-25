import Foundation

nonisolated enum TranscriptStreamEntry: Sendable {
    case timed(TokenizedTimedSegment)
    case untimedBarrier(tokens: [EnglishWordToken])
}

nonisolated struct SanitizedTranscriptStream: Sendable {
    let entries: [TranscriptStreamEntry]
    let timedSegments: [TokenizedTimedSegment]
    let hasIncompleteTiming: Bool
    let hasUnlocatedUntimedText: Bool
    let hasTrailingBarrier: Bool
}

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
            return makeEmptyResult(
                input: input,
                elapsedDuration: 0,
                hasIncompleteTiming: input.hasUntimedFinalText || !input.untimedFragments.isEmpty
            )
        }

        let stream = buildOrderedTranscriptStream(
            input: input,
            elapsedAudioDuration: safeDuration
        )
        guard !stream.timedSegments.isEmpty else {
            return makeEmptyResult(
                input: input,
                elapsedDuration: safeDuration,
                hasIncompleteTiming: stream.hasIncompleteTiming
            )
        }

        return buildCompletedResult(
            input: input,
            stream: stream,
            elapsedDuration: safeDuration,
            minimumGapDuration: safeMinGap
        )
    }

    private static func buildCompletedResult(
        input: TimingAnalysisInput,
        stream: SanitizedTranscriptStream,
        elapsedDuration: TimeInterval,
        minimumGapDuration: TimeInterval
    ) -> TimingAnalysisResult {
        let segments = stream.timedSegments
        let overlappingIDs = detectOverlappingSegmentIDs(in: segments)
        let hasOverlap = !overlappingIDs.isEmpty
        let totalWords = segments.reduce(0) { $0 + $1.tokens.count }
        let granularity = resolveGranularity(for: segments)
        let scriptStructure = EnglishWordTokenizer.extractScriptStructure(
            from: input.scriptText,
            knownSpeakerNames: input.knownSpeakerNames
        )
        let gapContext = GapDetectionContext(
            overlappingIDs: overlappingIDs,
            elapsedAudioDuration: elapsedDuration,
            minimumGapDuration: minimumGapDuration,
            hasMultipleSpeakersOrHandoff: input.hasMultipleSpeakersOrHandoff,
            hasInteriorStageDirection: scriptStructure.hasInteriorStageDirection
        )

        let gapObservations = detectBoundedPhraseGaps(stream: stream, context: gapContext)
        let alignmentOutcome = alignPhrases(
            input: input,
            scriptStructure: scriptStructure,
            stream: stream,
            overlappingIDs: overlappingIDs
        )
        let contextualNotes = collectContextualNotes(
            ContextualNoteContext(
                input: input,
                scriptStructure: scriptStructure,
                stream: stream,
                granularity: granularity,
                gapContext: gapContext,
                alignmentNotes: alignmentOutcome.notes
            )
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
            timingGranularity: granularity,
            estimatedWordsPerMinute: computeEstimatedWPM(
                wordCount: totalWords,
                elapsedDuration: elapsedDuration,
                localeIdentifier: input.localeIdentifier,
                granularity: granularity,
                hasReliableTiming: !hasOverlap && !stream.hasIncompleteTiming
            ),
            observations: sortedObservations,
            ambiguousNotes: contextualNotes + alignmentOutcome.notes,
            finalizedSegmentCount: segments.count,
            hasOverlappingSegments: hasOverlap,
            hasUntimedFinalText: stream.hasIncompleteTiming
        )
    }

    private static func computeEstimatedWPM(
        wordCount: Int,
        elapsedDuration: TimeInterval,
        localeIdentifier: String,
        granularity: TimingGranularity,
        hasReliableTiming: Bool
    ) -> Double? {
        guard isEnglishLocaleIdentifier(localeIdentifier),
              granularity == .wordLevel,
              hasReliableTiming,
              wordCount > 0,
              elapsedDuration > 0 else {
            return nil
        }
        return Double(wordCount) * 60.0 / elapsedDuration
    }
}

private nonisolated extension TimingObservationsEngine {
    struct StreamBuildState {
        var entries: [TranscriptStreamEntry] = []
        var rawTimed: [TokenizedTimedSegment] = []
        var hasDroppedFinalSegment = false
        var hasAnyBarrier = false
    }

    static func buildOrderedTranscriptStream(
        input: TimingAnalysisInput,
        elapsedAudioDuration: TimeInterval
    ) -> SanitizedTranscriptStream {
        var fragmentsBySlot: [Int: [UntimedTranscriptFragment]] = [:]
        for fragment in input.untimedFragments {
            let slot = min(max(fragment.insertionIndex, 0), input.segments.count)
            fragmentsBySlot[slot, default: []].append(fragment)
        }

        var state = StreamBuildState()
        for slot in 0 ... input.segments.count {
            if let fragments = fragmentsBySlot[slot] {
                for fragment in fragments {
                    let localeID = fragment.localeIdentifier.isEmpty
                        ? input.localeIdentifier
                        : fragment.localeIdentifier
                    let tokens = EnglishWordTokenizer.tokenize(fragment.text, localeIdentifier: localeID)
                    state.hasAnyBarrier = true
                    state.entries.append(.untimedBarrier(tokens: tokens))
                }
            }
            guard slot < input.segments.count else { continue }
            let segment = input.segments[slot]
            guard segment.isFinal else { continue }

            let localeID = segment.localeIdentifier.isEmpty
                ? input.localeIdentifier
                : segment.localeIdentifier
            let tokens = EnglishWordTokenizer.tokenize(segment.text, localeIdentifier: localeID)
            guard !tokens.isEmpty else { continue }

            if let validSegment = validateTimedSegment(
                segment,
                tokens: tokens,
                elapsedAudioDuration: elapsedAudioDuration
            ) {
                state.entries.append(.timed(validSegment))
                state.rawTimed.append(validSegment)
            } else {
                state.hasDroppedFinalSegment = true
                state.hasAnyBarrier = true
                state.entries.append(.untimedBarrier(tokens: tokens))
            }
        }

        return finalizeStream(state: state, input: input)
    }

    static func validateTimedSegment(
        _ segment: TimedTranscriptSegment,
        tokens: [EnglishWordToken],
        elapsedAudioDuration: TimeInterval
    ) -> TokenizedTimedSegment? {
        guard segment.isValidTimeRange,
              segment.startTime < elapsedAudioDuration,
              segment.endTime <= elapsedAudioDuration + tailDurationTolerance else {
            return nil
        }
        let clampedEnd = min(segment.endTime, elapsedAudioDuration)
        guard clampedEnd > segment.startTime else { return nil }
        return TokenizedTimedSegment(
            id: segment.id,
            rawText: segment.text,
            startTime: segment.startTime,
            endTime: clampedEnd,
            tokens: tokens
        )
    }

    static func finalizeStream(
        state: StreamBuildState,
        input: TimingAnalysisInput
    ) -> SanitizedTranscriptStream {
        let isMonotonic = zip(state.rawTimed, state.rawTimed.dropFirst()).allSatisfy { lhs, rhs in
            lhs.startTime < rhs.startTime
                || (lhs.startTime == rhs.startTime && lhs.endTime <= rhs.endTime)
        }
        let sortedTimed = isMonotonic
            ? state.rawTimed
            : state.rawTimed.sorted { lhs, rhs in
                lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
            }
        let finalEntries: [TranscriptStreamEntry] = (!isMonotonic && !state.hasAnyBarrier)
            ? sortedTimed.map { .timed($0) }
            : state.entries
        let hasIncompleteTiming = input.hasUntimedFinalText
            || state.hasDroppedFinalSegment
            || !input.untimedFragments.isEmpty
        let hasUnlocatedUntimedText = (input.hasUntimedFinalText && !state.hasAnyBarrier)
            || (state.hasAnyBarrier && !isMonotonic)
        let hasTrailingBarrier = computeHasTrailingBarrier(in: finalEntries)

        return SanitizedTranscriptStream(
            entries: finalEntries,
            timedSegments: sortedTimed,
            hasIncompleteTiming: hasIncompleteTiming,
            hasUnlocatedUntimedText: hasUnlocatedUntimedText,
            hasTrailingBarrier: hasTrailingBarrier
        )
    }

    static func computeHasTrailingBarrier(in entries: [TranscriptStreamEntry]) -> Bool {
        var sawTimed = false
        var trailingBarrier = false
        for entry in entries {
            switch entry {
            case .timed:
                sawTimed = true
                trailingBarrier = false
            case .untimedBarrier:
                if sawTimed {
                    trailingBarrier = true
                }
            }
        }
        return trailingBarrier
    }

    static func detectOverlappingSegmentIDs(in segments: [TokenizedTimedSegment]) -> Set<UUID> {
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

    static func resolveGranularity(for segments: [TokenizedTimedSegment]) -> TimingGranularity {
        guard !segments.isEmpty else { return .none }
        return segments.allSatisfy { $0.tokens.count == 1 } ? .wordLevel : .phraseLevel
    }

    static func isEnglishLocaleIdentifier(_ identifier: String) -> Bool {
        let locale = Locale(identifier: identifier)
        if let code = locale.language.languageCode?.identifier.lowercased() {
            return code == "en"
        }
        let lower = identifier.lowercased()
        return lower == "en" || lower.hasPrefix("en_") || lower.hasPrefix("en-")
    }
}
