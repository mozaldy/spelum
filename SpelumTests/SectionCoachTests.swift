import Foundation
import Testing
@testable import Spelum

@Suite("Task 6 Coaching Library, Grounded Validation, and Authored Fallback")
@MainActor
struct SectionCoachTests {
    @Test("Original technique library covers handoff, reveal, demo, and close with verified 2007 keynote provenance")
    func techniqueLibraryCoversCoreCategoriesWithVerifiedProvenance() {
        let techniques = TechniqueLibrary.allTechniques
        #expect(!techniques.isEmpty)

        let categories = Set(techniques.map(\.category))
        #expect(categories.contains(.handoff))
        #expect(categories.contains(.reveal))
        #expect(categories.contains(.demo))
        #expect(categories.contains(.close))

        let uniqueIDs = Set(techniques.map(\.id))
        #expect(uniqueIDs.count == techniques.count)

        for technique in techniques {
            #expect(!technique.id.isEmpty)
            #expect(!technique.title.isEmpty)
            #expect(technique.sourceWork.contains("2007"))
            #expect(technique.sourceTimestamp.contains(":"))
            #expect(!technique.sourcePassageSummary.isEmpty)
            #expect(!technique.deliveryInstruction.isEmpty)
            #expect(!technique.postTakeFocus.isEmpty)
            #expect(!technique.applicablePurposes.isEmpty)
        }
    }

    @Test("Authored defaults remain active for both preparation and post-take tasks")
    func authoredDefaultsRemainActiveByDefault() {
        let policy = CoachingFeaturePolicy.default
        #expect(policy.defaultMode(for: .preparation) == .authoredBaseline)
        #expect(policy.defaultMode(for: .postTake) == .authoredBaseline)
        #expect(!policy.isModelQualified(for: .preparation))
        #expect(!policy.isModelQualified(for: .postTake))
    }

    @Test("Unavailable on-device model safely falls back to grounded authored preparation cue")
    func unavailableModelFallsBackToAuthoredPreparationCue() async {
        let provider = StubCoachingModelProvider(
            availabilityState: .unavailable(.appleIntelligenceNotEnabled)
        )
        let service = SectionCoachService(modelProvider: provider)
        let request = CoachingTestFixtures.makeSamplePreparationRequest()

        let result = await service.generatePreparationCue(request: request, mode: .onDeviceModel)

        #expect(result.origin == .authoredFallback)
        #expect(result.fallbackReason == .modelUnavailable(.appleIntelligenceNotEnabled))
        #expect(result.techniqueID != nil)
        if let phrase = result.exactPhrase {
            #expect(request.scriptText.contains(phrase) || (request.handoffCueText?.contains(phrase) == true))
        }
        #expect(provider.preparationCallCount == 0)
    }

    @Test("Unknown passage ID fails bounded preparation validation and reverts to safe authored cue")
    func unknownPassageIDRevertsToAuthoredCue() async throws {
        let request = CoachingTestFixtures.makeSamplePreparationRequest()
        let optionSet = PreparationCoachingOptionSet.build(for: request)
        let firstTechnique = try #require(optionSet.candidateTechniques.first)
        let firstAction = try #require(optionSet.actionOptions.first { $0.techniqueID == firstTechnique.id })
        let provider = StubCoachingModelProvider(
            availabilityState: .available,
            preparationHandler: { _ in
                RawModelPreparationSelection(
                    shouldAbstain: false,
                    abstentionReasonID: nil,
                    techniqueID: firstTechnique.id,
                    passageID: "passage.invented-quote",
                    actionID: firstAction.id
                )
            }
        )
        let service = SectionCoachService(modelProvider: provider)

        let result = await service.generatePreparationCue(request: request, mode: .onDeviceModel)

        #expect(result.origin == .authoredFallback)
        #expect(result.fallbackReason == .validationFailed(.unknownPassageID))
        if let phrase = result.exactPhrase {
            #expect(request.scriptText.contains(phrase) || (request.handoffCueText?.contains(phrase) == true))
        }
    }

    @Test("Absent or invented observation ID fails post-take validation and reverts to safe authored cue")
    func absentObservationIDRevertsToAuthoredCue() async throws {
        let request = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let optionSet = PostTakeCoachingOptionSet.build(for: request)
        let firstTechnique = try #require(optionSet.candidateTechniques.first)
        let firstPassage = try #require(optionSet.passageOptions.first)
        let firstAction = try #require(optionSet.actionOptions.first)
        let nonexistentObservationID = "obs.\(UUID().uuidString.lowercased())"

        let provider = StubCoachingModelProvider(
            availabilityState: .available,
            postTakeHandler: { _ in
                RawModelPostTakeSelection(
                    shouldAbstain: false,
                    abstentionReasonID: nil,
                    techniqueID: firstTechnique.id,
                    passageID: firstPassage.id,
                    evidenceID: nonexistentObservationID,
                    actionID: firstAction.id
                )
            }
        )
        let service = SectionCoachService(modelProvider: provider)

        let result = await service.generatePostTakeCue(request: request, mode: .onDeviceModel)

        #expect(result.origin == .authoredFallback)
        #expect(result.fallbackReason == .validationFailed(.unknownObservationID))
        #expect(result.observationID?.uuidString.lowercased() != nonexistentObservationID)
    }

