import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 6 Preparation Coach Cache, Edit/Dismiss, and Coalescing Safeguards")
@MainActor
struct PreparationCoachCoordinatorTests {
    @Test("Preparation cache invalidates on section edit and persists user edits and dismissals")
    func preparationCacheInvalidatesOnEditAndPersistsEditDismiss() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T6PrepCache")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Coach Prep Talk")
        let originalScript = seeded.section.text
        let provider = StubCoachingModelProvider(availabilityState: .available)
        let coordinator = PreparationCoachCoordinator(
            coachService: SectionCoachService(modelProvider: provider),
            coachingStore: coachingStore
        )

        let requestV1 = SectionCoachService.makePreparationRequest(
            section: seeded.section,
            talkRevisionID: seeded.talkRevision.id,
            handoff: nil
        )
        coordinator.load(request: requestV1)
        #expect(coordinator.currentCue?.origin == .authoredBaseline)

        try coordinator.saveEditedAction("Pause for one full breath before the product name.")
        #expect(coordinator.currentCue?.isUserEdited == true)
        #expect(seeded.section.text == originalScript)

        try coordinator.dismissCurrentCue()
        let reloaded = PreparationCoachCoordinator(
            coachService: SectionCoachService(modelProvider: provider),
            coachingStore: coachingStore
        )
        reloaded.load(request: requestV1)
        #expect(reloaded.currentCue?.isDismissed == true)
        #expect(reloaded.currentCue?.displayedAction == "Pause for one full breath before the product name.")

        var draft = SectionDraft(record: seeded.section)
        draft.text = "Completely new section wording. Today we introduce HarborSync locally."
        draft.exactPhrase = "Today we introduce HarborSync locally."
        let editedRev = try library.saveSectionEdit(
            in: seeded.presentation,
            sectionID: seeded.section.sectionID,
            draft: draft
        )
        let updatedSection = try #require(
            library.orderedSections(in: editedRev).first { $0.sectionID == seeded.section.sectionID }
        )
        let requestV2 = SectionCoachService.makePreparationRequest(
            section: updatedSection,
            talkRevisionID: editedRev.id,
            handoff: nil
        )
        reloaded.load(request: requestV2)
        #expect(reloaded.currentCue?.sectionRevisionID == updatedSection.revisionID)
        #expect(reloaded.currentCue?.isDismissed == false)
        #expect(reloaded.currentCue?.isUserEdited == false)
        #expect(reloaded.currentCue?.exactPhrase == "Today we introduce HarborSync locally.")
    }

    @Test("Duplicate preparation requests coalesce and stale async responses are discarded")
    func duplicateRequestsCoalesceAndStaleResponsesDiscard() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T6StaleRace")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Race Talk")

        let gate = CoachingAsyncGate()
        let requestV1 = SectionCoachService.makePreparationRequest(
            section: seeded.section,
            talkRevisionID: seeded.talkRevision.id,
            handoff: nil
        )
        let provider = StubCoachingModelProvider(
            availabilityState: .available,
            preparationHandler: { req in
                await gate.wait()
                return StubCoachingModelProvider.defaultPreparationSelection(for: req)
            }
        )
        let coordinator = PreparationCoachCoordinator(
            coachService: SectionCoachService(modelProvider: provider),
            coachingStore: coachingStore
        )

        coordinator.load(request: requestV1)
        coordinator.requestOnDeviceSuggestion()
        coordinator.requestOnDeviceSuggestion()
        #expect(coordinator.isGenerating)

        var draft = SectionDraft(record: seeded.section)
        draft.text = "Fresh revision text. Welcome to VeloNotes offline."
        draft.exactPhrase = "Welcome to VeloNotes offline."
        let editedRev = try library.saveSectionEdit(
            in: seeded.presentation,
            sectionID: seeded.section.sectionID,
            draft: draft
        )
        let updatedSection = try #require(
            library.orderedSections(in: editedRev).first { $0.sectionID == seeded.section.sectionID }
        )
        coordinator.load(
            request: SectionCoachService.makePreparationRequest(
                section: updatedSection,
                talkRevisionID: editedRev.id,
                handoff: nil
            )
        )
        await gate.releaseAll()
        await coordinator.waitForActiveGeneration()

        #expect(provider.preparationCallCount == 1)
        #expect(coordinator.currentCue?.sectionRevisionID == updatedSection.revisionID)
        #expect(coordinator.currentCue?.origin == .authoredBaseline)
    }
}

