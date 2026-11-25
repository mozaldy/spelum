import Foundation
import Testing
@testable import Spelum

@Suite("Task 6 Blinded Evaluation Dataset, Runner, and Qualification Gate")
@MainActor
struct CoachingEvaluationTests {
    @Test("Synthetic CoachingCases dataset has 20 cases per task covering all categories and matches bundle")
    func syntheticDatasetHasTwentyCasesPerTaskAndMatchesBundle() throws {
        let testDataset = try CoachingTestFixtures.loadTestFixtureCoachingCases()
        let bundledDataset = try CoachingEvaluationDataset.loadBundled()

        #expect(testDataset == bundledDataset)
        #expect(bundledDataset.preparationCases.count == 20)
        #expect(bundledDataset.postTakeCases.count == 20)

        let taskCategories = [
            bundledDataset.preparationCases.map(\.category),
            bundledDataset.postTakeCases.map(\.category)
        ]
        for categories in taskCategories {
            let counts = Dictionary(grouping: categories, by: { $0 }).mapValues(\.count)
            #expect(counts[.handoff] == 5)
            #expect(counts[.reveal] == 5)
            #expect(counts[.demo] == 5)
            #expect(counts[.close] == 5)
        }

        let reviewTags = Set(bundledDataset.postTakeCases.flatMap(\.tags))
        #expect(reviewTags.contains("paraphrase"))
        #expect(reviewTags.contains("uncertainAlignment"))
        #expect(reviewTags.contains("silence"))
        #expect(reviewTags.contains("strongTake"))
        #expect(bundledDataset.postTakeCases.contains { $0.expectsAbstention })
        #expect(bundledDataset.preparationCases.contains { $0.includeInRepeatCheck })
        #expect(bundledDataset.postTakeCases.contains { $0.includeInRepeatCheck })
    }

    @Test("All 40 synthetic cases produce grounded authored cues with exact quotes, valid IDs, and abstention")
    func allFortySyntheticCasesProduceGroundedAuthoredBaselines() throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()

