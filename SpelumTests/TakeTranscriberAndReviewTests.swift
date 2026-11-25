import CoreMedia
import Foundation
import Speech
import Testing
@testable import Spelum

@Suite("Take Transcriber States and Offline UX")
@MainActor
struct TakeTranscriberAndReviewTests {
    @Test("SpeechResultSegmentExtractor extracts finalized CMTimeRange runs and flags untimed words honestly")
    func attributedStringExtractorHandlesFinalVolatileUntimedAndMultiWordRuns() {
        var attributed = AttributedString("Today ")
        if let todayRange = attributed.range(of: "Today") {
            attributed[todayRange].audioTimeRange = CMTimeRange(
                start: CMTime(seconds: 0.5, preferredTimescale: 600),
                end: CMTime(seconds: 1.0, preferredTimescale: 600)
            )
            attributed[todayRange].transcriptionConfidence = 0.96
        }

        var phraseRun = AttributedString("we unveil")
        phraseRun.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 1.1, preferredTimescale: 600),
            end: CMTime(seconds: 1.9, preferredTimescale: 600)
        )
        attributed.append(phraseRun)
        attributed.append(AttributedString(" — "))

        let finalExtraction = SpeechResultSegmentExtractor.extract(
            from: attributed,
            isFinal: true,
            localeIdentifier: "en_US"
        )
        #expect(!finalExtraction.hasUntimedFinalText)
        #expect(finalExtraction.segments.count == 2)
        #expect(finalExtraction.segments[0].text == "Today")
        #expect(abs(finalExtraction.segments[0].startTime - 0.5) < 0.001)
        #expect(finalExtraction.segments[1].text == "we unveil")
        #expect(abs(finalExtraction.segments[1].endTime - 1.9) < 0.001)

        let volatileExtraction = SpeechResultSegmentExtractor.extract(
            from: attributed,
            isFinal: false,
            localeIdentifier: "en_US"
        )
        #expect(volatileExtraction.segments.isEmpty)
        #expect(!volatileExtraction.hasUntimedFinalText)

        var untimed = attributed
        untimed.append(AttributedString("Lumera"))
        let untimedExtraction = SpeechResultSegmentExtractor.extract(
            from: untimed,
            isFinal: true,
            localeIdentifier: "en_US"
        )
        #expect(untimedExtraction.hasUntimedFinalText)
        #expect(untimedExtraction.segments.count == 2)

        let coarseResult = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 3.0,
                scriptText: "Today we unveil Lumera.",
                exactPhrase: "unveil",
                segments: finalExtraction.segments,
                localeIdentifier: "en_US"
            )
        )
        #expect(coarseResult.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
        #expect(coarseResult.ambiguousNotes.contains { $0.reason == .incompleteTimingCoverage })
    }

    @Test("Offline missing assets state preserves playback, does not auto-download, and recovers on retry")
    func offlineMissingAssetsStateAndRecoverableInstall() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5OfflineAssets")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 4.0)

        let transcriber = ControlledTakeTranscriber(
            availability: .assetsNotInstalled(localeIdentifier: "en_US"),
            installBehavior: { _ in
                throw TakeTranscriptionError.assetDownloadFailed(
                    "Offline: could not download English speech assets."
                )
            }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        coordinator.loadOrAnalyzeIfReady(context: context, attemptStore: take.attemptStore)
        await coordinator.waitForActiveTask()
        #expect(coordinator.phase == .assetsNotInstalled(localeIdentifier: "en_US"))
        #expect(await transcriber.installCallCount == 0)

        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: take.audioURL)
        #expect(player.isLoaded)
        player.stop()

        coordinator.installAssetsAndAnalyze(
            localeIdentifier: "en_US",
            context: context,
            attemptStore: take.attemptStore
        )
        await coordinator.waitForActiveTask()
        if case .failed(let message, let canRetry, _) = coordinator.phase {
            #expect(message.localizedCaseInsensitiveContains("offline"))
            #expect(canRetry)
        } else {
            Issue.record("Expected recoverable failure state when offline install fails.")
        }

        await verifyRecoveryAfterAssetInstall(
            transcriber: transcriber,
            coordinator: coordinator,
            context: context,
            attemptStore: take.attemptStore
        )
    }

    @Test("Honest unsupported, permission-denied, and silent-take states preserve takes")
    func honestUnavailableStatesPreserveTakes() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5UnavailableStates")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 3.0)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        let cases: [(SpeechAvailabilityState, TakeAnalysisPhase)] = [
            (
                .unsupportedDevice(reason: "No neural engine"),
                .unavailable(kind: .unsupportedDevice, reason: "No neural engine")
            ),
            (
                .unsupportedLocale(reason: "No English model"),
                .unavailable(kind: .unsupportedLocale, reason: "No English model")
            ),
            (
                .permissionDenied(reason: "Speech denied"),
                .unavailable(kind: .permissionDenied, reason: "Speech denied")
            )
        ]

        for (availability, expectedPhase) in cases {
            let coordinator = TakeAnalysisCoordinator(
                transcriber: ControlledTakeTranscriber(availability: availability)
            )
            coordinator.loadOrAnalyzeIfReady(context: context, attemptStore: take.attemptStore)
            await coordinator.waitForActiveTask()
            #expect(coordinator.phase == expectedPhase)
        }

        let silentContext = TakeAnalysisRequestContext(
            attemptID: UUID(),
            talkRevisionID: take.seeded.talkRevision.id,
            sectionRevisionID: take.seeded.section.revisionID,
            relativeAudioPath: nil,
            audioURL: nil,
            elapsedAudioDuration: 5.0,
            hasPlayableAudio: false,
            isSilentRecall: true,
            scriptText: take.seeded.section.text,
            exactPhrase: take.seeded.section.exactPhrase,
            cueWords: take.seeded.section.cueWords,
            hasMultipleSpeakersOrHandoff: false
        )
        let silentCoord = TakeAnalysisCoordinator(transcriber: ControlledTakeTranscriber())
        silentCoord.loadOrAnalyzeIfReady(context: silentContext, attemptStore: take.attemptStore)
        if case .unavailable(let kind, _) = silentCoord.phase {
            #expect(kind == .noAudio)
        } else {
            Issue.record("Expected noAudio unavailable state for silent recall take.")
        }
    }

    @Test("In-flight analysis can be cancelled and declined without affecting saved audio")
    func cancellableAndDeclinedStatesPreserveAudio() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5CancelDecline")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 3.0)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        let gate = TranscriptionGate()
        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, _ in try await gate.waitForOutput() }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        coordinator.loadOrAnalyzeIfReady(context: context, attemptStore: take.attemptStore)
        await gate.waitUntilStarted()
        coordinator.cancelActiveOperation()
        await coordinator.waitForActiveTask()
        #expect(coordinator.phase == .cancelled(previousResult: nil))

        coordinator.decline(context: context, attemptStore: take.attemptStore)
        #expect(coordinator.phase == .declined)
        let persisted = try #require(try take.attemptStore.attempt(withID: take.attempt.id))
        #expect(persisted.timingAnalysis?.outcome == .declined)
        #expect(persisted.hasPlayableAudio)
    }

    @Test("Disappearing while analyzing resets busy state and system asset download stays recoverable")
    func disappearResetsBusyStateAndSystemDownloadIsRecoverable() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5DisappearRecover")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 3.0)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        let gate = TranscriptionGate()
        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, _ in try await gate.waitForOutput() }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        coordinator.loadOrAnalyzeIfReady(context: context, attemptStore: take.attemptStore)
        await gate.waitUntilStarted()

        coordinator.handleViewDisappear()
        #expect(!coordinator.phase.isBusy)

        await transcriber.setAvailability(.downloadingAssets(localeIdentifier: "en_US", fractionCompleted: 0.4))
        coordinator.loadOrAnalyzeIfReady(context: context, attemptStore: take.attemptStore)
        await coordinator.waitForActiveTask()
        if case .failed(let message, let canRetry, _) = coordinator.phase {
            #expect(message.localizedCaseInsensitiveContains("downloading"))
            #expect(canRetry)
        } else {
            Issue.record("Expected recoverable status when iOS reports system asset download in progress.")
        }
    }
}

