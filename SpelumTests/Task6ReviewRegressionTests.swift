import Foundation
import Testing
@testable import Spelum

@Suite("Task 6 Independent Review Regressions")
@MainActor
struct Task6ReviewRegressionTests {
    @Test("Finding 1: Fallback entries never earn model usefulness, preference, or shipping qualification")
    func fallbackEntriesNeverQualifyOrEarnModelCredit() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let entries = dataset.preparationCases.map { Self.makeFallbackEntry(from: $0) }
        let session = CoachingEvaluationSession(
            id: UUID(),
            task: .preparation,
            datasetVersion: dataset.datasetVersion,
            promptVersion: SectionCoachService.preparationPromptVersion,
            createdAt: Date(),
            updatedAt: Date(),
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0",
                deviceModel: "iPhone18,1",
                isSimulator: false
            ),
            modelAvailability: .available,
            isUnblinded: true,
            coldLatencyMilliseconds: nil,
            warmLatenciesMilliseconds: [],
            repeatVariationResults: [],
            entries: entries
        )

        let stats = session.summary()
        #expect(stats.modelFallbackCount == 20)
        #expect(stats.modelValidationFailureCount == 20)
        #expect(stats.modelUsefulCount == 0)
        #expect(stats.modelPreferredCount == 0)
        #expect(stats.fallbackPreferredCount == 20)
        #expect(!stats.isQualifiedForShipping)
    }

    @Test("Finding 4A: Preparation dataset includes abstention check and titles avoid technique/abstention hints")
    func evaluationDatasetAvoidsHintBearingTitlesAndIncludesPrepAbstention() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        #expect(dataset.preparationCases.contains { $0.expectsAbstention })

        for evalCase in dataset.postTakeCases {
            #expect(!evalCase.title.lowercased().contains("needing no correction"))
            #expect(!evalCase.title.lowercased().contains("rushed final cadence"))
        }
        for evalCase in dataset.preparationCases {
            #expect(!evalCase.title.lowercased().contains("lineup identity"))
            #expect(!evalCase.title.lowercased().contains("three-part setup resolving"))
            #expect(!evalCase.title.lowercased().contains("problem contrast into short headline"))
        }
    }

    @Test("Finding 5: Failed generations excluded from latency/repeat and warmed process cannot claim cold latency")
    func failedGenerationsAndWarmedProcessLatencyIntegrity() async throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let failingProvider = StubCoachingModelProvider(
            availabilityState: .available,
            preparationHandler: { _ in
                throw NSError(domain: "StubModelError", code: 1)
            }
        )
        let failingRunner = CoachingEvaluationRunner(
            coachService: SectionCoachService(modelProvider: failingProvider),
            repeatTrialsPerCase: 3
        )
        let failedSession = await failingRunner.runSuite(
            task: .preparation,
            dataset: dataset,
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0",
                deviceModel: "iPhone18,1",
                isSimulator: false
            ),
            randomSeed: 99,
            isFreshProcessLaunch: true
        )

        #expect(failedSession.coldLatencyStatus == .firstCallFailed)
        #expect(failedSession.coldLatencyMilliseconds == nil)
        #expect(failedSession.warmLatenciesMilliseconds.isEmpty)
        for entry in failedSession.entries {
            #expect(entry.modelLatencyMilliseconds == nil)
            #expect(entry.modelFellBackToAuthored)
        }
        for repeatItem in failedSession.repeatVariationResults {
            #expect(repeatItem.fallbackCount == 3)
            #expect(repeatItem.successfulTrialCount == 0)
            #expect(repeatItem.techniqueAgreementRate == nil)
            #expect(repeatItem.meanTokenOverlapSimilarity == nil)
            #expect(repeatItem.trialLatenciesMilliseconds.isEmpty)
        }

        let workingRunner = CoachingEvaluationRunner(
            coachService: SectionCoachService(modelProvider: StubCoachingModelProvider(availabilityState: .available)),
            repeatTrialsPerCase: 2
        )
        let warmedSession = await workingRunner.runSuite(
            task: .postTake,
            dataset: dataset,
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0",
                deviceModel: "iPhone18,1",
                isSimulator: false
            ),
            randomSeed: 12,
            isFreshProcessLaunch: false
        )
        #expect(warmedSession.coldLatencyStatus == .processAlreadyWarmed)
        #expect(warmedSession.coldLatencyMilliseconds == nil)
        #expect(warmedSession.warmLatenciesMilliseconds.count == 20)
    }

    private static func makeFallbackEntry(from prepCase: PreparationEvaluationCase) -> BlindedEvaluationEntry {
        let request = prepCase.makeRequest()
        let authored = TechniqueLibrary.authoredPreparationSuggestion(for: request)
        let fallback = TechniqueLibrary.authoredPreparationSuggestion(
            for: request,
            origin: .authoredFallback,
            fallbackReason: .validationFailed(.unknownTechniqueID)
        )
        return BlindedEvaluationEntry(
            id: prepCase.id,
            category: prepCase.category,
            title: prepCase.title,
            sectionTitle: prepCase.sectionTitle,
            scriptText: prepCase.scriptText,
            handoffCueText: prepCase.handoffCueText,
            tags: prepCase.tags,
            expectsAbstention: prepCase.expectsAbstention,
            contextSummary: "Purpose: \(prepCase.purpose.displayName)",
            optionASource: .onDeviceModel,
            optionBSource: .authoredBaseline,
            optionASuggestion: fallback,
            optionBSuggestion: authored,
            modelLatencyMilliseconds: nil,
            modelFellBackToAuthored: true,
            modelFallbackSummary: fallback.fallbackReason?.userSummary,
            rating: BlindedCaseRating(
                optionAUseful: true,
                optionBUseful: true,
                preference: .optionA
            )
        )
    }
}

