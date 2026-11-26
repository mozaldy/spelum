import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 6 Grounding & Persistence Regressions")
@MainActor
struct Task6GroundingRegressionTests {
    @Test("Finding 3A: Bounded preparation options allow personalization and quote speaker names safely")
    func boundedPrepPersonalizationAndQuoteBoundaries() throws {
        let prepRequest = CoachingTestFixtures.makeSamplePreparationRequest()
        let prepOptions = PreparationCoachingOptionSet.build(for: prepRequest)

        #expect(prepOptions.candidateTechniques.count >= 2)
        #expect(prepOptions.passageOptions.count >= 2)
        #expect(prepOptions.actionOptions.count >= prepOptions.candidateTechniques.count * 2)

        let samPassage = try #require(prepOptions.passageOptions.first { $0.phrase == "Thank you, Sam." })
        let revealTech = try #require(prepOptions.candidateTechniques.first { $0.id == "reveal.problem-to-short-line" })
        let secondaryAction = try #require(
            prepOptions.actionOptions.first { $0.techniqueID == revealTech.id && $0.id != "\(revealTech.id).core" }
        )
        let selection = RawModelPreparationSelection(
            shouldAbstain: false,
            abstentionReasonID: nil,
            techniqueID: revealTech.id,
            passageID: samPassage.id,
            actionID: secondaryAction.id
        )
        let verdict = CoachingOutputValidator.validatePreparation(selection: selection, request: prepRequest)
        #expect(verdict.isValid)
        #expect(verdict.suggestion?.exactPhrase == "Thank you, Sam.")
        #expect(verdict.suggestion?.action == secondaryAction.renderedAction)

