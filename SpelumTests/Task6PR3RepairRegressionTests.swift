import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Task 6 PR #3 Blinded Evidence & Small-Issue Regressions")
@MainActor
struct Task6PR3RepairRegressionTests {
    // MARK: - Item 1: Blinded Post-Take Evidence, Persistence, Legacy v2, Ineligible Scoring

    @Test("Item 1: Blinded post-take entries persist neutral actual evidence across save/reload")
    func blindedPostTakeEvidencePersistedAcrossRoundTrip() async throws {
        let session = try await makePostTakeSession(seed: 11)
        #expect(session.evaluationSchemaVersion == CoachingEvaluationSession.currentSchemaVersion)
        #expect(session.entries.count == 20)
        #expect(session.entries.allSatisfy { $0.postTakeEvidence != nil })

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpelumPR3Persist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = CoachingEvaluationSessionStore(rootURL: tempDir)
        try store.save(session)
        let reloaded = try #require(store.loadLatest(for: .postTake))
        #expect(reloaded.id == session.id)
        #expect(reloaded.evaluationSchemaVersion == session.evaluationSchemaVersion)
        #expect(reloaded.entries.map(\.postTakeEvidence) == session.entries.map(\.postTakeEvidence))
        #expect(reloaded.entries.map(\.exactPhrase) == session.entries.map(\.exactPhrase))
        #expect(reloaded.entries.map(\.knownSpeakerNames) == session.entries.map(\.knownSpeakerNames))

        let review01 = try #require(reloaded.entries.first { $0.id == "review-01" })
        let ev01 = try #require(review01.postTakeEvidence)
        #expect(review01.exactPhrase == "Today we are introducing Lumera.")
        #expect(review01.speakerContextSummary?.contains("Sam") == true)
        #expect(review01.speakerContextSummary?.contains("Maya") == true)
        #expect(ev01.estimatedWordsPerMinute == 108.0)
        let gap01 = try #require(ev01.observations.first { $0.kind == .phraseGap })
        #expect(gap01.intervalDisplayText.contains("5.2s"))
        #expect(gap01.intervalDisplayText.contains("0.9s"))
        #expect(gap01.passageDisplayText?.contains("rebuilt our recorder") == true)
        #expect(ev01.ambiguityNotes.contains { $0.reason == .multiSpeakerBoundary })

        let review03 = try #require(reloaded.entries.first { $0.id == "review-03" })
        let ev03 = try #require(review03.postTakeEvidence)
        #expect(ev03.revealCount == 2)
        let marker03 = try #require(ev03.markers.first)
        #expect(marker03.formattedLine.contains("Hesitated on stat"))
        #expect(marker03.formattedLine.contains("4.5s"))
    }

    @Test("Item 1: Blinded post-take screen omits option identity, expected abstention, and aggregate verdict")
    func blindedPostTakeSheetOmitsLeaks() async throws {
        let session = try await makePostTakeSession(seed: 11)
        let review01 = try #require(session.entries.first { $0.id == "review-01" })
        let blindedTitle = review01.displayTitle(at: 0, isUnblinded: false)
        #expect(blindedTitle == "Case 1 · Taking the Stage")
        #expect(!blindedTitle.localizedCaseInsensitiveContains("abstention"))

        let sheet = CoachingEvaluationCaseSheet(
            task: .postTake,
            entry: review01,
            caseIndex: 0,
            totalCases: session.entries.count,
            isUnblinded: false,
            hasNextCase: true,
            onSave: { _, _ in }
        )
        let rendered = PR3TestViewSnapshot.collectStrings(from: sheet).joined(separator: "\n")
        #expect(!rendered.contains("Authored Baseline"))
        #expect(!rendered.contains("On-Device Model"))
        #expect(!rendered.contains("Abstention check"))
        #expect(!rendered.contains("Qualified for On-Device"))
        #expect(!rendered.contains("Qualification Verdict"))

        let review04 = try #require(session.entries.first { $0.id == "review-04" })
        let rowStrings = PR3TestViewSnapshot.collectStrings(
            from: CoachingEvaluationCaseRow(index: 3, entry: review04, isUnblinded: false)
        ).joined(separator: "\n")
        #expect(!rowStrings.contains("Abstention check"))
        #expect(!rowStrings.contains("Fallback"))
    }

