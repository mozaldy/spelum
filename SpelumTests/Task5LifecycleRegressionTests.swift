import Foundation
import os
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 5 Review Regressions — Progress Phase Guards and Deletion Recovery")
@MainActor
struct Task5LifecycleRegressionTests {
    // MARK: - Finding (4): Run AND phase guards on installAssets progress callbacks

    @Test("Finding 4: late installAssets(1.0) progress never reverts analyzing or completed phases")
    func lateInstallProgressNeverRevertsAnalyzingOrCompletedPhase() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5LateProgress")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 5.0)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        let capturedProgress = OSAllocatedUnfairLock<(@Sendable (Double?) -> Void)?>(initialState: nil)
        let gate = TranscriptionGate()
        let transcriber = ControlledTakeTranscriber(
            availability: .assetsNotInstalled(localeIdentifier: "en_US"),
            installBehavior: { onProgress in
                capturedProgress.withLock { $0 = onProgress }
                onProgress(0.5)
                onProgress(1.0)
            },
            transcribeBehavior: { _, _ in
                try await gate.waitForOutput()
            }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        coordinator.installAssetsAndAnalyze(
            localeIdentifier: "en_US",
            context: context,
            attemptStore: take.attemptStore
        )

        await gate.waitUntilStarted()
        await drainMainActorQueue()
        #expect(coordinator.phase == .analyzing(localeIdentifier: "en_US", previousResult: nil))

        let progressCallback = try #require(capturedProgress.withLock { $0 })
        progressCallback(1.0)
        progressCallback(0.75)
        await drainMainActorQueue()
        #expect(coordinator.phase == .analyzing(localeIdentifier: "en_US", previousResult: nil))

        await gate.resumeNext(with: .success(
            SpeechTranscriptionOutput(
                localeIdentifier: "en_US",
                segments: Task5TestHelpers.fiveWordSampleSegments(),
                hasUntimedFinalText: false
            )
        ))
        await coordinator.waitForActiveTask()

        guard case .completed(let result) = coordinator.phase else {
            Issue.record("Expected .completed after transcription finished, got \(coordinator.phase)")
            return
        }
        #expect(result.recognizedWordCount == 5)

        progressCallback(1.0)
        await drainMainActorQueue()
        #expect(coordinator.phase == .completed(result))
    }

    @Test("Finding 4: in-phase install progress updates normally and sanitizes non-finite fractions")
    func inPhaseInstallProgressUpdatesAndSanitizesNonFiniteValues() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5InPhaseProgress")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 5.0)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        let installGate = SimpleAsyncGate()
        let capturedProgress = OSAllocatedUnfairLock<(@Sendable (Double?) -> Void)?>(initialState: nil)
        let transcriber = ControlledTakeTranscriber(
            availability: .assetsNotInstalled(localeIdentifier: "en_US"),
            installBehavior: { onProgress in
                capturedProgress.withLock { $0 = onProgress }
                await installGate.wait()
                onProgress(1.0)
            },
            transcribeBehavior: { _, locale in
                SpeechTranscriptionOutput(
                    localeIdentifier: locale,
                    segments: Task5TestHelpers.fiveWordSampleSegments(),
                    hasUntimedFinalText: false
                )
            }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        coordinator.installAssetsAndAnalyze(
            localeIdentifier: "en_US",
            context: context,
            attemptStore: take.attemptStore
        )

        await installGate.waitUntilWaiting()
        let progressCallback = try #require(capturedProgress.withLock { $0 })

        progressCallback(0.45)
        await drainMainActorQueue()
        #expect(coordinator.phase == .installingAssets(localeIdentifier: "en_US", fractionCompleted: 0.45))

        progressCallback(.nan)
        await drainMainActorQueue()
        #expect(coordinator.phase == .installingAssets(localeIdentifier: "en_US", fractionCompleted: nil))

        progressCallback(1.5)
        await drainMainActorQueue()
        #expect(coordinator.phase == .installingAssets(localeIdentifier: "en_US", fractionCompleted: 1.0))

        await installGate.release()
        await coordinator.waitForActiveTask()
        guard case .completed = coordinator.phase else {
            Issue.record("Expected .completed after install and analysis, got \(coordinator.phase)")
            return
        }
    }

