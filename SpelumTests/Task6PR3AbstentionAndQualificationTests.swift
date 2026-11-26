import Foundation
import Testing
@testable import Spelum

@Suite("Task 6 PR #3 Abstention, Ambiguity & Qualification Tests")
@MainActor
struct Task6PR3AbstentionAndQualificationTests {
    private let physicalEnv = CoachingDeviceEnvironment(
        osDescription: "iOS 27.0",
        deviceModel: "iPhone18,1",
        isSimulator: false
    )

    @Test("Item 3: Unjustified clean-take abstention removed whenever inputs cannot support it across all 20 cases")
    func unjustifiedCleanTakeOptionRemovedAcrossSyntheticCases() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let supportedCleanIDs: Set<String> = ["review-02", "review-08", "review-14", "review-18"]

        for postCase in dataset.postTakeCases {
            let req = postCase.makeRequest()
            let optionSet = PostTakeCoachingOptionSet.build(for: req)
            let hasCleanTake = optionSet.abstentionOptions.contains { $0.id == "abstain.post.clean-take" }
            if supportedCleanIDs.contains(postCase.id) {
                #expect(hasCleanTake, "Expected clean-take option on \(postCase.id)")
            } else {
                #expect(!hasCleanTake, "Unjustified clean-take option offered on \(postCase.id)")
                for option in optionSet.abstentionOptions {
                    #expect(!option.renderedAction.localizedCaseInsensitiveContains("clean take"))
                    #expect(!option.renderedRationale.localizedCaseInsensitiveContains("cleanly"))
                }
            }
        }
    }

    @Test("Item 3: All 40 cases respect ambiguity, never imply demo/reveals = poor performance, keep personalization")
    func allFortyCasesRespectAmbiguityDemoRevealsAndPersonalization() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let forbiddenWords = ["poor", "forgot", "struggled", "failed", "badly", "weak"]

        for prepCase in dataset.preparationCases {
            let req = prepCase.makeRequest()
            let authored = TechniqueLibrary.authoredPreparationSuggestion(for: req)
            let optionSet = PreparationCoachingOptionSet.build(for: req)
            assertNoForbiddenWords(
                authored.action + " " + authored.rationale,
                forbidden: forbiddenWords,
                id: prepCase.id
            )
            if !optionSet.mustAbstain {
                #expect(optionSet.candidateTechniques.count >= 2, "Keep techniques on \(prepCase.id)")
                #expect(optionSet.actionOptions.count >= 2, "Keep actions on \(prepCase.id)")
            }
        }

        for postCase in dataset.postTakeCases {
            let req = postCase.makeRequest()
            let authored = TechniqueLibrary.authoredPostTakeSuggestion(for: req)
            let optionSet = PostTakeCoachingOptionSet.build(for: req)
            if PostTakeCoachingOptionSet.hasBlockingAmbiguity(in: req) {
                #expect(!authored.action.contains("WPM"), "Authored pace leaked on \(postCase.id)")
                #expect(!optionSet.evidenceOptions.contains { $0.id == "fact.pace.fast" || $0.id == "fact.pace.slow" })
            }
            assertNoForbiddenWords(
                authored.action + " " + authored.rationale,
                forbidden: forbiddenWords,
                id: postCase.id
            )
            for option in optionSet.abstentionOptions {
                assertNoForbiddenWords(
                    option.renderedAction + " " + option.renderedRationale,
                    forbidden: forbiddenWords,
                    id: "\(postCase.id):\(option.id)"
                )
            }
            if !optionSet.mustAbstain && !optionSet.evidenceOptions.isEmpty {
                #expect(optionSet.candidateTechniques.count >= 2, "Keep techniques on \(postCase.id)")
                #expect(optionSet.actionOptions.count >= 2, "Keep actions on \(postCase.id)")
            }
        }
    }

    @Test("Item 3: Mixed ambiguity + 175 WPM + reveals suppresses pace in authored, model options, and prompt")
    func mixedAmbiguityFastPaceAndRevealsSuppressesPaceAndCleanTake() {
        let alignedObs = TimingObservation(
            id: UUID(),
            kind: .alignedExactPhrase,
            title: "Exact phrase aligned",
            detail: "Estimated alignment for marked exact phrase.",
            startTime: 4.0,
            endTime: 7.2,
            matchedPhrase: "HarborSync is forty-nine dollars once."
        )
        let variants: [(String, PostTakeCoachingRequest)] = [
            ("withObs", makeMixedAmbiguityRequest(observations: [alignedObs])),
            ("noObs", makeMixedAmbiguityRequest(observations: []))
        ]
        for (label, req) in variants {
            let authored = TechniqueLibrary.authoredPostTakeSuggestion(for: req)
            #expect(!authored.action.contains("175"), "Authored leaked 175 on \(label)")
            #expect(!authored.action.contains("WPM"), "Authored leaked WPM on \(label)")
            #expect(!authored.rationale.contains("175"), "Authored rationale leaked 175 on \(label)")

            let optionSet = PostTakeCoachingOptionSet.build(for: req)
            #expect(!optionSet.evidenceOptions.contains { $0.id == "fact.pace.fast" })
            #expect(!optionSet.abstentionOptions.contains { $0.id == "abstain.post.clean-take" })
            #expect(optionSet.evidenceOptions.contains { $0.id == "fact.reveals" })
            #expect(optionSet.abstentionOptions.contains { $0.id == "abstain.post.uncertain-timing" })

            let prompt = CoachingPromptBuilder.buildPostTakePrompt(for: req, optionSet: optionSet)
            #expect(prompt.contains("reliableWPM=withheld(timing-ambiguity)"))
            #expect(!prompt.contains("fact.pace.fast"))
            #expect(!prompt.contains("abstain.post.clean-take"))
        }
    }

    @Test("Item 3: Missed optional abstention qualifies when human rates >=16/20 useful with benefit")
    func missedOptionalAbstentionFollowsHumanRatings() async throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(
                modelProvider: StubCoachingModelProvider(
                    availabilityState: .available,
                    preparationHandler: { req in
                        let opt = PreparationCoachingOptionSet.build(for: req)
                        let tech = opt.candidateTechniques[0]
                        let passage = opt.passageOptions.first { !$0.fromHandoff } ?? opt.passageOptions[0]
                        let action = opt.actionOptions.first { $0.techniqueID == tech.id }
                        return RawModelPreparationSelection(
                            shouldAbstain: false, abstentionReasonID: nil,
                            techniqueID: tech.id, passageID: passage.id, actionID: action?.id
                        )
                    }
                )
            ),
            repeatTrialsPerCase: 2
        )
        var session = await runner.runSuite(
            task: .preparation, dataset: dataset, environment: physicalEnv,
            randomSeed: 5, isFreshProcessLaunch: true
        )
        rateAll(session: &session, modelUsefulCount: 20, preferModelCount: 15)
        let stats = session.summary()
        #expect(stats.modelMissedAbstentionCount == 1)
        #expect(stats.isQualifiedForShipping)
    }

    @Test("Item 3: False optional abstention and safety violations gate qualification consistently via human ratings")
    func falseOptionalAbstentionAndSafetyViolationsGateQualification() async throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(
                modelProvider: StubCoachingModelProvider(
                    availabilityState: .available,
                    postTakeHandler: { req in
                        let opt = PostTakeCoachingOptionSet.build(for: req)
                        if opt.abstentionOptions.contains(where: { $0.id == "abstain.post.demo-silence-ok" }) {
                            return RawModelPostTakeSelection(
                                shouldAbstain: true, abstentionReasonID: "abstain.post.demo-silence-ok",
                                techniqueID: nil, passageID: nil, evidenceID: nil, actionID: nil
                            )
                        }
                        return StubCoachingModelProvider.defaultPostTakeSelection(for: req)
                    }
                )
            ),
            repeatTrialsPerCase: 2
        )
        var session = await runner.runSuite(
            task: .postTake, dataset: dataset, environment: physicalEnv,
            randomSeed: 6, isFreshProcessLaunch: true
        )
        rateAll(session: &session, modelUsefulCount: 15, preferModelCount: 12)
        #expect(session.summary().modelFalseAbstentionCount >= 1)
        #expect(!session.summary().isQualifiedForShipping)

        rateAll(session: &session, modelUsefulCount: 16, preferModelCount: 12)
        #expect(session.summary().isQualifiedForShipping)

        let modelIsA = session.entries[0].optionASource == .onDeviceModel
        session.entries[0].rating = BlindedCaseRating(
            optionAUseful: true, optionBUseful: true,
            optionASafetyIssues: modelIsA ? [.inventedMeasurement] : [],
            optionBSafetyIssues: modelIsA ? [] : [.inventedMeasurement],
            preference: modelIsA ? .optionA : .optionB
        )
        #expect(session.summary().totalModelSafetyViolations == 1)
        #expect(!session.summary().isQualifiedForShipping)
    }

    @Test("Item 3: Missing mandatory abstention fails validation and disqualifies session")
    func missingMandatoryAbstentionDisqualifiesViaValidationFailure() async throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(
                modelProvider: StubCoachingModelProvider(
                    availabilityState: .available,
                    postTakeHandler: { req in
                        if req.attemptStatus == .silentCompleted {
                            return RawModelPostTakeSelection(
                                shouldAbstain: false, abstentionReasonID: nil,
                                techniqueID: req.candidateTechniques.first?.id,
                                passageID: "passage.exact",
                                evidenceID: "fact.reveals",
                                actionID: "post.reveals.anchor-recall"
                            )
                        }
                        return StubCoachingModelProvider.defaultPostTakeSelection(for: req)
                    }
                )
            ),
            repeatTrialsPerCase: 2
        )
        var session = await runner.runSuite(
            task: .postTake, dataset: dataset, environment: physicalEnv,
            randomSeed: 8, isFreshProcessLaunch: true
        )
        rateAll(session: &session, modelUsefulCount: 20, preferModelCount: 20)
        let stats = session.summary()
        #expect(stats.modelValidationFailureCount >= 1)
        #expect(stats.modelFallbackCount >= 1)
        #expect(!stats.isQualifiedForShipping)
    }
}

