import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Full Run Rehearsal, Monotonic Timeline & Immutability")
@MainActor
struct FullRunTests {
    @Test("Four-section full run records continuous audio, silent demo, monotonic times, and playable seeks")
    func fourSectionFullRunWithSilentDemoAndMonotonicSeeks() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7FullRunFour")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .entireTalk
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 4.0
        recorder.silentDemoRange = 2.0 ..< 3.0
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            recorder: recorder,
            nowProvider: { clock }
        )

        let saved = try await executeFourSectionRun(
            session: session,
            recorder: recorder,
            advanceClock: { clock = clock.addingTimeInterval($0) }
        )

        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 1)
        #expect(saved.isFullRun)
        #expect(saved.status == .ready)
        #expect(saved.hasPlayableAudio)
        #expect(saved.revealCount == 1)
        #expect(session.stopRecording() == nil)
        #expect(try attemptStore.fetchFullRuns(forPresentationID: talk.presentation.id).count == 1)
        #expect(try attemptStore.fetchSectionTakes(forPresentationID: talk.presentation.id).isEmpty)

        try verifyCompletedFourSectionPayloadAndSeeks(saved: saved, attemptStore: attemptStore)
    }

    @Test("Timed silent full run tracks monotonic section transitions and early finish without audio")
    func timedSilentFullRunTracksTransitionsWithoutAudio() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7SilentRun")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .entireTalk
            )
        )

        var clock = Date(timeIntervalSince1970: 1_700_100_000)
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            initialMode: .memory,
            recorder: SteppableFullRunRecorder(),
            nowProvider: { clock }
        )

        session.startSilentRecall()
        #expect(session.phase == .silentRecall)
        clock = clock.addingTimeInterval(1.2)
        let revealTransition = try #require(session.advanceFullRunSection())
        #expect(revealTransition.sectionTitle == "Product Reveal")
        #expect(revealTransition.startTime >= 1.1)

        clock = clock.addingTimeInterval(1.5)
        let demoTransition = try #require(session.advanceFullRunSection())
        #expect(demoTransition.purpose == .demonstration)
        #expect(demoTransition.startTime >= revealTransition.startTime)

        clock = clock.addingTimeInterval(2.0)
        let saved = try #require(session.finishFullRunEarly())
        #expect(saved.isFullRun)
        #expect(saved.isSilentRecall)
        #expect(saved.status == .silentCompleted)
        #expect(!saved.hasPlayableAudio)
        let payload = try #require(saved.fullRunPayload)
        #expect(payload.completionKind == .finishedEarly)
        #expect(payload.reachedSectionCount == 3)
        #expect(payload.unreachedSections.map(\.title) == ["Close"])
    }

    @Test("Starting from presenter handoff snapshots cue and handles single-section talk")
    func presenterHandoffStartAndSingleSectionTalk() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7HandoffSingle")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)

        let defaultHandoff = try #require(library.defaultPresenterHandoffSection(in: talk.talkRevision))
        #expect(defaultHandoff.title == "Product Reveal")
        #expect(defaultHandoff.speaker == "Jordan")

        let handoffSnapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .fromHandoff
            )
        )
        #expect(handoffSnapshot.startKind == .fromHandoff)
        #expect(handoffSnapshot.startingTalkSectionIndex == 1)
        #expect(handoffSnapshot.sections.map(\.title) == ["Product Reveal", "Live Demo", "Close"])
        #expect(handoffSnapshot.sections.first?.handoffIsSpeakerChange == true)
        #expect(handoffSnapshot.sections.first?.handoffPrecedingSpeaker == "Alex")
        #expect(handoffSnapshot.sections.first?.handoffCueText?.isEmpty == false)

        let soloTalk = try library.importScript(
            text: "This is a concise solo lightning talk with one continuous section.",
            title: "Solo Lightning"
        )
        let soloRev = try #require(library.currentTalkRevision(for: soloTalk))
        #expect(library.defaultPresenterHandoffSection(in: soloRev) == nil)
        let soloSnapshot = try #require(
            library.makeFullRunSnapshot(for: soloTalk, talkRevision: soloRev, startKind: .fromHandoff)
        )
        #expect(soloSnapshot.startKind == .entireTalk)
        #expect(soloSnapshot.sections.count == 1)

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 1.4
        recorder.silentDemoRange = nil
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: soloSnapshot,
            initialMode: .fullScript,
            recorder: recorder
        )
        await session.startRecording()
        #expect(session.isOnFinalFullRunSection)
        recorder.currentTime = 1.4
        let saved = try #require(session.stopRecording())
        #expect(saved.fullRunPayload?.completionKind == .completedAllSections)
        #expect(saved.fullRunPayload?.transitions.count == 1)
    }

    @Test("Early finish saves continuous audio, preserves reached transitions, and lists unreached sections")
    func earlyFinishPreservesAudioAndUnreachedSections() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7EarlyFinish")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .entireTalk
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 2.2
        recorder.silentDemoRange = nil
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            recorder: recorder
        )

        await session.startRecording()
        recorder.currentTime = 1.0
        _ = try #require(session.advanceFullRunSection())
        recorder.currentTime = 2.2
        let saved = try #require(session.finishFullRunEarly())
        #expect(saved.status == .ready)
        #expect(saved.hasPlayableAudio)
        let payload = try #require(saved.fullRunPayload)
        #expect(payload.completionKind == .finishedEarly)
        #expect(payload.reachedSectionCount == 2)
        #expect(payload.transitions.map(\.sectionTitle) == ["Opening", "Product Reveal"])
        #expect(payload.unreachedSections.map(\.title) == ["Live Demo", "Close"])
    }

    @Test("Script edits, speaker reassignments, reorders, and deletions never mutate saved full runs")
    func scriptEditsReordersAndDeletionsPreserveImmutableFullRunSnapshot() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Immutable")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let revBefore = talk.talkRevision
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: revBefore,
                startKind: .entireTalk
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 2.0
        recorder.silentDemoRange = nil
        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            recorder: recorder
        )
        await session.startRecording()
        recorder.currentTime = 0.6
        _ = session.advanceFullRunSection()
        recorder.currentTime = 2.0
        let savedRun = try #require(session.stopRecording())

        try mutateTalkHeavily(talk: talk, in: library)

        let reloaded = try #require(try attemptStore.attempt(withID: savedRun.id))
        let payload = try #require(reloaded.fullRunPayload)
        #expect(payload.snapshot.talkRevisionID == revBefore.id)
        #expect(payload.snapshot.sections.map(\.title) == ["Opening", "Product Reveal", "Live Demo", "Close"])
        #expect(payload.snapshot.sections.map(\.speaker) == ["Alex", "Jordan", "Jordan", "Jordan"])
        #expect(payload.snapshot.sections[1].text.contains("unveil Spelum"))
        let descriptor = ComparableAttemptDescriptor(record: reloaded)
        let currentSectionRevIDs = Set(library.orderedSections(for: talk.presentation).map(\.revisionID))
        #expect(
            descriptor.isOlderRevision(
                currentTalkRevisionID: talk.presentation.currentRevisionID,
                currentSectionRevisionIDs: currentSectionRevIDs
            )
        )
    }
}

