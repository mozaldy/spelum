import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Take Analysis Race Safety, Reanalysis, and Review UI")
@MainActor
struct TakeAnalysisRaceAndUITests {
    @Test("Reanalysis replaces earlier result in place without duplicating recordings or altering prior revisions")
    func reanalysisReplacesInPlaceAndPreservesRevisions() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5Reanalyze")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 5.0)
        let library = PresentationStore(modelContext: take.container.mainContext)
        let baseline = ReanalysisBaseline(
            audioPath: take.attempt.relativeAudioPath,
            talkRevisionID: take.attempt.talkRevisionID,
            sectionRevisionID: take.attempt.sectionRevisionID
        )

        try editSectionToRevisionTwo(in: library, seeded: take.seeded)

        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, locale in
                SpeechTranscriptionOutput(
                    localeIdentifier: locale,
                    segments: [
                        TimedTranscriptSegment(text: "Today", startTime: 0.4, endTime: 0.8),
                        TimedTranscriptSegment(text: "we", startTime: 0.9, endTime: 1.1)
                    ],
                    hasUntimedFinalText: false
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
        let firstPersisted = try #require(try take.attemptStore.attempt(withID: take.attempt.id)?.timingAnalysis)
        #expect(firstPersisted.analysisVersion == 1)
        #expect(firstPersisted.recognizedWordCount == 2)

        await transcriber.setTranscribeBehavior { _, locale in
            SpeechTranscriptionOutput(
                localeIdentifier: locale,
                segments: Task5TestHelpers.fiveWordSampleSegments(),
                hasUntimedFinalText: false
            )
        }
        coordinator.reanalyze(context: context, attemptStore: take.attemptStore)
        await coordinator.waitForActiveTask()

        try verifyReanalyzedTake(
            take: take,
            library: library,
            firstPersisted: firstPersisted,
            baseline: baseline
        )
    }

