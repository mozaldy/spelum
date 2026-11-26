import Foundation

extension AmbiguousEvidenceReason {
    nonisolated var neutralDisplayLabel: String {
        switch self {
        case .repeatedPhrase:
            "Repeated phrase"
        case .paraphrasedOrMissingWords:
            "Paraphrased or missing words"
        case .overlappingRanges:
            "Overlapping timing ranges"
        case .incompleteTimingCoverage:
            "Incomplete timing coverage"
        case .emptyTranscript:
            "No spoken words recognized"
        case .stageDirectionSilence:
            "Scripted stage-direction silence"
        case .multiSpeakerBoundary:
            "Multi-speaker handoff boundary"
        }
    }

    nonisolated var isBlockingTimingAmbiguity: Bool {
        switch self {
        case .emptyTranscript, .overlappingRanges, .incompleteTimingCoverage,
             .repeatedPhrase, .paraphrasedOrMissingWords:
            true
        case .stageDirectionSilence, .multiSpeakerBoundary:
            false
        }
    }
}

nonisolated struct EvaluationMarkerEvidence: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let timestamp: TimeInterval
    let label: String

    init(id: String, timestamp: TimeInterval, label: String) {
        self.id = id
        self.timestamp = max(0, timestamp.isFinite ? timestamp : 0)
        self.label = label
    }

    var formattedLine: String {
        let clock = RehearsalTimeFormatter.clockString(for: timestamp)
        let seconds = String(format: "%.1fs", timestamp)
        return "\(clock) (\(seconds)) · \(label)"
    }
}

nonisolated struct EvaluationObservationEvidence: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let kind: TimingObservationKind
    let startTime: TimeInterval
    let endTime: TimeInterval
    let gapDuration: TimeInterval?
    let matchedPhrase: String?
    let precedingContext: String?
    let followingContext: String?

    init(
        id: UUID,
        kind: TimingObservationKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        gapDuration: TimeInterval? = nil,
        matchedPhrase: String? = nil,
        precedingContext: String? = nil,
        followingContext: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startTime = max(0, startTime.isFinite ? startTime : 0)
        self.endTime = max(self.startTime, endTime.isFinite ? endTime : self.startTime)
        self.gapDuration = gapDuration
        self.matchedPhrase = matchedPhrase
        self.precedingContext = precedingContext
        self.followingContext = followingContext
    }

    init(from fixture: EvaluationObservationFixture) {
        self.init(
            id: fixture.id,
            kind: fixture.kind,
            startTime: fixture.startTime,
            endTime: fixture.endTime,
            gapDuration: fixture.gapDuration,
            matchedPhrase: fixture.matchedPhrase,
            precedingContext: fixture.precedingContext,
            followingContext: fixture.followingContext
        )
    }

    var kindDisplayName: String {
        switch kind {
        case .alignedExactPhrase: "Aligned Exact Phrase"
        case .alignedCuePhrase: "Aligned Cue Phrase"
        case .alignedScriptPhrase: "Aligned Script Phrase"
        case .phraseGap: "Phrase Gap"
        }
    }

    var intervalDisplayText: String {
        let range = String(format: "%.1fs–%.1fs", startTime, endTime)
        if let gapDuration {
            let formattedGap = String(format: "%.1fs", gapDuration)
            return "\(range) · est. \(formattedGap) gap"
        }
        return range
    }

    var passageDisplayText: String? {
        if let matched = cleaned(matchedPhrase) {
            return "“\(matched)”"
        }
        let preceding = cleaned(precedingContext)
        let following = cleaned(followingContext)
        switch (preceding, following) {
        case let (before?, after?):
            return "Between “\(before)” and “\(after)”"
        case let (before?, nil):
            return "After “\(before)”"
        case let (nil, after?):
            return "Before “\(after)”"
        case (nil, nil):
            return nil
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

nonisolated struct EvaluationAmbiguityEvidence: Identifiable, Codable, Equatable, Hashable, Sendable {
    let reason: AmbiguousEvidenceReason
    let title: String
    let explanation: String

    var id: String { reason.rawValue }

    init(reason: AmbiguousEvidenceReason, title: String, explanation: String) {
        self.reason = reason
        self.title = title
        self.explanation = explanation
    }

    init(from fixture: EvaluationAmbiguousNoteFixture) {
        self.init(reason: fixture.reason, title: fixture.title, explanation: fixture.explanation)
    }
}

nonisolated struct EvaluationPostTakeEvidence: Codable, Equatable, Hashable, Sendable {
    let attemptStatus: AttemptStatus
    let practiceMode: PracticeMode
    let playableDuration: TimeInterval
    let revealCount: Int
    let analysisOutcome: String
    let recognizedWordCount: Int
    let estimatedWordsPerMinute: Double?
    let markers: [EvaluationMarkerEvidence]
    let observations: [EvaluationObservationEvidence]
    let ambiguityNotes: [EvaluationAmbiguityEvidence]

    init(
        attemptStatus: AttemptStatus,
        practiceMode: PracticeMode,
        playableDuration: TimeInterval,
        revealCount: Int,
        analysisOutcome: String,
        recognizedWordCount: Int,
        estimatedWordsPerMinute: Double?,
        markers: [EvaluationMarkerEvidence],
        observations: [EvaluationObservationEvidence],
        ambiguityNotes: [EvaluationAmbiguityEvidence]
    ) {
        self.attemptStatus = attemptStatus
        self.practiceMode = practiceMode
        self.playableDuration = max(0, playableDuration.isFinite ? playableDuration : 0)
        self.revealCount = max(0, revealCount)
        self.analysisOutcome = analysisOutcome
        self.recognizedWordCount = max(0, recognizedWordCount)
        self.estimatedWordsPerMinute = estimatedWordsPerMinute
        self.markers = markers
        self.observations = observations
        self.ambiguityNotes = ambiguityNotes
    }

    init(from evalCase: PostTakeEvaluationCase) {
        let mappedMarkers = evalCase.markers.enumerated().map { idx, marker in
            EvaluationMarkerEvidence(
                id: "marker-\(idx)",
                timestamp: marker.timestamp,
                label: marker.label
            )
        }
        self.init(
            attemptStatus: evalCase.attemptStatus,
            practiceMode: evalCase.practiceMode,
            playableDuration: evalCase.playableDuration,
            revealCount: evalCase.revealCount,
            analysisOutcome: evalCase.analysisOutcome,
            recognizedWordCount: evalCase.recognizedWordCount,
            estimatedWordsPerMinute: evalCase.estimatedWordsPerMinute,
            markers: mappedMarkers,
            observations: evalCase.observations.map(EvaluationObservationEvidence.init(from:)),
            ambiguityNotes: evalCase.ambiguousNotes.map(EvaluationAmbiguityEvidence.init(from:))
        )
    }

    var hasBlockingAmbiguity: Bool {
        ambiguityNotes.contains { $0.reason.isBlockingTimingAmbiguity }
    }

    var analysisOutcomeLabel: String {
        switch analysisOutcome {
        case "completed": "Completed"
        case "declined": "Declined by presenter"
        default: "Unavailable"
        }
    }
}