    @Test("Incompatible technique, passage, evidence, and action combinations fail bounded validation")
    func incompatibleBoundedSelectionsFailValidation() throws {
        let request = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let optionSet = PostTakeCoachingOptionSet.build(for: request)
        let technique = try #require(optionSet.candidateTechniques.first)
        let gapEvidence = try #require(optionSet.evidenceOptions.first { $0.observationID != nil })
        let validAction = try #require(
            optionSet.actionOptions.first { $0.compatibleEvidenceIDs.contains(gapEvidence.id) }
        )

        // Unrelated passage ("Thank you, Sam." is not adjacent to the gap at "rebuilt our recorder -> Lumera")
        let samPassage = try #require(optionSet.passageOptions.first { $0.phrase == "Thank you, Sam." })
        let unrelatedPairing = RawModelPostTakeSelection(
            shouldAbstain: false,
            abstentionReasonID: nil,
            techniqueID: technique.id,
            passageID: samPassage.id,
            evidenceID: gapEvidence.id,
            actionID: validAction.id
        )
        let unrelatedVerdict = CoachingOutputValidator.validatePostTake(
            selection: unrelatedPairing,
            request: request
        )
        #expect(unrelatedVerdict.failureReason == .incompatibleSelection)

        // Unknown action ID
        let matchingPassageID = try #require(gapEvidence.compatiblePassageIDs.first)
        let badAction = RawModelPostTakeSelection(
            shouldAbstain: false,
            abstentionReasonID: nil,
            techniqueID: technique.id,
            passageID: matchingPassageID,
            evidenceID: gapEvidence.id,
            actionID: "post.invented.action"
        )
        #expect(
            CoachingOutputValidator.validatePostTake(selection: badAction, request: request).failureReason
                == .unknownActionID
        )

        // Unknown technique ID
        let badTechnique = RawModelPostTakeSelection(
            shouldAbstain: false,
            abstentionReasonID: nil,
            techniqueID: "nonexistent.tech",
            passageID: matchingPassageID,
            evidenceID: gapEvidence.id,
            actionID: validAction.id
        )
        #expect(
            CoachingOutputValidator.validatePostTake(selection: badTechnique, request: request).failureReason
                == .unknownTechniqueID
        )
    }

    @Test("Valid bounded post-take selection and valid abstention pass validation and render deterministically")
    func validGroundedModelSuggestionAndAbstentionPass() async throws {
        let request = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let optionSet = PostTakeCoachingOptionSet.build(for: request)
        let technique = try #require(optionSet.candidateTechniques.first)
        let gapEvidence = try #require(optionSet.evidenceOptions.first { $0.observationID != nil })
        let validObsID = try #require(gapEvidence.observationID)
        let matchingPassage = try #require(
            optionSet.passageOptions.first { gapEvidence.compatiblePassageIDs.contains($0.id) }
        )
        let validAction = try #require(
            optionSet.actionOptions.first {
                $0.compatibleEvidenceIDs.contains(gapEvidence.id)
                    && $0.compatibleTechniqueIDs.contains(technique.id)
            }
        )

        let validSelection = RawModelPostTakeSelection(
            shouldAbstain: false,
            abstentionReasonID: nil,
            techniqueID: technique.id,
            passageID: matchingPassage.id,
            evidenceID: gapEvidence.id,
            actionID: validAction.id
        )
        let service = SectionCoachService(
            modelProvider: StubCoachingModelProvider(
                availabilityState: .available,
                postTakeHandler: { _ in validSelection }
            )
        )
        let result = await service.generatePostTakeCue(request: request, mode: .onDeviceModel)

        #expect(result.origin == .onDeviceModel)
        #expect(!result.isAbstention)
        #expect(result.techniqueID == technique.id)
        #expect(result.exactPhrase == matchingPassage.phrase)
        #expect(result.observationID == validObsID)
        #expect(result.action.contains("0.9s"))
        #expect(!result.rationale.lowercased().contains("sam"))
    }

    @Test("Clean-take abstention is rejected on gap takes and accepted on supported clean takes")
    func cleanTakeAbstentionGatingWorks() async throws {
        let gapRequest = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let gapOptionSet = PostTakeCoachingOptionSet.build(for: gapRequest)
        #expect(gapOptionSet.abstentionOptions.isEmpty)
        let unjustifiedCleanService = SectionCoachService(
            modelProvider: StubCoachingModelProvider(
                availabilityState: .available,
                postTakeHandler: { _ in
                    RawModelPostTakeSelection(
                        shouldAbstain: true,
                        abstentionReasonID: "abstain.post.clean-take",
                        techniqueID: nil,
                        passageID: nil,
                        evidenceID: nil,
                        actionID: nil
                    )
                }
            )
        )
        let rejectedClean = await unjustifiedCleanService.generatePostTakeCue(
            request: gapRequest,
            mode: .onDeviceModel
        )
        #expect(rejectedClean.origin == .authoredFallback)

        let dataset = try CoachingEvaluationDataset.loadBundled()
        let cleanCase = try #require(dataset.postTakeCases.first { $0.id == "review-02" })
        let cleanRequest = cleanCase.makeRequest()
        let cleanOptionSet = PostTakeCoachingOptionSet.build(for: cleanRequest)
        let abstainOption = try #require(
            cleanOptionSet.abstentionOptions.first { $0.id == "abstain.post.clean-take" }
        )
        let abstainService = SectionCoachService(
            modelProvider: StubCoachingModelProvider(
                availabilityState: .available,
                postTakeHandler: { _ in
                    RawModelPostTakeSelection(
                        shouldAbstain: true,
                        abstentionReasonID: abstainOption.id,
                        techniqueID: nil,
                        passageID: nil,
                        evidenceID: nil,
                        actionID: nil
                    )
                }
            )
        )
        let abstainResult = await abstainService.generatePostTakeCue(request: cleanRequest, mode: .onDeviceModel)
        #expect(abstainResult.origin == .onDeviceModel)
        #expect(abstainResult.isAbstention)
        #expect(abstainResult.observationID == nil)
    }
}