    // MARK: - Finding (5): Failed deletion recovery and successful deletion race safety

    @Test("Finding 5: failed deletion on completed take preserves observations, playback, and reanalyze")
    func failedDeletionOnCompletedTakePreservesObservationsPlaybackAndRetry() async throws {
        let fixture = try makeControlledDeletionTake(prefix: "T5DeleteFailCompleted", duration: 4.0)
        defer { fixture.workspace.cleanup() }

        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, locale in
                SpeechTranscriptionOutput(
                    localeIdentifier: locale,
                    segments: Task5TestHelpers.fiveWordSampleSegments(),
                    hasUntimedFinalText: false
                )
            }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: fixture.audioURL)
        defer { player.stop() }

        coordinator.loadOrAnalyzeIfReady(context: fixture.context, attemptStore: fixture.store)
        await coordinator.waitForActiveTask()
        guard case .completed(let initialResult) = coordinator.phase else {
            Issue.record("Expected initial .completed phase, got \(coordinator.phase)")
            return
        }
        let exactObservation = try #require(initialResult.observations.first { $0.kind == .alignedExactPhrase })

        fixture.setShouldFailSave(true)
        #expect(throws: Error.self) {
            try TakeReview.performDeletion(
                attempt: fixture.attempt,
                attemptStore: fixture.store,
                player: player,
                analysisCoordinator: coordinator
            )
        }

        #expect(coordinator.phase == .completed(initialResult))
        #expect(player.isLoaded)
        let seekTarget = exactObservation.seekTarget(maxDuration: player.duration)
        player.seek(to: seekTarget, autoPlay: true)
        #expect(player.isPlaying)

        fixture.setShouldFailSave(false)
        coordinator.reanalyze(context: fixture.context, attemptStore: fixture.store)
        await coordinator.waitForActiveTask()
        guard case .completed(let reanalyzed) = coordinator.phase else {
            Issue.record("Expected .completed after retry, got \(coordinator.phase)")
            return
        }
        #expect(reanalyzed.analysisVersion == 2)
    }

    @Test("Finding 5: failed deletion during in-flight analysis cancels work and keeps card recoverable")
    func failedDeletionDuringInFlightAnalysisRestoresRecoverableStateAndAllowsRetry() async throws {
        let fixture = try makeControlledDeletionTake(prefix: "T5DeleteFailInFlight", duration: 4.0)
        defer { fixture.workspace.cleanup() }

        let gate = TranscriptionGate()
        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, _ in try await gate.waitForOutput() }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: fixture.audioURL)
        defer { player.stop() }

        coordinator.loadOrAnalyzeIfReady(context: fixture.context, attemptStore: fixture.store)
        await gate.waitUntilStarted()
        #expect(coordinator.phase == .analyzing(localeIdentifier: "en_US", previousResult: nil))

        fixture.setShouldFailSave(true)
        #expect(throws: Error.self) {
            try TakeReview.performDeletion(
                attempt: fixture.attempt,
                attemptStore: fixture.store,
                player: player,
                analysisCoordinator: coordinator
            )
        }

        #expect(coordinator.phase == .cancelled(previousResult: nil))
        #expect(player.isLoaded)

        await gate.resumeNext(with: .success(
            SpeechTranscriptionOutput(
                localeIdentifier: "en_US",
                segments: [TimedTranscriptSegment(text: "Stale", startTime: 0.2, endTime: 0.5)],
                hasUntimedFinalText: false
            )
        ))
        await drainMainActorQueue()
        #expect(coordinator.phase == .cancelled(previousResult: nil))
        #expect(try fixture.store.attempt(withID: fixture.attempt.id)?.timingAnalysis == nil)

        fixture.setShouldFailSave(false)
        await transcriber.setTranscribeBehavior { _, locale in
            SpeechTranscriptionOutput(
                localeIdentifier: locale,
                segments: Task5TestHelpers.fiveWordSampleSegments(),
                hasUntimedFinalText: false
            )
        }
        coordinator.reanalyze(context: fixture.context, attemptStore: fixture.store)
        await coordinator.waitForActiveTask()
        guard case .completed(let recovered) = coordinator.phase else {
            Issue.record("Expected .completed after retry, got \(coordinator.phase)")
            return
        }
        #expect(recovered.recognizedWordCount == 5)

        try await verifyFailedDeletionDuringReanalysisPreservesPriorResult(
            fixture: fixture,
            transcriber: transcriber,
            coordinator: coordinator,
            player: player,
            gate: gate
        )
    }

    @Test("Finding 5: successful deletion during in-flight analysis stays idle and blocks late resurrection")
    func successfulDeletionDuringInFlightAnalysisStaysIdleAndBlocksResurrection() async throws {
        let fixture = try makeControlledDeletionTake(prefix: "T5DeleteSuccessRace", duration: 4.0)
        defer { fixture.workspace.cleanup() }

        let gate = TranscriptionGate()
        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, _ in try await gate.waitForOutput() }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: fixture.audioURL)

        coordinator.loadOrAnalyzeIfReady(context: fixture.context, attemptStore: fixture.store)
        await gate.waitUntilStarted()

        try TakeReview.performDeletion(
            attempt: fixture.attempt,
            attemptStore: fixture.store,
            player: player,
            analysisCoordinator: coordinator
        )
        #expect(coordinator.phase == .idle)
        #expect(!player.isLoaded)
        #expect(try fixture.store.attempt(withID: fixture.attempt.id) == nil)

        await gate.resumeNext(with: .success(
            SpeechTranscriptionOutput(
                localeIdentifier: "en_US",
                segments: Task5TestHelpers.fiveWordSampleSegments(),
                hasUntimedFinalText: false
            )
        ))
        await coordinator.waitForActiveTask()
        await drainMainActorQueue()

        #expect(coordinator.phase == .idle)
        #expect(try fixture.store.attempt(withID: fixture.attempt.id) == nil)
    }
}