    @Test("Item 1: Legacy v2 JSON decodes cleanly and missing post-take evidence blocks shipping qualification")
    func legacyV2DecodingAndMissingPostTakeEvidenceIneligible() async throws {
        var v3Session = try await makePostTakeSession(seed: 7)
        for idx in v3Session.entries.indices {
            let modelIsA = v3Session.entries[idx].optionASource == .onDeviceModel
            v3Session.entries[idx].rating = BlindedCaseRating(
                optionAUseful: true,
                optionBUseful: true,
                preference: modelIsA ? .optionA : .optionB
            )
        }
        #expect(v3Session.summary().hasCompleteRatingEvidence)
        #expect(v3Session.summary().isQualifiedForShipping)

        let rawData = try makeEncoder().encode(v3Session)
        let legacyData = try stripPostTakeEvidence(from: rawData, schemaVersion: 2, promptVersion: "review-v2")
        let decodedLegacy = try makeDecoder().decode(CoachingEvaluationSession.self, from: legacyData)
        #expect(decodedLegacy.isLegacySession)
        let legacyStats = decodedLegacy.summary()
        #expect(legacyStats.missingPostTakeEvidenceCount == 20)
        #expect(!legacyStats.hasCompleteRatingEvidence)
        #expect(!legacyStats.isQualifiedForShipping)

        let partialData = try stripFirstEntryPostTakeEvidence(from: rawData)
        let decodedPartial = try makeDecoder().decode(CoachingEvaluationSession.self, from: partialData)
        let partialStats = decodedPartial.summary()
        #expect(!decodedPartial.isLegacySession)
        #expect(partialStats.missingPostTakeEvidenceCount == 1)
        #expect(!partialStats.hasCompleteRatingEvidence)
        #expect(!partialStats.isQualifiedForShipping)
        #expect(partialStats.decisionHeadline.localizedCaseInsensitiveContains("missing"))
    }

    // MARK: - Small Issues 1, 2, 3

