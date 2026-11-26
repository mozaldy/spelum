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
    typealias PreparationHandler = @Sendable (PreparationCoachingRequest) async throws -> RawModelPreparationSelection
    typealias PostTakeHandler = @Sendable (PostTakeCoachingRequest) async throws -> RawModelPostTakeSelection

    let availabilityState: CoachingModelAvailability
    let preparationHandler: PreparationHandler?
    let postTakeHandler: PostTakeHandler?
    private(set) var preparationCallCount = 0
    private(set) var postTakeCallCount = 0

    init(
        availabilityState: CoachingModelAvailability,
        preparationHandler: PreparationHandler? = nil,
        postTakeHandler: PostTakeHandler? = nil
    ) {
        self.availabilityState = availabilityState
        self.preparationHandler = preparationHandler
        self.postTakeHandler = postTakeHandler
    }

    func availability() -> CoachingModelAvailability {
        availabilityState
    }

    func generatePreparation(_ request: PreparationCoachingRequest) async throws -> RawModelPreparationSelection {
        preparationCallCount += 1
        if let preparationHandler {
            return try await preparationHandler(request)
        }
        return Self.defaultPreparationSelection(for: request)
    }

    func generatePostTake(_ request: PostTakeCoachingRequest) async throws -> RawModelPostTakeSelection {
        postTakeCallCount += 1
        if let postTakeHandler {
            return try await postTakeHandler(request)
        }
        return Self.defaultPostTakeSelection(for: request)
    }

    static func defaultPreparationSelection(
        for request: PreparationCoachingRequest
    ) -> RawModelPreparationSelection {
        let optionSet = PreparationCoachingOptionSet.build(for: request)
        if optionSet.mustAbstain, let abstention = optionSet.abstentionOptions.first {
            return RawModelPreparationSelection(
                shouldAbstain: true,
                abstentionReasonID: abstention.id,
                techniqueID: nil,
                passageID: nil,
                actionID: nil
            )
        }
        if PreparationCoachingOptionSet.isMinimalClosingLine(request),
           let abstention = optionSet.abstentionOptions.first(where: { $0.id == "abstain.prep.minimal-signoff" }) {
            return RawModelPreparationSelection(
                shouldAbstain: true,
                abstentionReasonID: abstention.id,
                techniqueID: nil,
                passageID: nil,
                actionID: nil
            )
        }
        let tech = optionSet.candidateTechniques.first?.id ?? "reveal.three-part-resolution"
        let passage = optionSet.passageOptions.first(where: { !$0.fromHandoff })?.id
            ?? optionSet.passageOptions.first?.id
        let action = optionSet.actionOptions.first(where: { $0.techniqueID == tech })?.id
        return RawModelPreparationSelection(
            shouldAbstain: false,
            abstentionReasonID: nil,
            techniqueID: tech,
            passageID: passage,
            actionID: action
        )
    }

    static func defaultPostTakeSelection(
        for request: PostTakeCoachingRequest
    ) -> RawModelPostTakeSelection {
        let optionSet = PostTakeCoachingOptionSet.build(for: request)
        if optionSet.mustAbstain, let abstention = optionSet.abstentionOptions.first {
            return RawModelPostTakeSelection(
                shouldAbstain: true,
                abstentionReasonID: abstention.id,
                techniqueID: nil,
                passageID: nil,
                evidenceID: nil,
                actionID: nil
            )
        }
        if PostTakeCoachingOptionSet.isSupportedCleanTake(for: request),
           let cleanTake = optionSet.abstentionOptions.first(where: { $0.id == "abstain.post.clean-take" }) {
            return RawModelPostTakeSelection(
                shouldAbstain: true,
                abstentionReasonID: cleanTake.id,
                techniqueID: nil,
                passageID: nil,
                evidenceID: nil,
                actionID: nil
            )
        }
        for evidence in optionSet.evidenceOptions {
            for action in optionSet.actionOptions where action.compatibleEvidenceIDs.contains(evidence.id) {
                if let techID = optionSet.candidateTechniques.first(where: {
                    action.compatibleTechniqueIDs.contains($0.id)
                })?.id {
                    let passageID = optionSet.passageOptions.first(where: {
                        evidence.compatiblePassageIDs.contains($0.id)
                    })?.id
                    return RawModelPostTakeSelection(
                        shouldAbstain: false,
                        abstentionReasonID: nil,
                        techniqueID: techID,
                        passageID: passageID,
                        evidenceID: evidence.id,
                        actionID: action.id
                    )
                }
            }
        }
        let fallbackAbstention = optionSet.abstentionOptions.first?.id ?? "abstain.post.insufficient-evidence"
        return RawModelPostTakeSelection(
            shouldAbstain: true,
            abstentionReasonID: fallbackAbstention,
            techniqueID: nil,
            passageID: nil,
            evidenceID: nil,
            actionID: nil
        )
    }
}