        for prepCase in dataset.preparationCases {
            let req = prepCase.makeRequest()
            let cue = TechniqueLibrary.authoredPreparationSuggestion(for: req)
            let expectsAbstain = prepCase.expectsAbstention || prepCase.tags.contains("abstainCandidate")
            #expect(cue.isAbstention == expectsAbstain)
            if !cue.isAbstention {
                let techID = try #require(cue.techniqueID)
                #expect(TechniqueLibrary.technique(withID: techID) != nil)
            }
            #expect(!cue.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let phrase = cue.exactPhrase, !phrase.isEmpty {
                let inScript = req.scriptText.contains(phrase)
                let inHandoff = req.handoffCueText?.contains(phrase) == true
                #expect(inScript || inHandoff)
            }
        }

        for postCase in dataset.postTakeCases {
            let req = postCase.makeRequest()
            let cue = TechniqueLibrary.authoredPostTakeSuggestion(for: req)
            if postCase.expectsAbstention {
                #expect(cue.isAbstention)
            }
            if let obsID = cue.observationID {
                let knownIDs = Set((req.timingAnalysis?.observations ?? []).map(\.id))
                #expect(knownIDs.contains(obsID))
            }
            if let phrase = cue.exactPhrase, !phrase.isEmpty {
                let inScript = req.scriptText.contains(phrase)
                let inHandoff = req.handoffCueText?.contains(phrase) == true
                #expect(inScript || inHandoff)
            }
            if postCase.isSpeakerChangeHandoff {
                let combined = "\(cue.action) \(cue.rationale)".lowercased()
                for speaker in postCase.knownSpeakerNames {
                    #expect(!combined.contains(speaker.lowercased()))
                }
            }
        }
    }

    @Test("Blinded evaluation runner measures cold/warm latency, repeat variation, and enforces gate")
    func blindedEvaluationMeasuresMetricsAndEnforcesQualificationGate() async throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let provider = StubCoachingModelProvider(
            availabilityState: .available,
            preparationHandler: { req in
                StubCoachingModelProvider.defaultPreparationSelection(for: req)
            }
        )
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(modelProvider: provider),
            repeatTrialsPerCase: 3
        )

        var session = await runner.runSuite(
            task: .preparation,
            dataset: dataset,
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0",
                deviceModel: "iPhone18,1",
                isSimulator: false
            ),
            randomSeed: 42,
            isFreshProcessLaunch: true
        )

        #expect(session.entries.count == 20)
        #expect(!session.isUnblinded)
        #expect(session.coldLatencyStatus == .verifiedColdLaunch)
        #expect(session.coldLatencyMilliseconds != nil)
        #expect(!session.warmLatenciesMilliseconds.isEmpty)
        #expect(!session.repeatVariationResults.isEmpty)
        #expect(!session.summary().isQualifiedForShipping)

        applyPassingRatings(to: &session, modelUsefulCount: 16)
        #expect(session.summary().isQualifiedForShipping)

        flagSafetyIssue(on: &session, at: 0, issue: .alteredQuote)
        #expect(!session.summary().isQualifiedForShipping)

        var simSession = session
        simSession.environment = CoachingDeviceEnvironment(
            osDescription: "iOS 27.0 Simulator",
            deviceModel: "iPhone 17 Simulator",
            isSimulator: true
        )
        clearSafetyIssues(on: &simSession, at: 0)
        #expect(!simSession.summary().isQualifiedForShipping)
    }

    @Test("CoachingEvaluationSessionStore saves, reloads, reports Markdown, and clears local sessions")
    func evaluationSessionStoreRoundTripsLocally() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("spelum-eval-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = CoachingEvaluationSessionStore(rootURL: tempRoot)
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(
                modelProvider: StubCoachingModelProvider(availabilityState: .unavailable(.deviceNotEligible))
            ),
            repeatTrialsPerCase: 2
        )
        let session = await runner.runSuite(
            task: .postTake,
            dataset: dataset,
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0 Simulator",
                deviceModel: "iPhone 17",
                isSimulator: true
            ),
            randomSeed: 7,
            isFreshProcessLaunch: false
        )

        try store.save(session)
        let loaded = try #require(store.loadLatest(for: .postTake))
        #expect(loaded.id == session.id)
        #expect(loaded.entries.count == 20)

        let report = loaded.markdownReport()
        #expect(report.contains("Spelum Blinded Coach Evaluation"))
        #expect(report.contains("Keep Authored Baseline"))

        try store.clear(for: .postTake)
        #expect(store.loadLatest(for: .postTake) == nil)
    }

    private func applyPassingRatings(to session: inout CoachingEvaluationSession, modelUsefulCount: Int) {
        for idx in session.entries.indices {
            let modelIsA = session.entries[idx].optionASource == .onDeviceModel
            let markUseful = idx < modelUsefulCount
            session.entries[idx].rating = BlindedCaseRating(
                optionAUseful: modelIsA ? markUseful : true,
                optionBUseful: modelIsA ? true : markUseful,
                optionASafetyIssues: [],
                optionBSafetyIssues: [],
                preference: markUseful ? (modelIsA ? .optionA : .optionB) : .tie
            )
        }
    }

    private func flagSafetyIssue(
        on session: inout CoachingEvaluationSession,
        at index: Int,
        issue: EvaluationSafetyIssue
    ) {
        if session.entries[index].optionASource == .onDeviceModel {
            session.entries[index].rating?.optionASafetyIssues = [issue]
        } else {
            session.entries[index].rating?.optionBSafetyIssues = [issue]
        }
    }

    private func clearSafetyIssues(on session: inout CoachingEvaluationSession, at index: Int) {
        session.entries[index].rating?.optionASafetyIssues = []
        session.entries[index].rating?.optionBSafetyIssues = []
    }
}