        #expect(!CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch("ing", in: prepRequest.scriptText))
        let stageScript = "Tap Import. [pause for applause] There it is."
        #expect(!CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch("[pause for applause]", in: stageScript))
        let stagePassages = CoachingPassageExtractor.extractPassages(
            scriptText: stageScript,
            exactPhrase: nil,
            handoffCueText: nil,
            observations: []
        )
        #expect(!stagePassages.isEmpty)
        #expect(stagePassages.allSatisfy { !$0.phrase.contains("[") && !$0.phrase.contains("]") })
    }

    @Test("Finding 3B: Post-take bounded options enforce mandatory abstention and semantic passage ties")
    func boundedPostTakeMandatoryAbstentionAndSemanticTies() throws {
        let silentReq = PostTakeCoachingRequest(
            attemptID: UUID(),
            talkRevisionID: UUID(),
            sectionRevisionID: UUID(),
            sectionTitle: "Silent",
            scriptText: "Good morning everyone. Today we introduce Lumera.",
            exactPhrase: "Good morning everyone.",
            cueWords: [],
            purpose: .general,
            handoffCueText: nil,
            isSpeakerChangeHandoff: false,
            knownSpeakerNames: [],
            attemptStatus: .silentCompleted,
            practiceMode: .memory,
            playableDuration: 0,
            revealCount: 0,
            markers: [],
            timingAnalysis: nil,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .general, hasHandoff: false),
            promptVersion: SectionCoachService.postTakePromptVersion
        )
        let silentOptions = PostTakeCoachingOptionSet.build(for: silentReq)
        #expect(silentOptions.mustAbstain)
        #expect(silentOptions.evidenceOptions.isEmpty)

        let nonAbstain = RawModelPostTakeSelection(
            shouldAbstain: false,
            abstentionReasonID: nil,
            techniqueID: silentReq.candidateTechniques.first?.id,
            passageID: "passage.exact",
            evidenceID: "fact.pace.fast",
            actionID: "post.pace.breath-before-payoff"
        )
        #expect(!CoachingOutputValidator.validatePostTake(selection: nonAbstain, request: silentReq).isValid)

        let mixedAbstain = RawModelPostTakeSelection(
            shouldAbstain: true,
            abstentionReasonID: silentOptions.abstentionOptions.first?.id,
            techniqueID: silentReq.candidateTechniques.first?.id,
            passageID: nil,
            evidenceID: nil,
            actionID: nil
        )
        #expect(!CoachingOutputValidator.validatePostTake(selection: mixedAbstain, request: silentReq).isValid)

        let cleanAbstain = RawModelPostTakeSelection(
            shouldAbstain: true,
            abstentionReasonID: silentOptions.abstentionOptions.first?.id,
            techniqueID: nil,
            passageID: nil,
            evidenceID: nil,
            actionID: nil
        )
        #expect(CoachingOutputValidator.validatePostTake(selection: cleanAbstain, request: silentReq).isValid)

        let postReq = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let postOptions = PostTakeCoachingOptionSet.build(for: postReq)
        let gapEvidence = try #require(postOptions.evidenceOptions.first { $0.observationID != nil })
        let unrelatedSam = try #require(postOptions.passageOptions.first { $0.phrase == "Thank you, Sam." })
        let lumeraPassage = try #require(
            postOptions.passageOptions.first { $0.phrase == "Today we are introducing Lumera." }
        )
        #expect(!gapEvidence.compatiblePassageIDs.contains(unrelatedSam.id))
        #expect(gapEvidence.compatiblePassageIDs.contains(lumeraPassage.id))
    }

    @Test("Finding 3C: Stale v1 and v2 cached cues are ignored after v3 prompt bump")
    func stalePromptVersionCacheEntriesAreIgnored() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let store = CoachingStore(modelContext: container.mainContext)
        let prepReq = CoachingTestFixtures.makeSamplePreparationRequest()
        for legacyVersion in ["prep-v1", "prep-v2"] {
            let legacyPrep = PreparationCoachingRequest(
                presentationID: prepReq.presentationID,
                sectionRevisionID: prepReq.sectionRevisionID,
                talkRevisionID: prepReq.talkRevisionID,
                sectionTitle: prepReq.sectionTitle,
                scriptText: prepReq.scriptText,
                exactPhrase: prepReq.exactPhrase,
                cueWords: prepReq.cueWords,
                purpose: prepReq.purpose,
                handoffCueText: prepReq.handoffCueText,
                isSpeakerChangeHandoff: prepReq.isSpeakerChangeHandoff,
                knownSpeakerNames: prepReq.knownSpeakerNames,
                selectedTechniqueID: prepReq.selectedTechniqueID,
                candidateTechniques: prepReq.candidateTechniques,
                promptVersion: legacyVersion
            )
            try store.savePreparationCue(
                TechniqueLibrary.authoredPreparationSuggestion(for: legacyPrep),
                for: legacyPrep
            )
        }
        #expect(try store.fetchCachedPreparationCue(for: prepReq) == nil)

        let postReq = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        for legacyVersion in ["review-v1", "review-v2"] {
            let legacyPost = PostTakeCoachingRequest(
                presentationID: postReq.presentationID,
                attemptID: postReq.attemptID,
                talkRevisionID: postReq.talkRevisionID,
                sectionRevisionID: postReq.sectionRevisionID,
                sectionTitle: postReq.sectionTitle,
                scriptText: postReq.scriptText,
                exactPhrase: postReq.exactPhrase,
                cueWords: postReq.cueWords,
                purpose: postReq.purpose,
                handoffCueText: postReq.handoffCueText,
                isSpeakerChangeHandoff: postReq.isSpeakerChangeHandoff,
                knownSpeakerNames: postReq.knownSpeakerNames,
                attemptStatus: postReq.attemptStatus,
                practiceMode: postReq.practiceMode,
                playableDuration: postReq.playableDuration,
                revealCount: postReq.revealCount,
                markers: postReq.markers,
                timingAnalysis: postReq.timingAnalysis,
                candidateTechniques: postReq.candidateTechniques,
                promptVersion: legacyVersion
            )
            try store.savePostTakeCue(
                TechniqueLibrary.authoredPostTakeSuggestion(for: legacyPost),
                for: legacyPost
            )
        }
        #expect(try store.fetchCachedPostTakeCue(for: postReq) == nil)
    }

    @Test("Finding 6: PresentationStore.deletePresentation cleans up CoachingCueRecord entries directly")
    func presentationStoreDeleteCleansUpCoachingCueRecords() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Direct Delete Talk")

        let prepReq = SectionCoachService.makePreparationRequest(
            section: seeded.section,
            talkRevisionID: seeded.talkRevision.id,
            handoff: nil
        )
        try coachingStore.savePreparationCue(
            TechniqueLibrary.authoredPreparationSuggestion(for: prepReq),
            for: prepReq
        )
        #expect(try coachingStore.fetchCachedPreparationCue(for: prepReq) != nil)

        try library.deletePresentation(seeded.presentation)
        #expect(try coachingStore.fetchCachedPreparationCue(for: prepReq) == nil)
    }
}
