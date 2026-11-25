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

    @Test("Invented quotation fails validation and reverts to safe authored cue")
    func inventedQuotationRevertsToAuthoredCue() async throws {
        let request = CoachingTestFixtures.makeSamplePreparationRequest()
        let firstTechnique = try #require(request.candidateTechniques.first)
        let provider = StubCoachingModelProvider(
            availabilityState: .available,
            preparationHandler: { _ in
                RawModelCoachingSuggestion(
                    shouldAbstain: false,
                    techniqueID: firstTechnique.id,
                    exactPhrase: "Today we are launching Lumera Pro Max forever!",
                    observationID: nil,
                    action: "Pause briefly before delivering the product name.",
                    rationale: "Sets up the reveal."
                )
            }
        )
        let service = SectionCoachService(modelProvider: provider)

        let result = await service.generatePreparationCue(request: request, mode: .onDeviceModel)

        #expect(result.origin == .authoredFallback)
        #expect(result.fallbackReason == .validationFailed(.alteredOrInventedQuote))
        #expect(result.exactPhrase != "Today we are launching Lumera Pro Max forever!")
        if let phrase = result.exactPhrase {
            #expect(request.scriptText.contains(phrase) || (request.handoffCueText?.contains(phrase) == true))
        }
    }

    @Test("Absent or invented observation ID fails post-take validation and reverts to safe authored cue")
    func absentObservationIDRevertsToAuthoredCue() async throws {
        let request = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let firstTechnique = try #require(request.candidateTechniques.first)
        let nonexistentObservationID = UUID().uuidString

        let provider = StubCoachingModelProvider(
            availabilityState: .available,
            postTakeHandler: { _ in
                RawModelCoachingSuggestion(
                    shouldAbstain: false,
                    techniqueID: firstTechnique.id,
                    exactPhrase: "Today we are introducing Lumera.",
                    observationID: nonexistentObservationID,
                    action: "Replay the beat before the reveal and test a calmer landing.",
                    rationale: "Grounded in the pause before the headline."
                )
            }
        )
        let service = SectionCoachService(modelProvider: provider)

        let result = await service.generatePostTakeCue(request: request, mode: .onDeviceModel)

        #expect(result.origin == .authoredFallback)
        #expect(result.fallbackReason == .validationFailed(.unknownObservationID))
        #expect(result.observationID != UUID(uuidString: nonexistentObservationID))
    }

    @Test("Invented measurements, performance scores, and unsupported speaker judgments fail validation")
    func unsafeModelOutputsFailValidation() async throws {
        let request = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let technique = try #require(request.candidateTechniques.first)
        let validObsID = try #require(request.timingAnalysis?.observations.first?.id)

        let inventedMeasurement = RawModelCoachingSuggestion(
            shouldAbstain: false,
            techniqueID: technique.id,
            exactPhrase: "Today we are introducing Lumera.",
            observationID: validObsID.uuidString,
            action: "You spoke at 210 WPM, so slow down before the product name.",
            rationale: "210 WPM is too fast."
        )
        let measurementVerdict = CoachingOutputValidator.validatePostTake(
            raw: inventedMeasurement,
            request: request
        )
        #expect(measurementVerdict.failureReason == .inventedMeasurement)

        let speakerBlame = RawModelCoachingSuggestion(
            shouldAbstain: false,
            techniqueID: technique.id,
            exactPhrase: "Today we are introducing Lumera.",
            observationID: validObsID.uuidString,
            action: "Ask Sam to finish sooner because Sam paused too long before your line.",
            rationale: "Sam's pause delayed the handoff."
        )
        let speakerVerdict = CoachingOutputValidator.validatePostTake(
            raw: speakerBlame,
            request: request
        )
        #expect(speakerVerdict.failureReason == .unsupportedSpeakerJudgment)

        let disallowedScore = RawModelCoachingSuggestion(
            shouldAbstain: false,
            techniqueID: technique.id,
            exactPhrase: "Today we are introducing Lumera.",
            observationID: validObsID.uuidString,
            action: "Overall score 8/10; work on your accent and sound more like Steve Jobs.",
            rationale: "Pronunciation sounded nervous."
        )
        let disallowedVerdict = CoachingOutputValidator.validatePostTake(
            raw: disallowedScore,
            request: request
        )
        #expect(disallowedVerdict.failureReason == .disallowedCoachingClaim)
    }

    @Test("Valid grounded post-take model suggestion and valid abstention pass validation")
    func validGroundedModelSuggestionAndAbstentionPass() async throws {
        let request = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let technique = try #require(request.candidateTechniques.first)
        let validObsID = try #require(request.timingAnalysis?.observations.first?.id)

        let validRaw = RawModelCoachingSuggestion(
            shouldAbstain: false,
            techniqueID: technique.id,
            exactPhrase: "Today we are introducing Lumera.",
            observationID: validObsID.uuidString,
            action: "Replay from the 0.9s pause and try landing the reveal without rushing.",
            rationale: "The bounded pause sits directly before your marked exact phrase."
        )
        let service = SectionCoachService(
            modelProvider: StubCoachingModelProvider(
                availabilityState: .available,
                postTakeHandler: { _ in validRaw }
            )
        )
        let result = await service.generatePostTakeCue(request: request, mode: .onDeviceModel)

        #expect(result.origin == .onDeviceModel)
        #expect(!result.isAbstention)
        #expect(result.techniqueID == technique.id)
        #expect(result.exactPhrase == "Today we are introducing Lumera.")
        #expect(result.observationID == validObsID)

        let abstainService = SectionCoachService(
            modelProvider: StubCoachingModelProvider(
                availabilityState: .available,
                postTakeHandler: { _ in
                    RawModelCoachingSuggestion(
                        shouldAbstain: true,
                        techniqueID: "",
                        exactPhrase: "",
                        observationID: nil,
                        action: "No change needed on this take — replay the exact phrase to confirm.",
                        rationale: "Delivery was clean with 0 reveals and aligned timing."
                    )
                }
            )
        )
        let abstainResult = await abstainService.generatePostTakeCue(request: request, mode: .onDeviceModel)
        #expect(abstainResult.origin == .onDeviceModel)
        #expect(abstainResult.isAbstention)
        #expect(abstainResult.observationID == nil)
    }
}
