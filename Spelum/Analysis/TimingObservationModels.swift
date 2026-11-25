import Foundation

nonisolated struct TimedTranscriptSegment: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Double?
    let isFinal: Bool
    let localeIdentifier: String

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil,
        isFinal: Bool = true,
        localeIdentifier: String = "en_US"
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinal = isFinal
        self.localeIdentifier = localeIdentifier
    }

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }

    var isValidTimeRange: Bool {
        startTime.isFinite && endTime.isFinite && startTime >= 0 && endTime > startTime
    }
}

nonisolated enum TimingGranularity: String, Codable, Equatable, Hashable, Sendable {
    case wordLevel
    case phraseLevel
    case none
}

nonisolated enum TimingObservationKind: String, Codable, Equatable, Hashable, Sendable {
    case alignedExactPhrase
    case alignedCuePhrase
    case alignedScriptPhrase
    case phraseGap

    var badgeLabel: String {
        switch self {
        case .alignedExactPhrase: "Exact Phrase · Estimate"
        case .alignedCuePhrase: "Cue · Estimate"
        case .alignedScriptPhrase: "Phrase · Estimate"
        case .phraseGap: "Gap · Estimate"
        }
    }

    var symbolName: String {
        switch self {
        case .alignedExactPhrase: "quote.opening"
        case .alignedCuePhrase: "tag"
        case .alignedScriptPhrase: "text.quote"
        case .phraseGap: "pause.circle"
        }
    }
}

nonisolated struct TimingObservation: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let kind: TimingObservationKind
    let title: String
    let detail: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let gapDuration: TimeInterval?
    let matchedPhrase: String?
    let precedingContext: String?
    let followingContext: String?
    let isEstimate: Bool

    init(
        id: UUID = UUID(),
        kind: TimingObservationKind,
        title: String,
        detail: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        gapDuration: TimeInterval? = nil,
        matchedPhrase: String? = nil,
        precedingContext: String? = nil,
        followingContext: String? = nil,
        isEstimate: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.startTime = max(0, startTime.isFinite ? startTime : 0)
        self.endTime = max(self.startTime, endTime.isFinite ? endTime : self.startTime)
        self.gapDuration = gapDuration
        self.matchedPhrase = matchedPhrase
        self.precedingContext = precedingContext
        self.followingContext = followingContext
        self.isEstimate = isEstimate
    }

    func seekTarget(
        leadIn: TimeInterval = TimingObservationsEngine.defaultSeekLeadIn,
        maxDuration: TimeInterval
    ) -> TimeInterval {
        let safeLeadIn = max(0, leadIn.isFinite ? leadIn : 0)
        let safeMax = max(0, maxDuration.isFinite ? maxDuration : 0)
        let desired = max(0, startTime - safeLeadIn)
        return safeMax > 0 ? min(desired, safeMax) : desired
    }
}

nonisolated enum AmbiguousEvidenceReason: String, Codable, Equatable, Hashable, Sendable {
    case repeatedPhrase
    case paraphrasedOrMissingWords
    case overlappingRanges
    case incompleteTimingCoverage
    case emptyTranscript
    case stageDirectionSilence
    case multiSpeakerBoundary
}

nonisolated struct AmbiguousEvidenceNote: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let reason: AmbiguousEvidenceReason
    let title: String
    let explanation: String
    let suggestedMarkerLabel: String
    let offersManualMarking: Bool

    init(
        id: UUID = UUID(),
        reason: AmbiguousEvidenceReason,
        title: String,
        explanation: String,
        suggestedMarkerLabel: String,
        offersManualMarking: Bool = true
    ) {
        self.id = id
        self.reason = reason
        self.title = title
        self.explanation = explanation
        self.suggestedMarkerLabel = suggestedMarkerLabel
        self.offersManualMarking = offersManualMarking
    }
}

nonisolated enum TimingAnalysisOutcome: String, Codable, Equatable, Hashable, Sendable {
    case completed
    case declined
}