    @Test("Late completion after deletion never resurrects takes")
    func lateCompletionAfterDeletionNeverResurrectsTake() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5DeleteRace")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 4.0)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        let deleteGate = TranscriptionGate()
        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, _ in try await deleteGate.waitForOutput() }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        coordinator.loadOrAnalyzeIfReady(context: context, attemptStore: take.attemptStore)
        await deleteGate.waitUntilStarted()

        coordinator.invalidateForDeletion()
        try take.attemptStore.deleteAttempt(take.attempt)

        await deleteGate.resumeNext(with: .success(
            SpeechTranscriptionOutput(
                localeIdentifier: "en_US",
                segments: [TimedTranscriptSegment(text: "Late", startTime: 0.2, endTime: 0.6)],
                hasUntimedFinalText: false
            )
        ))
        await coordinator.waitForActiveTask()
        #expect(try take.attemptStore.attempt(withID: take.attempt.id) == nil)
        let remaining = try take.attemptStore.fetchAttempts(
            forPresentationID: take.seeded.presentation.id,
            includeInProgress: true
        )
        #expect(remaining.isEmpty)

        let orphanAnalysis = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: take.attempt.id,
                talkRevisionID: take.seeded.talkRevision.id,
                sectionRevisionID: take.seeded.section.revisionID,
                elapsedAudioDuration: 4.0,
                scriptText: take.seeded.section.text,
                segments: [TimedTranscriptSegment(text: "Ghost", startTime: 0.2, endTime: 0.6)]
            )
        )
        let savedDeleted = try take.attemptStore.saveTimingAnalysis(
            orphanAnalysis,
            forAttemptID: take.attempt.id,
            expectedRelativeAudioPath: take.attempt.relativeAudioPath,
            expectedTalkRevisionID: take.seeded.talkRevision.id,
            expectedSectionRevisionID: take.seeded.section.revisionID
        )
        #expect(!savedDeleted)
        #expect(try take.attemptStore.attempt(withID: take.attempt.id) == nil)
    }

    @Test("Superseded earlier retry finishing late never overwrites newer result")
    func supersededRetryNeverOverwritesNewerResult() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5SupersededRetry")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 4.0)
        let context = Task5TestHelpers.makeContext(
            attempt: take.attempt,
            audioURL: take.audioURL,
            section: take.seeded.section
        )

        let raceGate = TranscriptionGate()
        let transcriber = ControlledTakeTranscriber(
            availability: .ready(localeIdentifier: "en_US"),
            transcribeBehavior: { _, _ in try await raceGate.waitForOutput() }
        )
        let coordinator = TakeAnalysisCoordinator(transcriber: transcriber)
        coordinator.loadOrAnalyzeIfReady(context: context, attemptStore: take.attemptStore)
        await raceGate.waitUntilStarted(count: 1)

        await transcriber.setTranscribeBehavior { _, locale in
            SpeechTranscriptionOutput(
                localeIdentifier: locale,
                segments: [
                    TimedTranscriptSegment(text: "Fresh", startTime: 0.4, endTime: 0.8),
                    TimedTranscriptSegment(text: "retry", startTime: 0.9, endTime: 1.3),
                    TimedTranscriptSegment(text: "result", startTime: 1.4, endTime: 1.9)
                ],
                hasUntimedFinalText: false
            )
        }
        coordinator.reanalyze(context: context, attemptStore: take.attemptStore)
        await coordinator.waitForActiveTask()

        await raceGate.resumeNext(with: .success(
            SpeechTranscriptionOutput(
                localeIdentifier: "en_US",
                segments: [TimedTranscriptSegment(text: "Stale", startTime: 0.1, endTime: 0.4)],
                hasUntimedFinalText: false
            )
        ))
        let persisted = try #require(try take.attemptStore.attempt(withID: take.attempt.id)?.timingAnalysis)
        #expect(persisted.recognizedWordCount == 3)
    }

    @Test("Manual marker added for ambiguous alignment persists sorted and refuses deleted takes")
    func manualMarkerPersistsAndRefusesDeletedTake() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5ManualMarker")
        defer { workspace.cleanup() }
        let take = try Task5TestHelpers.seedAudioTake(in: workspace, duration: 6.0)

        let second = try take.attemptStore.addManualMarker(
            toAttemptID: take.attempt.id,
            timestamp: 3.4,
            label: "Check repeated Lumera"
        )
        let first = try take.attemptStore.addManualMarker(
            toAttemptID: take.attempt.id,
            timestamp: 1.2,
            label: "Check handoff"
        )
        #expect(first != nil)
        #expect(second != nil)

        let updated = try #require(try take.attemptStore.attempt(withID: take.attempt.id))
        #expect(updated.markers.map(\.label) == ["Check handoff", "Check repeated Lumera"])

        try take.attemptStore.deleteAttempt(updated)
        let ghost = try take.attemptStore.addManualMarker(
            toAttemptID: take.attempt.id,
            timestamp: 2.0,
            label: "Should not resurrect"
        )
        #expect(ghost == nil)
        #expect(try take.attemptStore.attempt(withID: take.attempt.id) == nil)
    }

    @Test("TakeReviewAnalysisCard renders cleanly in Light, Dark, and Accessibility Dynamic Type sizes")
    func analysisCardRendersAcrossAppearancesAndDynamicType() {
        let sampleResult = makeSampleAmbiguousResult()
        let phases: [TakeAnalysisPhase] = [
            .completed(sampleResult),
            .assetsNotInstalled(localeIdentifier: "en_US"),
            .unavailable(kind: .unsupportedDevice, reason: "Unavailable on simulator."),
            .failed(message: "Offline download error.", canRetry: true, previousResult: sampleResult),
            .analyzing(localeIdentifier: "en_US", previousResult: nil),
            .declined
        ]
        let configurations: [(ColorScheme, DynamicTypeSize)] = [
            (.light, .large),
            (.dark, .large),
            (.light, .accessibility3),
            (.dark, .accessibility5)
        ]

        for phase in phases {
            for (scheme, typeSize) in configurations {
                let card = TakeReviewAnalysisCard(
                    phase: phase,
                    isAudioLoaded: true,
                    currentPlaybackTime: 2.2,
                    totalDuration: 10.0,
                    isAccessibilitySize: typeSize.isAccessibilitySize,
                    onSeekObservation: { _ in },
                    onAddManualMarker: { _ in },
                    onInstallAssets: { _ in },
                    onReanalyze: {},
                    onDecline: {},
                    onCancel: {}
                )
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)

                let hosting = UIHostingController(rootView: card)
                hosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
                hosting.view.setNeedsLayout()
                hosting.view.layoutIfNeeded()
                let fitted = hosting.sizeThatFits(in: CGSize(width: 393, height: 2000))
                #expect(fitted.width > 0)
                #expect(fitted.height > 0)
            }
        }
    }
}

