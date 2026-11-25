import Foundation
import Testing
@testable import Spelum

private final class CoachingTestBundleAnchor {}

enum CoachingTestFixtures {
    static func makeSamplePreparationRequest() -> PreparationCoachingRequest {
        let script =
            "Thank you, Sam. That problem is exactly why we rebuilt our recorder. " +
            "Today we are introducing Lumera."
        return PreparationCoachingRequest(
            sectionRevisionID: UUID(),
            talkRevisionID: UUID(),
            sectionTitle: "Taking the Stage",
            scriptText: script,
            exactPhrase: "Today we are introducing Lumera.",
            cueWords: ["Thank Sam", "rebuilt", "Lumera"],
            purpose: .reveal,
            handoffCueText: "And now Maya will show you what we built to solve that.",
            isSpeakerChangeHandoff: true,
            knownSpeakerNames: ["Sam", "Maya"],
            selectedTechniqueID: nil,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .reveal, hasHandoff: true),
            promptVersion: SectionCoachService.preparationPromptVersion
        )
    }

    static func makeSamplePostTakeRequest(withObservation: Bool) -> PostTakeCoachingRequest {
        let attemptID = UUID()
        let talkRevID = UUID()
        let sectionRevID = UUID()
        let script =
            "Thank you, Sam. That problem is exactly why we rebuilt our recorder. " +
            "Today we are introducing Lumera."
        let obs = TimingObservation(
            id: UUID(),
            kind: .phraseGap,
            title: "0.9s phrase gap",
            detail: "Estimated 0.9s pause between neighboring final phrases.",
            startTime: 5.2,
            endTime: 6.1,
            gapDuration: 0.9,
            precedingContext: "rebuilt our recorder",
            followingContext: "Today we are introducing Lumera"
        )
        let analysis: TimingAnalysisResult? = withObservation ? TimingAnalysisResult(
            attemptID: attemptID,
            talkRevisionID: talkRevID,
            sectionRevisionID: sectionRevID,
            localeIdentifier: "en_US",
            outcome: .completed,
            elapsedAudioDuration: 10.0,
            recognizedWordCount: 18,
            timingGranularity: .wordLevel,
            estimatedWordsPerMinute: 108.0,
            observations: [obs],
            ambiguousNotes: [],
            finalizedSegmentCount: 18,
            hasOverlappingSegments: false,
            hasUntimedFinalText: false
        ) : nil

        return PostTakeCoachingRequest(
            attemptID: attemptID,
            talkRevisionID: talkRevID,
            sectionRevisionID: sectionRevID,
            sectionTitle: "Taking the Stage",
            scriptText: script,
            exactPhrase: "Today we are introducing Lumera.",
            cueWords: ["Thank Sam", "rebuilt", "Lumera"],
            purpose: .reveal,
            handoffCueText: "And now Maya will show you what we built to solve that.",
            isSpeakerChangeHandoff: true,
            knownSpeakerNames: ["Sam", "Maya"],
            attemptStatus: .ready,
            practiceMode: .cueWords,
            playableDuration: 10.0,
            revealCount: 0,
            markers: [],
            timingAnalysis: analysis,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .reveal, hasHandoff: true),
            promptVersion: SectionCoachService.postTakePromptVersion
        )
    }

    static func loadTestFixtureCoachingCases() throws -> CoachingEvaluationDataset {
        let bundle = Bundle(for: CoachingTestBundleAnchor.self)
        let url = bundle.url(forResource: "CoachingCases", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "CoachingCases", withExtension: "json")
        let resolvedURL = try #require(url)
        let data = try Data(contentsOf: resolvedURL)
        return try JSONDecoder().decode(CoachingEvaluationDataset.self, from: data)
    }
}

actor CoachingAsyncGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

final class StubCoachingModelProvider: CoachingModelProviding, @unchecked Sendable {
    let availabilityState: CoachingModelAvailability
    let preparationHandler: (@Sendable (PreparationCoachingRequest) async throws -> RawModelCoachingSuggestion)?
    let postTakeHandler: (@Sendable (PostTakeCoachingRequest) async throws -> RawModelCoachingSuggestion)?
    private(set) var preparationCallCount = 0
    private(set) var postTakeCallCount = 0

    init(
        availabilityState: CoachingModelAvailability,
        preparationHandler: (@Sendable (PreparationCoachingRequest) async throws -> RawModelCoachingSuggestion)? = nil,
        postTakeHandler: (@Sendable (PostTakeCoachingRequest) async throws -> RawModelCoachingSuggestion)? = nil
    ) {
        self.availabilityState = availabilityState
        self.preparationHandler = preparationHandler
        self.postTakeHandler = postTakeHandler
    }

    func availability() -> CoachingModelAvailability {
        availabilityState
    }

    func generatePreparation(_ request: PreparationCoachingRequest) async throws -> RawModelCoachingSuggestion {
        preparationCallCount += 1
        if let preparationHandler {
            return try await preparationHandler(request)
        }
        let tech = request.candidateTechniques.first?.id ?? "reveal.three-part-resolution"
        return RawModelCoachingSuggestion(
            shouldAbstain: false,
            techniqueID: tech,
            exactPhrase: request.exactPhrase ?? request.scriptText,
            observationID: nil,
            action: "Try one calm beat before the highlighted line.",
            rationale: "Fits the section."
        )
    }

    func generatePostTake(_ request: PostTakeCoachingRequest) async throws -> RawModelCoachingSuggestion {
        postTakeCallCount += 1
        if let postTakeHandler {
            return try await postTakeHandler(request)
        }
        return RawModelCoachingSuggestion(
            shouldAbstain: true,
            techniqueID: "",
            exactPhrase: "",
            observationID: nil,
            action: "No change needed — replay to confirm.",
            rationale: "Clean delivery."
        )
    }
}
