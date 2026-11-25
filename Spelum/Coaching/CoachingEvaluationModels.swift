import Foundation

nonisolated struct CoachingEvaluationDataset: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let datasetVersion: String
    let preparationCases: [PreparationEvaluationCase]
    let postTakeCases: [PostTakeEvaluationCase]

    static func loadBundled(from bundle: Bundle = .main) throws -> CoachingEvaluationDataset {
        let url = bundle.url(forResource: "CoachingEvaluationCases", withExtension: "json")
            ?? bundle.url(forResource: "CoachingEvaluationCases", withExtension: "json", subdirectory: "Coaching")
        guard let url else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CoachingEvaluationDataset.self, from: data)
    }
}

nonisolated struct PreparationEvaluationCase: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let category: CoachingCategory
    let title: String
    let sectionTitle: String
    let purpose: SectionPurpose
    let scriptText: String
    let exactPhrase: String?
    let cueWords: [String]
    let handoffCueText: String?
    let isSpeakerChangeHandoff: Bool
    let knownSpeakerNames: [String]
    let tags: [String]
    let includeInRepeatCheck: Bool
    let expectsAbstention: Bool
    let notes: String

    func makeRequest(
        promptVersion: String = SectionCoachService.preparationPromptVersion
    ) -> PreparationCoachingRequest {
        let hasHandoff = !(handoffCueText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let stableRevisionID = DeterministicUUID.fromString("prep-case-\(id)")
        let stableTalkID = DeterministicUUID.fromString("prep-talk-\(id)")
        return PreparationCoachingRequest(
            sectionRevisionID: stableRevisionID,
            talkRevisionID: stableTalkID,
            sectionTitle: sectionTitle,
            scriptText: scriptText,
            exactPhrase: exactPhrase,
            cueWords: cueWords,
            purpose: purpose,
            handoffCueText: handoffCueText,
            isSpeakerChangeHandoff: isSpeakerChangeHandoff,
            knownSpeakerNames: knownSpeakerNames,
            selectedTechniqueID: nil,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: purpose, hasHandoff: hasHandoff),
            promptVersion: promptVersion
        )
    }
}

nonisolated struct EvaluationMarkerFixture: Codable, Equatable, Hashable, Sendable {
    let timestamp: TimeInterval
    let label: String
}

nonisolated struct EvaluationObservationFixture: Codable, Equatable, Hashable, Sendable {
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

    func toTimingObservation() -> TimingObservation {
        TimingObservation(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            startTime: startTime,
            endTime: endTime,
            gapDuration: gapDuration,
            matchedPhrase: matchedPhrase,
            precedingContext: precedingContext,
            followingContext: followingContext,
            isEstimate: true
        )
    }
}

nonisolated struct EvaluationAmbiguousNoteFixture: Codable, Equatable, Hashable, Sendable {
    let reason: AmbiguousEvidenceReason
    let title: String
    let explanation: String
    let suggestedMarkerLabel: String

    func toAmbiguousNote() -> AmbiguousEvidenceNote {
        AmbiguousEvidenceNote(
            reason: reason,
            title: title,
            explanation: explanation,
            suggestedMarkerLabel: suggestedMarkerLabel,
            offersManualMarking: true
        )
    }
}

nonisolated struct PostTakeEvaluationCase: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let category: CoachingCategory
    let title: String
    let sectionTitle: String
    let purpose: SectionPurpose
    let scriptText: String
    let exactPhrase: String?
    let cueWords: [String]
    let handoffCueText: String?
    let isSpeakerChangeHandoff: Bool
    let knownSpeakerNames: [String]
    let attemptStatus: AttemptStatus
    let practiceMode: PracticeMode
    let playableDuration: TimeInterval
    let revealCount: Int
    let markers: [EvaluationMarkerFixture]
    let analysisOutcome: String
    let recognizedWordCount: Int
    let estimatedWordsPerMinute: Double?
    let observations: [EvaluationObservationFixture]
    let ambiguousNotes: [EvaluationAmbiguousNoteFixture]
    let tags: [String]
    let includeInRepeatCheck: Bool
    let expectsAbstention: Bool
    let notes: String

    func makeRequest(
        promptVersion: String = SectionCoachService.postTakePromptVersion
    ) -> PostTakeCoachingRequest {
        let hasHandoff = !(handoffCueText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let attemptID = DeterministicUUID.fromString("review-attempt-\(id)")
        let talkID = DeterministicUUID.fromString("review-talk-\(id)")
        let sectionRevID = DeterministicUUID.fromString("review-sec-\(id)")

        let timingResult = makeTimingResult(attemptID: attemptID, talkID: talkID, sectionRevID: sectionRevID)
        let mappedMarkers = markers.enumerated().map { idx, fixture in
            AttemptMarker(
                id: DeterministicUUID.fromString("review-marker-\(id)-\(idx)"),
                timestamp: fixture.timestamp,
                label: fixture.label
            )
        }

        return PostTakeCoachingRequest(
            attemptID: attemptID,
            talkRevisionID: talkID,
            sectionRevisionID: sectionRevID,
            sectionTitle: sectionTitle,
            scriptText: scriptText,
            exactPhrase: exactPhrase,
            cueWords: cueWords,
            purpose: purpose,
            handoffCueText: handoffCueText,
            isSpeakerChangeHandoff: isSpeakerChangeHandoff,
            knownSpeakerNames: knownSpeakerNames,
            attemptStatus: attemptStatus,
            practiceMode: practiceMode,
            playableDuration: playableDuration,
            revealCount: revealCount,
            markers: mappedMarkers,
            timingAnalysis: timingResult,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: purpose, hasHandoff: hasHandoff),
            promptVersion: promptVersion
        )
    }

    private func makeTimingResult(
        attemptID: UUID,
        talkID: UUID,
        sectionRevID: UUID
    ) -> TimingAnalysisResult? {
        switch analysisOutcome {
        case "completed":
            return TimingAnalysisResult(
                analysisID: DeterministicUUID.fromString("review-analysis-\(id)"),
                analysisVersion: 1,
                attemptID: attemptID,
                talkRevisionID: talkID,
                sectionRevisionID: sectionRevID,
                localeIdentifier: "en_US",
                outcome: .completed,
                elapsedAudioDuration: playableDuration,
                recognizedWordCount: recognizedWordCount,
                timingGranularity: recognizedWordCount > 0 ? .wordLevel : .none,
                estimatedWordsPerMinute: estimatedWordsPerMinute,
                observations: observations.map { $0.toTimingObservation() },
                ambiguousNotes: ambiguousNotes.map { $0.toAmbiguousNote() },
                finalizedSegmentCount: recognizedWordCount,
                hasOverlappingSegments: ambiguousNotes.contains { $0.reason == .overlappingRanges },
                hasUntimedFinalText: ambiguousNotes.contains { $0.reason == .incompleteTimingCoverage }
            )
        case "declined":
            return TimingAnalysisResult.declined(
                attemptID: attemptID,
                talkRevisionID: talkID,
                sectionRevisionID: sectionRevID,
                elapsedAudioDuration: playableDuration
            )
        default:
            return nil
        }
    }
}