private extension TakeAnalysisRaceAndUITests {
    struct ReanalysisBaseline {
        let audioPath: String?
        let talkRevisionID: UUID
        let sectionRevisionID: UUID
    }

    func editSectionToRevisionTwo(
        in library: PresentationStore,
        seeded: SeededSectionFixture
    ) throws {
        _ = try library.saveSectionEdit(
            in: seeded.presentation,
            sectionID: seeded.section.sectionID,
            draft: SectionDraft(
                title: "Updated Reveal",
                text: "Completely rewritten revision 2 script.",
                speaker: "Jordan",
                speakerRole: .presenter,
                purpose: .reveal,
                cueWords: ["rewritten"],
                exactPhrase: "Completely rewritten revision 2 script.",
                handoffCueOverride: nil
            )
        )
    }

    func verifyReanalyzedTake(
        take: SeededAudioTake,
        library: PresentationStore,
        firstPersisted: TimingAnalysisResult,
        baseline: ReanalysisBaseline
    ) throws {
        let allAttempts = try take.attemptStore.fetchAttempts(
            forPresentationID: take.seeded.presentation.id,
            includeInProgress: true
        )
        #expect(allAttempts.count == 1)
        let updatedAttempt = try #require(allAttempts.first)
        #expect(updatedAttempt.id == take.attempt.id)
        #expect(updatedAttempt.relativeAudioPath == baseline.audioPath)
        #expect(updatedAttempt.talkRevisionID == baseline.talkRevisionID)
        #expect(updatedAttempt.sectionRevisionID == baseline.sectionRevisionID)
        #expect(updatedAttempt.timingAnalysis?.analysisVersion == 2)
        #expect(updatedAttempt.timingAnalysis?.recognizedWordCount == 5)
        #expect(updatedAttempt.timingAnalysis?.analysisID != firstPersisted.analysisID)

        let originalSection = try #require(try library.sectionRevision(withID: baseline.sectionRevisionID))
        #expect(originalSection.exactPhrase == "Today we unveil Spelum offline.")

        let mismatchedSaved = try take.attemptStore.saveTimingAnalysis(
            firstPersisted,
            forAttemptID: updatedAttempt.id,
            expectedRelativeAudioPath: baseline.audioPath,
            expectedTalkRevisionID: UUID(),
            expectedSectionRevisionID: baseline.sectionRevisionID
        )
        #expect(!mismatchedSaved)
        #expect(updatedAttempt.timingAnalysis?.analysisVersion == 2)
    }

    func makeSampleAmbiguousResult() -> TimingAnalysisResult {
        TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 10.0,
                scriptText: "Lumera starts fast. Lumera keeps recordings local.",
                exactPhrase: "Lumera",
                cueWords: ["local"],
                hasMultipleSpeakersOrHandoff: true,
                segments: [
                    TimedTranscriptSegment(text: "Lumera", startTime: 0.4, endTime: 0.9),
                    TimedTranscriptSegment(text: "starts", startTime: 0.95, endTime: 1.35),
                    TimedTranscriptSegment(text: "fast.", startTime: 1.4, endTime: 1.8),
                    TimedTranscriptSegment(text: "Lumera", startTime: 2.6, endTime: 3.1),
                    TimedTranscriptSegment(text: "keeps", startTime: 3.15, endTime: 3.5),
                    TimedTranscriptSegment(text: "local.", startTime: 3.55, endTime: 4.0)
                ],
                localeIdentifier: "en_US"
            )
        )
    }
}