private extension TakeTranscriberAndReviewTests {
    func verifyRecoveryAfterAssetInstall(
        transcriber: ControlledTakeTranscriber,
        coordinator: TakeAnalysisCoordinator,
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore
    ) async {
        await transcriber.setInstallBehavior { progress in
            progress(0.5)
            progress(1.0)
        }
        await transcriber.setTranscribeBehavior { _, locale in
            SpeechTranscriptionOutput(
                localeIdentifier: locale,
                segments: Task5TestHelpers.fiveWordSampleSegments(),
                hasUntimedFinalText: false
            )
        }
        coordinator.installAssetsAndAnalyze(
            localeIdentifier: "en_US",
            context: context,
            attemptStore: attemptStore
        )
        await coordinator.waitForActiveTask()

        if case .completed(let result) = coordinator.phase {
            #expect(result.recognizedWordCount == 5)
            #expect(result.observations.contains { $0.kind == .alignedExactPhrase })
        } else {
            Issue.record("Expected completed analysis after successful asset install.")
        }

        let reopenTranscriber = ControlledTakeTranscriber(
            availability: .unsupportedDevice(reason: "Should not be queried when persisted result exists")
        )
        let reopenCoordinator = TakeAnalysisCoordinator(transcriber: reopenTranscriber)
        reopenCoordinator.loadOrAnalyzeIfReady(context: context, attemptStore: attemptStore)
        await reopenCoordinator.waitForActiveTask()
        #expect(await reopenTranscriber.availabilityCallCount == 0)
        if case .completed(let loaded) = reopenCoordinator.phase {
            #expect(loaded.recognizedWordCount == 5)
        } else {
            Issue.record("Expected persisted analysis to load offline immediately.")
        }
    }
}
