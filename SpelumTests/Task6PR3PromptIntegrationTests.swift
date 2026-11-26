import Foundation
import Testing
@testable import Spelum

@Suite("Task 6 PR #3 Real FM Prompt Integration Tests")
@MainActor
struct Task6PR3PromptIntegrationTests {
    @Test("Item 2: Protocol versions bumped past v2 and observation IDs are concise and stable")
    func protocolVersionsBumpedAndObservationIDsStable() throws {
        #expect(SectionCoachService.preparationPromptVersion == "prep-v3")
        #expect(SectionCoachService.postTakePromptVersion == "review-v3")
        #expect(CoachingEvaluationSession.currentSchemaVersion == 3)

        let req = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let optionSet = PostTakeCoachingOptionSet.build(for: req)
        let obsEvidence = try #require(optionSet.evidenceOptions.first { $0.observationID != nil })
        #expect(obsEvidence.id == "obs.1")
    }

    @Test("Item 2: Every permissible prep combination described in real FM prompts validates across all 20 cases")
    func allTwentyPrepPromptsMatchValidatorExhaustively() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()

        for prepCase in dataset.preparationCases {
            let req = prepCase.makeRequest()
            let optionSet = PreparationCoachingOptionSet.build(for: req)
            let prompt = CoachingPromptBuilder.buildPreparationPrompt(for: req, optionSet: optionSet)

            #expect(prompt.contains("Section: \(req.sectionTitle)"))
            #expect(prompt.contains("Script context:"))
            #expect(prompt.contains("Handoff/Speakers:"))

            let parsed = ParsedPromptMenus.parse(prompt)
            verifyPrepAbstentions(parsed.abstentionIDs, request: req, caseID: prepCase.id)
            if !optionSet.mustAbstain {
                #expect(!parsed.prepActions.isEmpty, "Expected prep actions on \(prepCase.id)")
                verifyPrepActions(parsed.prepActions, request: req, caseID: prepCase.id)
            }
        }
    }

    @Test("Item 2: Every permissible post-take combination described in real FM prompts validates across all 20 cases")
    func allTwentyPostTakePromptsMatchValidatorExhaustively() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()

        for postCase in dataset.postTakeCases {
            let req = postCase.makeRequest()
            let optionSet = PostTakeCoachingOptionSet.build(for: req)
            let prompt = CoachingPromptBuilder.buildPostTakePrompt(for: req, optionSet: optionSet)

            #expect(prompt.contains("Section: \(req.sectionTitle)"))
            #expect(prompt.contains("Script context:"))
            #expect(prompt.contains("Measurements:"))
            #expect(prompt.contains("Ambiguity:"))
            #expect(!prompt.contains("- passage.handoff |"), "Unreachable handoff passage leaked on \(postCase.id)")

            let parsed = ParsedPromptMenus.parse(prompt)
            verifyPostTakeAbstentions(parsed.abstentionIDs, request: req, caseID: postCase.id)
            if !optionSet.mustAbstain {
                let validCount = verifyPostTakeCombos(parsed: parsed, request: req, caseID: postCase.id)
                if !optionSet.evidenceOptions.isEmpty {
                    #expect(validCount > 0, "Expected at least one valid post-take combo on \(postCase.id)")
                }
            }
        }
    }

    @Test("Item 2: Probe review-11 demo and review-16 closing mixed techniques reject handoff mismatches")
    func probeReview11DemoAndReview16ClosingMixedTechniques() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()

        let review11 = try #require(dataset.postTakeCases.first { $0.id == "review-11" })
        let req11 = review11.makeRequest()
        let opt11 = PostTakeCoachingOptionSet.build(for: req11)
        let parsed11 = ParsedPromptMenus.parse(
            CoachingPromptBuilder.buildPostTakePrompt(for: req11, optionSet: opt11)
        )
        let syncAction = try #require(parsed11.postActions.first { $0.id == "post.gap.sync-demo-wait" })
        #expect(syncAction.techniqueIDs.allSatisfy { $0.hasPrefix("demo.") })
        #expect(!syncAction.techniqueIDs.contains { $0.hasPrefix("handoff.") })

        let obs11 = try #require(parsed11.postEvidence.first { $0.id == "obs.1" })
        let passage11 = try #require(obs11.passageIDs.first)
        let handoff11 = try #require(opt11.candidateTechniques.first { $0.id.hasPrefix("handoff.") })
        let rejectedDemo = CoachingOutputValidator.validatePostTake(
            selection: RawModelPostTakeSelection(
                shouldAbstain: false, abstentionReasonID: nil,
                techniqueID: handoff11.id, passageID: passage11,
                evidenceID: obs11.id, actionID: syncAction.id
            ),
            request: req11
        )
        #expect(rejectedDemo.failureReason == .incompatibleSelection)

        let review16 = try #require(dataset.postTakeCases.first { $0.id == "review-16" })
        let req16 = review16.makeRequest()
        let opt16 = PostTakeCoachingOptionSet.build(for: req16)
        let parsed16 = ParsedPromptMenus.parse(
            CoachingPromptBuilder.buildPostTakePrompt(for: req16, optionSet: opt16)
        )
        let slowCloseAction = try #require(parsed16.postActions.first { $0.id == "post.pace.slow-final-landing" })
        #expect(slowCloseAction.techniqueIDs.allSatisfy { $0.hasPrefix("close.") })
        #expect(!slowCloseAction.techniqueIDs.contains { $0.hasPrefix("handoff.") })

        let pace16 = try #require(parsed16.postEvidence.first { $0.id == "fact.pace.fast" })
        let passage16 = try #require(pace16.passageIDs.first)
        let handoff16 = try #require(opt16.candidateTechniques.first { $0.id.hasPrefix("handoff.") })
        let rejectedClose = CoachingOutputValidator.validatePostTake(
            selection: RawModelPostTakeSelection(
                shouldAbstain: false, abstentionReasonID: nil,
                techniqueID: handoff16.id, passageID: passage16,
                evidenceID: pace16.id, actionID: slowCloseAction.id
            ),
            request: req16
        )
        #expect(rejectedClose.failureReason == .incompatibleSelection)
    }

    @Test("Item 2: Long scripts and handoffs obey bounded context window truncation while preserving anchors")
    func longScriptAndHandoffTruncationDiscipline() {
        let opening = "Opening headline sets the stage clearly for every listener."
        let filler = String(repeating: "Detailed background context expanding the section naturally. ", count: 30)
        let anchor = "Today we are introducing Lumera with offline speech timing."
        let closing = "Final takeaway lands calmly with a short stop."
        let longScript = "\(opening) \(filler) \(anchor) \(filler) \(closing)"
        #expect(longScript.count > 3_000)

        let bounded = CoachingPromptBuilder.boundedScriptContext(scriptText: longScript, anchors: [anchor])
        #expect(bounded.count <= CoachingPromptBuilder.maxScriptContextCharacters + 40)
        #expect(bounded.contains("[truncated]"))
        #expect(bounded.contains("Opening headline"))
        #expect(bounded.contains(anchor))
        #expect(bounded.contains("short stop."))

        let longHandoff = String(repeating: "Context from the previous speaker leading in. ", count: 12)
            + "Now Maya will walk you through Lumera live."
        let boundedHandoff = CoachingPromptBuilder.boundedHandoffCue(longHandoff)
        #expect((boundedHandoff?.count ?? 0) <= CoachingPromptBuilder.maxHandoffContextCharacters)
        #expect(boundedHandoff?.contains("Lumera live.") == true)
    }

    // MARK: - Validation Helpers

    private func verifyPrepAbstentions(
        _ ids: [String],
        request: PreparationCoachingRequest,
        caseID: String
    ) {
        for abstentionID in ids {
            let verdict = CoachingOutputValidator.validatePreparation(
                selection: RawModelPreparationSelection(
                    shouldAbstain: true, abstentionReasonID: abstentionID,
                    techniqueID: nil, passageID: nil, actionID: nil
                ),
                request: request
            )
            #expect(verdict.suggestion != nil, "Prep abstention \(abstentionID) failed on \(caseID)")
        }
    }

    private func verifyPrepActions(
        _ actions: [ParsedPromptMenus.PrepAction],
        request: PreparationCoachingRequest,
        caseID: String
    ) {
        for action in actions {
            for passageID in action.passageIDs {
                let verdict = CoachingOutputValidator.validatePreparation(
                    selection: RawModelPreparationSelection(
                        shouldAbstain: false, abstentionReasonID: nil,
                        techniqueID: action.techniqueID, passageID: passageID, actionID: action.id
                    ),
                    request: request
                )
                #expect(
                    verdict.suggestion != nil,
                    "Prep combo \(action.id)/\(action.techniqueID)/\(passageID) failed on \(caseID)"
                )
            }
        }
    }

    private func verifyPostTakeAbstentions(
        _ ids: [String],
        request: PostTakeCoachingRequest,
        caseID: String
    ) {
        for abstentionID in ids {
            let verdict = CoachingOutputValidator.validatePostTake(
                selection: RawModelPostTakeSelection(
                    shouldAbstain: true, abstentionReasonID: abstentionID,
                    techniqueID: nil, passageID: nil, evidenceID: nil, actionID: nil
                ),
                request: request
            )
            #expect(verdict.suggestion != nil, "Post abstention \(abstentionID) failed on \(caseID)")
        }
    }

    private func verifyPostTakeCombos(
        parsed: ParsedPromptMenus,
        request: PostTakeCoachingRequest,
        caseID: String
    ) -> Int {
        var validCount = 0
        for evidence in parsed.postEvidence {
            for action in parsed.postActions where action.evidenceIDs.contains(evidence.id) {
                let sharedTechs = Set(evidence.techniqueIDs).intersection(action.techniqueIDs)
                validCount += validatePostTakePair(
                    evidence: evidence,
                    action: action,
                    sharedTechs: sharedTechs,
                    request: request,
                    caseID: caseID
                )
            }
        }
        return validCount
    }

    private func validatePostTakePair(
        evidence: ParsedPromptMenus.PostEvidence,
        action: ParsedPromptMenus.PostAction,
        sharedTechs: Set<String>,
        request: PostTakeCoachingRequest,
        caseID: String
    ) -> Int {
        var count = 0
        for techID in sharedTechs {
            for passageID in evidence.passageIDs {
                let verdict = CoachingOutputValidator.validatePostTake(
                    selection: RawModelPostTakeSelection(
                        shouldAbstain: false, abstentionReasonID: nil,
                        techniqueID: techID, passageID: passageID,
                        evidenceID: evidence.id, actionID: action.id
                    ),
                    request: request
                )
                #expect(
                    verdict.suggestion != nil,
                    "Post combo \(evidence.id)/\(passageID)/\(techID)/\(action.id) failed on \(caseID)"
                )
                count += 1
            }
        }
        return count
    }
}