@Suite("Task 6 Post-Take Coach Cache, Coalescing, and Deletion Safeguards")
@MainActor
struct CoachCoordinatorTests {

    @Test("Post-take cache invalidates on reanalysis or marker change and preserves immutable evidence")
    func postTakeCacheInvalidatesOnEvidenceChangeAndPreservesEvidence() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)

        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Review Cache Talk")
        let attempt = try seedSilentAttempt(in: attemptStore, seeded: seeded, duration: 12.0, reveals: 2)
        let originalScript = seeded.section.text

        let coordinator = PostTakeCoachCoordinator(coachingStore: coachingStore)
        let reqV1 = SectionCoachService.makePostTakeRequest(
            attempt: attempt,
            section: seeded.section,
            handoff: nil,
            knownSpeakerNames: ["Alex", "Jordan"],
            timingAnalysis: nil
        )
        coordinator.load(request: reqV1)
        try coordinator.saveEditedAction("User custom post-take note for v1.")

        let newAnalysis = makeCompletedAnalysis(for: attempt, seeded: seeded)
        let reqV2 = SectionCoachService.makePostTakeRequest(
            attempt: attempt,
            section: seeded.section,
            handoff: nil,
            knownSpeakerNames: ["Alex", "Jordan"],
            timingAnalysis: newAnalysis
        )
        #expect(reqV1.evidenceVersion != reqV2.evidenceVersion)
        coordinator.load(request: reqV2)
        #expect(coordinator.currentCue?.displayedAction != "User custom post-take note for v1.")

        _ = try attemptStore.addManualMarker(toAttemptID: attempt.id, timestamp: 4.5, label: "Check pacing")
        let refreshedAttempt = try #require(try attemptStore.attempt(withID: attempt.id))
        let reqV3 = SectionCoachService.makePostTakeRequest(
            attempt: refreshedAttempt,
            section: seeded.section,
            handoff: nil,
            knownSpeakerNames: ["Alex", "Jordan"],
            timingAnalysis: newAnalysis
        )
        #expect(reqV2.evidenceVersion != reqV3.evidenceVersion)
        #expect(seeded.section.text == originalScript)
        #expect(refreshedAttempt.elapsedDuration == 12.0)
        #expect(refreshedAttempt.revealCount == 2)
    }

    @Test("Post-take coordinator coalesces duplicates, discards stale response on deletion, and restores on failure")
    func postTakeCoalescingDeletionDiscardAndRecovery() async throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)

        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Deletion Race Talk")
        let attempt = try seedSilentAttempt(in: attemptStore, seeded: seeded, duration: 9.0, reveals: 0)

        let gate = CoachingAsyncGate()
        let provider = StubCoachingModelProvider(
            availabilityState: .available,
            postTakeHandler: { req in
                await gate.wait()
                return StubCoachingModelProvider.defaultPostTakeSelection(for: req)
            }
        )
        let coordinator = PostTakeCoachCoordinator(
            coachService: SectionCoachService(modelProvider: provider),
            coachingStore: coachingStore
        )
        let request = SectionCoachService.makePostTakeRequest(
            attempt: attempt,
            section: seeded.section,
            handoff: nil,
            knownSpeakerNames: [],
            timingAnalysis: nil
        )
        coordinator.load(request: request)
        let originalAction = coordinator.currentCue?.displayedAction

        let recoveryToken = coordinator.prepareForDeletion(attemptID: attempt.id)
        #expect(coordinator.currentCue == nil)
        coordinator.restoreAfterFailedDeletion(recoveryToken)
        #expect(coordinator.currentCue?.displayedAction == originalAction)

        coordinator.requestOnDeviceSuggestion(attemptStore: attemptStore)
        coordinator.requestOnDeviceSuggestion(attemptStore: attemptStore)
        #expect(coordinator.isGenerating)

        try TakeReview.performDeletion(
            attempt: attempt,
            attemptStore: attemptStore,
            player: TakeAudioPlayer(),
            coachCoordinator: coordinator
        )
        await gate.releaseAll()
        await coordinator.waitForActiveGeneration()

        #expect(provider.postTakeCallCount == 1)
        #expect(coordinator.currentCue == nil)
        #expect(try coachingStore.fetchCachedPostTakeCue(for: request) == nil)
    }

    @Test("Deleting attempt or presentation removes associated CoachingCueRecord entries")
    func deletingAttemptAndPresentationCleansUpCoachingRecords() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)

        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Cleanup Talk")
        let attempt = try seedSilentAttempt(in: attemptStore, seeded: seeded, duration: 8.0, reveals: 1)

        let prepReq = SectionCoachService.makePreparationRequest(
            section: seeded.section,
            talkRevisionID: seeded.talkRevision.id,
            handoff: nil
        )
        try coachingStore.savePreparationCue(
            TechniqueLibrary.authoredPreparationSuggestion(for: prepReq),
            for: prepReq
        )

        let postReq = SectionCoachService.makePostTakeRequest(
            attempt: attempt,
            section: seeded.section,
            handoff: nil,
            knownSpeakerNames: [],
            timingAnalysis: nil
        )
        try coachingStore.savePostTakeCue(
            TechniqueLibrary.authoredPostTakeSuggestion(for: postReq),
            for: postReq
        )

        try attemptStore.deleteAttempt(attempt)
        #expect(try coachingStore.fetchCachedPostTakeCue(for: postReq) == nil)
        #expect(try coachingStore.fetchCachedPreparationCue(for: prepReq) != nil)

        try attemptStore.deletePresentationAndAttempts(seeded.presentation)
        #expect(try coachingStore.fetchCachedPreparationCue(for: prepReq) == nil)
    }
}