@Suite("Annotated Script Coaching Grounding")
@MainActor
struct AnnotatedScriptCoachingTests {
    @Test("Coaching passages ignore slide headings and inline cue markup")
    func coachingPassagesIgnoreSlideHeadingsAndInlineAnnotations() async {
        let annotatedScript = """
        # Opening Hook
        ## Slide 1: Reliable Rehearsal
        [Step forward and smile]
        Welcome everyone / to our live rehearsal \u{2197} //
        Let us begin ///

        ## Slide 2: Core Problem
        [Point at the slide diagram]
        Why do presenters lose their flow \u{2198}
        """

        #expect(
            CoachingPassageExtractor.firstSpokenSentence(in: annotatedScript)
                == "Welcome everyone to our live rehearsal"
        )
        #expect(!CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(
            "## Slide 1: Reliable Rehearsal",
            in: annotatedScript
        ))
        #expect(!CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(
            "Slide 1: Reliable Rehearsal",
            in: annotatedScript
        ))
        #expect(CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(
            "Welcome everyone to our live rehearsal",
            in: annotatedScript
        ))

        let passages = CoachingPassageExtractor.extractPassages(
            scriptText: annotatedScript,
            exactPhrase: nil,
            handoffCueText: nil,
            observations: []
        )
        #expect(passages.map(\.phrase) == [
            "Welcome everyone to our live rehearsal",
            "Let us begin",
            "Why do presenters lose their flow"
        ])

        let prepRequest = PreparationCoachingRequest(
            sectionRevisionID: UUID(),
            talkRevisionID: UUID(),
            sectionTitle: "Opening Hook",
            scriptText: annotatedScript,
            exactPhrase: nil,
            cueWords: ["rehearsal", "flow"],
            purpose: .general,
            handoffCueText: nil,
            isSpeakerChangeHandoff: false,
            knownSpeakerNames: ["Presenter"],
            selectedTechniqueID: nil,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .general, hasHandoff: false),
            promptVersion: SectionCoachService.preparationPromptVersion
        )
        let service = SectionCoachService(
            modelProvider: StubCoachingModelProvider(availabilityState: .unavailable(.modelNotReady))
        )
        let cue = await service.generatePreparationCue(request: prepRequest, mode: .onDeviceModel)
        #expect(cue.exactPhrase == "Welcome everyone to our live rehearsal")
    }

    @Test("Heading-only annotated section requires coaching abstention")
    func headingOnlyAnnotatedSectionRequiresAbstention() {
        let headingOnlyScript = """
        ## Slide 1: Logo Reveal
        [Reveal the logo and pause]
        """
        #expect(CoachingPassageExtractor.spokenWordCount(in: headingOnlyScript) == 0)
        #expect(CoachingPassageExtractor.firstSpokenSentence(in: headingOnlyScript) == nil)
        let headingOnlyRequest = PreparationCoachingRequest(
            sectionRevisionID: UUID(),
            talkRevisionID: UUID(),
            sectionTitle: "Logo Reveal",
            scriptText: headingOnlyScript,
            exactPhrase: nil,
            cueWords: [],
            purpose: .reveal,
            handoffCueText: nil,
            isSpeakerChangeHandoff: false,
            knownSpeakerNames: ["Presenter"],
            selectedTechniqueID: nil,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .reveal, hasHandoff: false),
            promptVersion: SectionCoachService.preparationPromptVersion
        )
        #expect(PreparationCoachingOptionSet.build(for: headingOnlyRequest).mustAbstain)
    }
}