private extension FullRunTests {
    func executeFourSectionRun(
        session: RecordingSession,
        recorder: SteppableFullRunRecorder,
        advanceClock: (TimeInterval) -> Void
    ) async throws -> AttemptRecord {
        await session.startRecording()
        #expect(session.phase == .recording)
        #expect(session.currentFullRunSection?.title == "Opening")
        #expect(session.fullRunTransitions.count == 1)

        session.toggleReveal()
        #expect(session.isScriptRevealed)
        #expect(session.revealCount == 1)
        recorder.currentTime = 0.9
        advanceClock(0.9)
        let toReveal = try #require(session.advanceFullRunSection())
        #expect(toReveal.sectionTitle == "Product Reveal")
        #expect(!session.isScriptRevealed)
        #expect(session.currentFullRunSection?.title == "Product Reveal")

        // Simulate slight recorder timestamp jitter (0.85 < 0.9) and verify monotonic clamping.
        recorder.currentTime = 0.85
        advanceClock(1.1)
        session.addManualMarker(label: "Reveal peak")
        recorder.currentTime = 2.0
        let toDemo = try #require(session.advanceFullRunSection())
        #expect(toDemo.sectionTitle == "Live Demo")
        #expect(toDemo.purpose == .demonstration)

        // Silent demo runs 2.0..3.0 inside the same continuous recording without splitting files.
        recorder.currentTime = 3.05
        advanceClock(1.05)
        let toClose = try #require(session.advanceFullRunSection())
        #expect(toClose.sectionTitle == "Close")
        #expect(session.isOnFinalFullRunSection)
        #expect(session.advanceFullRunSection() == nil)

        recorder.currentTime = 4.0
        advanceClock(0.95)
        return try #require(session.stopRecording())
    }