private extension CoachCoordinatorTests {
    func seedSilentAttempt(
        in attemptStore: AttemptStore,
        seeded: SeededSectionFixture,
        duration: TimeInterval,
        reveals: Int
    ) throws -> AttemptRecord {
        let pending = try attemptStore.beginAttempt(
            snapshot: seeded.snapshot,
            practiceMode: .cueWords,
            isSilentRecall: true
        )
        return try attemptStore.finalizeAttempt(
            AttemptFinalizationInput(
                id: pending.id,
                snapshot: seeded.snapshot,
                practiceMode: .cueWords,
                startedAt: pending.startedAt,
                relativeAudioPath: nil,
                elapsedDuration: duration,
                revealCount: reveals,
                markers: [],
                isSilentRecall: true,
                interrupted: false,
                interruptionReason: nil
            )
        )
    }

    func makeCompletedAnalysis(
        for attempt: AttemptRecord,
        seeded: SeededSectionFixture
    ) -> TimingAnalysisResult {
        TimingAnalysisResult(
            attemptID: attempt.id,
            talkRevisionID: seeded.talkRevision.id,
            sectionRevisionID: seeded.section.revisionID,
            localeIdentifier: "en_US",
            outcome: .completed,
            elapsedAudioDuration: 12.0,
            recognizedWordCount: 16,
            timingGranularity: .wordLevel,
            estimatedWordsPerMinute: 112.0,
            observations: [],
            ambiguousNotes: [],
            finalizedSegmentCount: 16,
            hasOverlappingSegments: false,
            hasUntimedFinalText: false
        )
    }
}