private extension Task5LifecycleRegressionTests {
    struct ControlledDeletionFixture {
        let workspace: PracticeTestWorkspace
        let container: ModelContainer
        let store: AttemptStore
        let attempt: AttemptRecord
        let audioURL: URL
        let context: TakeAnalysisRequestContext
        let setShouldFailSave: (Bool) -> Void
    }

    func makeControlledDeletionTake(
        prefix: String,
        duration: Double
    ) throws -> ControlledDeletionFixture {
        let workspace = try PracticeTestWorkspace.create(prefix: prefix)
        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let failFlag = OSAllocatedUnfairLock(initialState: false)
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if failFlag.withLock({ $0 }) {
                    throw NSError(domain: "SimulatedDeleteFailure", code: 503)
                }
                try context.save()
            }
        )
        let saved = try PracticeTestFixtures.saveSyntheticTake(
            in: store,
            snapshot: seeded.snapshot,
            mode: .cueWords,
            durationSeconds: duration
        )
        let context = Task5TestHelpers.makeContext(
            attempt: saved.attempt,
            audioURL: saved.audioURL,
            section: seeded.section
        )
        return ControlledDeletionFixture(
            workspace: workspace,
            container: container,
            store: store,
            attempt: saved.attempt,
            audioURL: saved.audioURL,
            context: context,
            setShouldFailSave: { shouldFail in failFlag.withLock { $0 = shouldFail } }
        )
    }

    func verifyFailedDeletionDuringReanalysisPreservesPriorResult(
        fixture: ControlledDeletionFixture,
        transcriber: ControlledTakeTranscriber,
        coordinator: TakeAnalysisCoordinator,
        player: TakeAudioPlayer,
        gate: TranscriptionGate
    ) async throws {
        let priorResult = try #require(coordinator.phase.displayedResult)
        await transcriber.setTranscribeBehavior { _, _ in try await gate.waitForOutput() }
        coordinator.reanalyze(context: fixture.context, attemptStore: fixture.store)
        await gate.waitUntilStarted(count: 2)
        fixture.setShouldFailSave(true)
        #expect(throws: Error.self) {
            try TakeReview.performDeletion(
                attempt: fixture.attempt,
                attemptStore: fixture.store,
                player: player,
                analysisCoordinator: coordinator
            )
        }
        #expect(coordinator.phase == .cancelled(previousResult: priorResult))
        #expect(coordinator.phase.displayedResult == priorResult)
        await gate.cancelAll()
    }

    func drainMainActorQueue() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}