    func verifyCompletedFourSectionPayloadAndSeeks(
        saved: AttemptRecord,
        attemptStore: AttemptStore
    ) throws {
        let payload = try #require(saved.fullRunPayload)
        #expect(payload.completionKind == .completedAllSections)
        #expect(payload.reachedSectionCount == 4)
        #expect(payload.unreachedSections.isEmpty)
        #expect(payload.transitions.map(\.sectionTitle) == ["Opening", "Product Reveal", "Live Demo", "Close"])
        #expect(payload.transitions.map(\.speaker) == ["Alex", "Jordan", "Jordan", "Jordan"])

        for idx in payload.transitions.indices {
            let trans = payload.transitions[idx]
            #expect(trans.startTime >= 0)
            #expect(trans.startTime <= saved.playableDuration + 0.05)
            let endTime = try #require(trans.endTime)
            #expect(endTime >= trans.startTime)
            if idx > 0 {
                #expect(trans.startTime >= payload.transitions[idx - 1].startTime)
            }
        }

        let audioURL = try #require(attemptStore.resolvedAudioURL(for: saved))
        let player = TakeAudioPlayer(
            audioSessionManager: TrackingAudioSessionManager(),
            playerVolume: 0.0
        )
        player.load(url: audioURL)
        #expect(player.isLoaded)
        #expect(player.duration > 3.5)

        // Replay of Reveal and every recorded transition/marker seeks accurately within audio.
        let revealTransition = try #require(payload.transitions.first { $0.purpose == .reveal })
        player.seek(to: revealTransition.startTime, autoPlay: false)
        #expect(abs(player.currentTime - revealTransition.startTime) < 0.25)
        #expect(payload.activeTransition(at: player.currentTime)?.sectionID == revealTransition.sectionID)

        for transition in payload.transitions {
            player.seek(to: transition.startTime, autoPlay: false)
            #expect(abs(player.currentTime - transition.startTime) < 0.25)
        }
        for marker in saved.markers {
            player.seek(to: marker.timestamp, autoPlay: false)
            #expect(abs(player.currentTime - marker.timestamp) < 0.25)
        }
        player.stop()
    }

    func mutateTalkHeavily(
        talk: FullRunTestFixtures.FourSectionTalk,
        in library: PresentationStore
    ) throws {
        let originalReveal = talk.sections[1]
        _ = try library.saveSectionEdit(
            in: talk.presentation,
            sectionID: originalReveal.sectionID,
            draft: SectionDraft(
                title: "Renamed Reveal",
                text: "Completely rewritten reveal script.",
                speaker: "Sam",
                speakerRole: .teammate,
                purpose: .reveal,
                cueWords: ["rewritten"],
                exactPhrase: nil,
                handoffCueOverride: nil
            )
        )
        let reorderedIDs = [
            talk.sections[3].sectionID,
            talk.sections[2].sectionID,
            talk.sections[1].sectionID,
            talk.sections[0].sectionID
        ]
        _ = try library.reorderSections(in: talk.presentation, orderedSectionIDs: reorderedIDs)
        _ = try library.deleteSection(in: talk.presentation, sectionID: talk.sections[2].sectionID)
    }
}