nonisolated struct TimingAnalysisResult: Codable, Equatable, Hashable, Sendable {
    let analysisID: UUID
    let analysisVersion: Int
    let attemptID: UUID
    let talkRevisionID: UUID
    let sectionRevisionID: UUID
    let analyzedAt: Date
    let localeIdentifier: String
    let outcome: TimingAnalysisOutcome
    let elapsedAudioDuration: TimeInterval
    let recognizedWordCount: Int
    let timingGranularity: TimingGranularity
    let estimatedWordsPerMinute: Double?
    let observations: [TimingObservation]
    let ambiguousNotes: [AmbiguousEvidenceNote]
    let finalizedSegmentCount: Int
    let hasOverlappingSegments: Bool
    let hasUntimedFinalText: Bool

    init(
        analysisID: UUID = UUID(),
        analysisVersion: Int = 1,
        attemptID: UUID,
        talkRevisionID: UUID,
        sectionRevisionID: UUID,
        analyzedAt: Date = Date(),
        localeIdentifier: String,
        outcome: TimingAnalysisOutcome = .completed,
        elapsedAudioDuration: TimeInterval,
        recognizedWordCount: Int,
        timingGranularity: TimingGranularity,
        estimatedWordsPerMinute: Double?,
        observations: [TimingObservation],
        ambiguousNotes: [AmbiguousEvidenceNote],
        finalizedSegmentCount: Int,
        hasOverlappingSegments: Bool,
        hasUntimedFinalText: Bool
    ) {
        self.analysisID = analysisID
        self.analysisVersion = max(1, analysisVersion)
        self.attemptID = attemptID
        self.talkRevisionID = talkRevisionID
        self.sectionRevisionID = sectionRevisionID
        self.analyzedAt = analyzedAt
        self.localeIdentifier = localeIdentifier
        self.outcome = outcome
        self.elapsedAudioDuration = max(0, elapsedAudioDuration.isFinite ? elapsedAudioDuration : 0)
        self.recognizedWordCount = max(0, recognizedWordCount)
        self.timingGranularity = timingGranularity
        self.estimatedWordsPerMinute = estimatedWordsPerMinute
        self.observations = observations
        self.ambiguousNotes = ambiguousNotes
        self.finalizedSegmentCount = max(0, finalizedSegmentCount)
        self.hasOverlappingSegments = hasOverlappingSegments
        self.hasUntimedFinalText = hasUntimedFinalText
    }

    static func declined(
        attemptID: UUID,
        talkRevisionID: UUID,
        sectionRevisionID: UUID,
        elapsedAudioDuration: TimeInterval,
        localeIdentifier: String = "en_US",
        previousVersion: Int = 0,
        at date: Date = Date()
    ) -> TimingAnalysisResult {
        TimingAnalysisResult(
            analysisVersion: max(1, previousVersion + 1),
            attemptID: attemptID,
            talkRevisionID: talkRevisionID,
            sectionRevisionID: sectionRevisionID,
            analyzedAt: date,
            localeIdentifier: localeIdentifier,
            outcome: .declined,
            elapsedAudioDuration: elapsedAudioDuration,
            recognizedWordCount: 0,
            timingGranularity: .none,
            estimatedWordsPerMinute: nil,
            observations: [],
            ambiguousNotes: [],
            finalizedSegmentCount: 0,
            hasOverlappingSegments: false,
            hasUntimedFinalText: false
        )
    }
}

nonisolated struct TimingAnalysisInput: Sendable {
    let attemptID: UUID
    let talkRevisionID: UUID
    let sectionRevisionID: UUID
    let elapsedAudioDuration: TimeInterval
    let scriptText: String
    let exactPhrase: String?
    let cueWords: [String]
    let hasMultipleSpeakersOrHandoff: Bool
    let segments: [TimedTranscriptSegment]
    let localeIdentifier: String
    let hasUntimedFinalText: Bool
    let analysisVersion: Int
    let analyzedAt: Date

    init(
        attemptID: UUID,
        talkRevisionID: UUID,
        sectionRevisionID: UUID,
        elapsedAudioDuration: TimeInterval,
        scriptText: String,
        exactPhrase: String? = nil,
        cueWords: [String] = [],
        hasMultipleSpeakersOrHandoff: Bool = false,
        segments: [TimedTranscriptSegment],
        localeIdentifier: String = "en_US",
        hasUntimedFinalText: Bool = false,
        analysisVersion: Int = 1,
        analyzedAt: Date = Date()
    ) {
        self.attemptID = attemptID
        self.talkRevisionID = talkRevisionID
        self.sectionRevisionID = sectionRevisionID
        self.elapsedAudioDuration = elapsedAudioDuration
        self.scriptText = scriptText
        self.exactPhrase = exactPhrase
        self.cueWords = cueWords
        self.hasMultipleSpeakersOrHandoff = hasMultipleSpeakersOrHandoff
        self.segments = segments
        self.localeIdentifier = localeIdentifier
        self.hasUntimedFinalText = hasUntimedFinalText
        self.analysisVersion = max(1, analysisVersion)
        self.analyzedAt = analyzedAt
    }
}