private extension Task6PR3AbstentionAndQualificationTests {
    func assertNoForbiddenWords(_ text: String, forbidden: [String], id: String) {
        let lower = text.lowercased()
        for word in forbidden {
            #expect(!lower.contains(word), "Judgmental word '\(word)' in \(id)")
        }
    }

    func rateAll(
        session: inout CoachingEvaluationSession,
        modelUsefulCount: Int,
        preferModelCount: Int
    ) {
        for idx in session.entries.indices {
            let modelIsA = session.entries[idx].optionASource == .onDeviceModel
            let modelUseful = idx < modelUsefulCount
            let preferModel = idx < preferModelCount
            let pref: BlindedPreference = preferModel
                ? (modelIsA ? .optionA : .optionB)
                : (modelIsA ? .optionB : .optionA)
            session.entries[idx].rating = BlindedCaseRating(
                optionAUseful: modelIsA ? modelUseful : true,
                optionBUseful: modelIsA ? true : modelUseful,
                preference: pref
            )
        }
    }

    func makeMixedAmbiguityRequest(observations: [TimingObservation]) -> PostTakeCoachingRequest {
        let attemptID = UUID()
        let talkID = UUID()
        let sectionID = UUID()
        let ambiguity = AmbiguousEvidenceNote(
            reason: .incompleteTimingCoverage,
            title: "Incomplete timing coverage",
            explanation: "Some final recognized words lacked audio time ranges.",
            suggestedMarkerLabel: "Price line"
        )
        return PostTakeCoachingRequest(
            attemptID: attemptID, talkRevisionID: talkID, sectionRevisionID: sectionID,
            sectionTitle: "Price Reveal",
            scriptText: "Teams normally pay ninety dollars a month. HarborSync is forty-nine dollars once.",
            exactPhrase: "HarborSync is forty-nine dollars once.",
            cueWords: ["ninety", "forty-nine"], purpose: .reveal,
            handoffCueText: nil, isSpeakerChangeHandoff: false, knownSpeakerNames: ["Presenter"],
            attemptStatus: .ready, practiceMode: .cueWords, playableDuration: 9.0, revealCount: 2,
            markers: [],
            timingAnalysis: TimingAnalysisResult(
                attemptID: attemptID, talkRevisionID: talkID, sectionRevisionID: sectionID,
                localeIdentifier: "en_US", outcome: .completed, elapsedAudioDuration: 9.0,
                recognizedWordCount: 26, timingGranularity: .wordLevel, estimatedWordsPerMinute: 175.0,
                observations: observations, ambiguousNotes: [ambiguity],
                finalizedSegmentCount: 26, hasOverlappingSegments: false, hasUntimedFinalText: true
            ),
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .reveal, hasHandoff: false),
            promptVersion: SectionCoachService.postTakePromptVersion
        )
    }
}