@Suite("Task 6 Legacy Evaluation & Rating Regressions")
@MainActor
struct Task6LegacyEvaluationRegressionTests {
    @Test("Finding 4B: Legacy saved sessions mask hint notes while blinded and cannot falsely qualify")
    func legacySavedSessionsMaskHintsAndCannotQualify() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let entries = dataset.preparationCases.map { prepCase in
            let request = prepCase.makeRequest()
            let authored = TechniqueLibrary.authoredPreparationSuggestion(for: request)
            let model = TechniqueLibrary.authoredPreparationSuggestion(for: request, origin: .onDeviceModel)
            return BlindedEvaluationEntry(
                id: prepCase.id,
                category: prepCase.category,
                title: "Lineup identity closing statement",
                sectionTitle: prepCase.sectionTitle,
                scriptText: prepCase.scriptText,
                handoffCueText: prepCase.handoffCueText,
                tags: prepCase.tags,
                expectsAbstention: prepCase.expectsAbstention,
                contextSummary: "Purpose: \(prepCase.purpose.displayName) · Echoing the teammate's closing theme.",
                optionASource: .onDeviceModel,
                optionBSource: .authoredBaseline,
                optionASuggestion: model,
                optionBSuggestion: authored,
                modelLatencyMilliseconds: 120,
                modelFellBackToAuthored: false,
                modelFallbackSummary: nil,
                rating: BlindedCaseRating(optionAUseful: true, optionBUseful: true, preference: .optionA)
            )
        }
        let legacySession = CoachingEvaluationSession(
            id: UUID(),
            evaluationSchemaVersion: 1,
            task: .preparation,
            datasetVersion: "2026-11-25-v1",
            promptVersion: "prep-v1",
            createdAt: Date(),
            updatedAt: Date(),
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0",
                deviceModel: "iPhone18,1",
                isSimulator: false
            ),
            modelAvailability: .available,
            isUnblinded: false,
            coldLatencyStatus: .unknownLegacy,
            coldLatencyMilliseconds: 250,
            warmLatenciesMilliseconds: [120],
            repeatVariationResults: [],
            entries: entries
        )

        #expect(legacySession.isLegacySession)
        #expect(!legacySession.summary().isQualifiedForShipping)

        let firstEntry = try #require(legacySession.entries.first)
        let blindedTitle = firstEntry.displayTitle(at: 0, isUnblinded: false)
        #expect(!blindedTitle.lowercased().contains("lineup identity"))
        #expect(blindedTitle.contains(firstEntry.sectionTitle))

        let blindedContext = firstEntry.displayContextSummary(for: .preparation, isUnblinded: false)
        #expect(!blindedContext.contains("Echoing"))
        #expect(blindedContext.hasPrefix("Purpose:"))
    }

    @Test("Finding 4C: Intentional rating draft requires explicit choices and early unblinding disqualifies")
    func intentionalRatingDraftAndEarlyUnblindingGate() async throws {
        var draft = BlindedCaseRatingDraft()
        #expect(!draft.isComplete)
        #expect(draft.buildRating() == nil)

        draft.optionAUseful = true
        draft.optionBUseful = false
        #expect(!draft.isComplete)

        draft.preference = .optionA
        #expect(draft.isComplete)
        let rating = try #require(draft.buildRating())
        #expect(rating.optionAUseful && !rating.optionBUseful && rating.preference == .optionA)

        let dataset = try CoachingEvaluationDataset.loadBundled()
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(modelProvider: StubCoachingModelProvider(availabilityState: .available)),
            repeatTrialsPerCase: 2
        )
        var session = await runner.runSuite(
            task: .preparation,
            dataset: dataset,
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0",
                deviceModel: "iPhone18,1",
                isSimulator: false
            ),
            randomSeed: 7,
            isFreshProcessLaunch: true
        )
        for idx in session.entries.indices {
            let modelIsA = session.entries[idx].optionASource == .onDeviceModel
            session.entries[idx].rating = BlindedCaseRating(
                optionAUseful: true,
                optionBUseful: true,
                preference: modelIsA ? .optionA : .optionB
            )
        }
        #expect(session.summary().isQualifiedForShipping)

        session.unblindedEarly = true
        #expect(!session.summary().isQualifiedForShipping)
    }

    @Test("Finding 4D: Legacy v1 JSON session decodes cleanly, sanitizes fallback repeats, and cannot qualify")
    func legacyJSONDecodingPreservesDataAndBlocksFalseQualification() throws {
        let legacyJSON = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "task": "preparation",
          "datasetVersion": "2026-11-25-v1",
          "promptVersion": "prep-v1",
          "createdAt": "2026-11-25T10:00:00Z",
          "updatedAt": "2026-11-25T10:05:00Z",
          "environment": { "osDescription": "iOS 27.0", "deviceModel": "iPhone18,1", "isSimulator": false },
          "modelAvailability": { "available": {} },
          "isUnblinded": false,
          "coldLatencyMilliseconds": 310.0,
          "warmLatenciesMilliseconds": [180.0],
          "repeatVariationResults": [
            {
              "id": "prep-01",
              "caseTitle": "Legacy Repeat",
              "trialCount": 3,
              "uniqueActionCount": 1,
              "techniqueAgreementRate": 1.0,
              "meanTokenOverlapSimilarity": 1.0,
              "trialLatenciesMilliseconds": [],
              "fallbackCount": 3
            }
          ],
          "entries": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CoachingEvaluationSession.self, from: Data(legacyJSON.utf8))
        #expect(decoded.evaluationSchemaVersion == 1)
        #expect(decoded.isLegacySession)
        #expect(decoded.coldLatencyStatus == .unknownLegacy)
        #expect(!decoded.unblindedEarly)
        #expect(!decoded.summary().isQualifiedForShipping)
        let repeatItem = try #require(decoded.repeatVariationResults.first)
        #expect(repeatItem.successfulTrialCount == 0)
        #expect(repeatItem.techniqueAgreementRate == nil)
        #expect(repeatItem.meanTokenOverlapSimilarity == nil)
    }
}