    @Test("Small Issue 1: Explicitly marked short standalone words (No., OK) validate without leakage")
    func explicitlyMarkedShortStandaloneWordsAndStageDirectionGuard() throws {
        let noScript = "How do you mark a stumble? A tiny Bluetooth remote? No. Instead, tap once."
        let noPassages = CoachingPassageExtractor.extractPassages(
            scriptText: noScript, exactPhrase: "No.", handoffCueText: nil, observations: []
        )
        #expect(noPassages.contains { $0.id == "passage.exact" && $0.phrase == "No." })

        let noRequest = PreparationCoachingRequest(
            sectionRevisionID: UUID(), talkRevisionID: UUID(), sectionTitle: "Marked Short Word",
            scriptText: noScript, exactPhrase: "No.", cueWords: ["remote", "No"], purpose: .reveal,
            handoffCueText: nil, isSpeakerChangeHandoff: false, knownSpeakerNames: ["Presenter"],
            selectedTechniqueID: nil,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .reveal, hasHandoff: false),
            promptVersion: SectionCoachService.preparationPromptVersion
        )
        let action = try #require(
            PreparationCoachingOptionSet.build(for: noRequest).actionOptions.first { $0.allowsScriptPassage }
        )
        let verdict = CoachingOutputValidator.validatePreparation(
            selection: RawModelPreparationSelection(
                shouldAbstain: false, abstentionReasonID: nil,
                techniqueID: action.techniqueID, passageID: "passage.exact", actionID: action.id
            ),
            request: noRequest
        )
        #expect(verdict.suggestion?.exactPhrase == "No.")

        let okPassages = CoachingPassageExtractor.extractPassages(
            scriptText: "OK. Let us walk through the live timeline.",
            exactPhrase: "OK", handoffCueText: nil, observations: []
        )
        #expect(okPassages.contains { $0.id == "passage.exact" && $0.phrase == "OK" })

        let partialNo = CoachingPassageExtractor.extractPassages(
            scriptText: "Notes on offline software.", exactPhrase: "No", handoffCueText: nil, observations: []
        )
        #expect(!partialNo.contains { $0.id == "passage.exact" })

        let partialOK = CoachingPassageExtractor.extractPassages(
            scriptText: "Look at this book right here.", exactPhrase: "ok", handoffCueText: nil, observations: []
        )
        #expect(!partialOK.contains { $0.id == "passage.exact" })

        let stageScript = "Tap Import. [No. Pause while file loads] There it is."
        #expect(!CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch("Pause while file loads", in: stageScript))
        let stageNo = CoachingPassageExtractor.extractPassages(
            scriptText: stageScript, exactPhrase: "No.", handoffCueText: nil, observations: []
        )
        #expect(!stageNo.contains { $0.id == "passage.exact" })
    }

    @Test("Small Issue 2: Cue Words UI clearly explains when an edited reminder needs reveal")
    func cueWordsUIExplainsEditedReminderNeedsReveal() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Cue Words Edited Check")
        seeded.section.text = "Marked headline phrase. Second line stays hidden."
        seeded.section.exactPhrase = "Marked headline phrase."

        let request = SectionCoachService.makePreparationRequest(
            section: seeded.section, talkRevisionID: seeded.talkRevision.id, handoff: nil
        )
        let coordinator = PreparationCoachCoordinator(
            coachService: SectionCoachService(modelProvider: StubCoachingModelProvider(availabilityState: .available)),
            coachingStore: coachingStore
        )
        coordinator.load(request: request)
        try coordinator.saveEditedAction("Pause cleanly before my custom reminder.")
        let editedCue = try #require(coordinator.currentCue)

        let policy = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .cueWords, isScriptRevealed: false,
            sectionExactPhrase: seeded.section.exactPhrase, handoffCueText: nil, cue: editedCue
        )
        #expect(policy.state == .concealEntireCue)
        #expect(policy.reason == .editedReminderInCueWords)
        #expect(!policy.allowsEditing)

        let idleView = PracticeCoachingConcealedCueView(isActiveTake: false, reason: policy.reason, onRevealScript: {})
        #expect(idleView.titleText.localizedCaseInsensitiveContains("edited"))
        #expect(idleView.titleText.localizedCaseInsensitiveContains("cue words"))
        #expect(idleView.explanationText.localizedCaseInsensitiveContains("reveal"))
        #expect(idleView.revealButtonTitle.localizedCaseInsensitiveContains("edited"))

        let activeView = PracticeCoachingConcealedCueView(isActiveTake: true, reason: policy.reason, onRevealScript: {})
        #expect(activeView.explanationText.localizedCaseInsensitiveContains("one reveal"))

        let editSheet = CoachingEditCueSheet(
            title: "Edit Pre-Practice Cue",
            originalAction: editedCue.action,
            initialText: editedCue.displayedAction,
            footerNotice: "In Cue Words mode, saving an edited reminder hides it until you reveal the script.",
            onSave: { _ in }
        )
        #expect(editSheet.footerNotice?.localizedCaseInsensitiveContains("reveal") == true)
        _ = PR3TestViewSnapshot.collectStrings(from: editSheet)
    }

    @Test("Small Issue 3: Cancelled suite before inference preserves fresh-launch tracking")
    func cancelledSuiteBeforeInferencePreservesFreshLaunchTracking() async throws {
        await CoachingEvaluationProcessState.shared.resetForTesting()
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let provider = StubCoachingModelProvider(availabilityState: .available)
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(modelProvider: provider),
            repeatTrialsPerCase: 2
        )
        let physicalEnv = CoachingDeviceEnvironment(
            osDescription: "iOS 27.0", deviceModel: "iPhone18,1", isSimulator: false
        )

        let cancelledPrep = Task {
            await runner.runSuite(
                task: .preparation, dataset: dataset, environment: physicalEnv,
                randomSeed: 1, isFreshProcessLaunch: nil
            )
        }
        cancelledPrep.cancel()
        _ = await cancelledPrep.value
        #expect(provider.preparationCallCount == 0)

        let cancelledPost = Task {
            await runner.runSuite(
                task: .postTake, dataset: dataset, environment: physicalEnv,
                randomSeed: 2, isFreshProcessLaunch: nil
            )
        }
        cancelledPost.cancel()
        _ = await cancelledPost.value
        #expect(provider.postTakeCallCount == 0)

        let firstReal = await runner.runSuite(
            task: .postTake, dataset: dataset, environment: physicalEnv,
            randomSeed: 3, isFreshProcessLaunch: nil
        )
        #expect(firstReal.coldLatencyStatus == .verifiedColdLaunch)
        #expect(firstReal.coldLatencyMilliseconds != nil)

        let secondReal = await runner.runSuite(
            task: .preparation, dataset: dataset, environment: physicalEnv,
            randomSeed: 4, isFreshProcessLaunch: nil
        )
        #expect(secondReal.coldLatencyStatus == .processAlreadyWarmed)
    }

    @Test("Small Issue 3: Persisted legacy ColdLatencyMeasurementStatus values decode with updated wording")
    func legacyColdLatencyStatusValuesDecodeCleanly() throws {
        let cases: [(String, ColdLatencyMeasurementStatus)] = [
            ("verifiedColdLaunch", .verifiedColdLaunch),
            ("processAlreadyWarmed", .processAlreadyWarmed),
            ("firstCallFailed", .firstCallFailed),
            ("modelUnavailable", .modelUnavailable),
            ("simulatorNotPhysical", .simulatorNotPhysical),
            ("unknownLegacy", .unknownLegacy)
        ]
        let decoder = JSONDecoder()
        for (raw, expected) in cases {
            let decoded = try decoder.decode(ColdLatencyMeasurementStatus.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded == expected)
        }
        #expect(ColdLatencyMeasurementStatus.verifiedColdLaunch.displayLabel.contains("First evaluation request"))
        #expect(ColdLatencyMeasurementStatus.processAlreadyWarmed.displayLabel.contains("already started"))
    }
}