private struct ParsedPromptMenus {
    struct PrepAction {
        let id: String
        let techniqueID: String
        let passageIDs: [String]
    }

    struct PostEvidence {
        let id: String
        let passageIDs: [String]
        let techniqueIDs: [String]
    }

    struct PostAction {
        let id: String
        let evidenceIDs: [String]
        let techniqueIDs: [String]
    }

    var abstentionIDs: [String] = []
    var prepActions: [PrepAction] = []
    var postEvidence: [PostEvidence] = []
    var postActions: [PostAction] = []

    static func parse(_ prompt: String) -> ParsedPromptMenus {
        var result = ParsedPromptMenus()
        var section = ""

        for rawLine in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("Allowed ") {
                section = line
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            let parts = String(line.dropFirst(2)).components(separatedBy: " | ")
            guard let id = parts.first else { continue }
            result.record(id: id, parts: parts, section: section)
        }
        return result
    }

    private mutating func record(id: String, parts: [String], section: String) {
        switch section {
        case "Allowed Abstention Options:":
            abstentionIDs.append(id)
        case "Allowed Evidence Options:":
            let passages = Self.extractBracketList(prefix: "passages=[", in: parts)
            let techs = Self.extractBracketList(prefix: "techniques=[", in: parts)
            postEvidence.append(PostEvidence(id: id, passageIDs: passages, techniqueIDs: techs))
        case "Allowed Action Options:":
            if let techPart = parts.first(where: { $0.hasPrefix("technique=") }) {
                let techID = String(techPart.dropFirst("technique=".count))
                let passages = Self.extractBracketList(prefix: "passages=[", in: parts)
                prepActions.append(PrepAction(id: id, techniqueID: techID, passageIDs: passages))
            } else {
                let evIDs = Self.extractBracketList(prefix: "evidence=[", in: parts)
                let techs = Self.extractBracketList(prefix: "techniques=[", in: parts)
                postActions.append(PostAction(id: id, evidenceIDs: evIDs, techniqueIDs: techs))
            }
        default:
            break
        }
    }

    private static func extractBracketList(prefix: String, in parts: [String]) -> [String] {
        guard let part = parts.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix("]") }) else {
            return []
        }
        let inner = part.dropFirst(prefix.count).dropLast(1)
        return inner.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}