private extension Task6PR3RepairRegressionTests {
    func makePostTakeSession(seed: UInt64) async throws -> CoachingEvaluationSession {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(modelProvider: StubCoachingModelProvider(availabilityState: .available)),
            repeatTrialsPerCase: 2
        )
        return await runner.runSuite(
            task: .postTake, dataset: dataset,
            environment: CoachingDeviceEnvironment(
                osDescription: "iOS 27.0", deviceModel: "iPhone18,1", isSimulator: false
            ),
            randomSeed: seed, isFreshProcessLaunch: true
        )
    }

    func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func stripPostTakeEvidence(
        from rawData: Data,
        schemaVersion: Int,
        promptVersion: String
    ) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        json["evaluationSchemaVersion"] = schemaVersion
        json["promptVersion"] = promptVersion
        if var entries = json["entries"] as? [[String: Any]] {
            for idx in entries.indices {
                for key in ["postTakeEvidence", "exactPhrase", "knownSpeakerNames",
                            "isSpeakerChangeHandoff", "isMultiSpeakerTalk"] {
                    entries[idx].removeValue(forKey: key)
                }
            }
            json["entries"] = entries
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    func stripFirstEntryPostTakeEvidence(from rawData: Data) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        if var entries = json["entries"] as? [[String: Any]], !entries.isEmpty {
            entries[0].removeValue(forKey: "postTakeEvidence")
            json["entries"] = entries
        }
        return try JSONSerialization.data(withJSONObject: json)
    }
}

@MainActor
enum PR3TestViewSnapshot {
    static func collectStrings<V: View>(from view: V) -> [String] {
        let host = UIHostingController(rootView: view)
        let window: UIWindow = (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            .map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        var collected: [String] = []
        var visited = Set<ObjectIdentifier>()
        visit(host.view, collected: &collected, visited: &visited)
        window.isHidden = true
        return collected
    }

    private static func visit(_ object: AnyObject, collected: inout [String], visited: inout Set<ObjectIdentifier>) {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return }
        if let nsObj = object as? NSObject {
            for text in [nsObj.accessibilityLabel, nsObj.accessibilityValue, nsObj.accessibilityHint].compactMap({ $0 })
                where !text.isEmpty {
                collected.append(text)
            }
            for child in childAccessibilityObjects(of: nsObj) {
                visit(child, collected: &collected, visited: &visited)
            }
        }
        if let view = object as? UIView {
            if let label = view as? UILabel, let text = label.text { collected.append(text) }
            for subview in view.subviews {
                visit(subview, collected: &collected, visited: &visited)
            }
        }
    }

    private static func childAccessibilityObjects(of nsObj: NSObject) -> [AnyObject] {
        if let elements = nsObj.accessibilityElements { return elements.map { $0 as AnyObject } }
        let count = nsObj.accessibilityElementCount()
        guard count != NSNotFound, count > 0 else { return [] }
        return (0..<count).compactMap { nsObj.accessibilityElement(at: $0) as AnyObject? }
    }
}
