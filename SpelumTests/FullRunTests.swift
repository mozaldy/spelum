import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Spelum

@MainActor
private final class SteppableFullRunRecorder: AudioRecorderControlling {
    var currentTime: TimeInterval = 0
    var isRecording = false
    var onUnexpectedFinish: ((Bool) -> Void)?
    var onEncodeError: ((Error?) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    var totalDuration: TimeInterval = 4.0
    var silentDemoRange: Range<Double>? = 2.0 ..< 3.0

    func startRecording(to url: URL) throws {
        startCount += 1
        isRecording = true
        currentTime = 0
        try FullRunTestFixtures.writeContinuousQuietAAC(
            to: url,
            durationSeconds: totalDuration,
            silentRange: silentDemoRange
        )
    }

    func stopRecording() {
        stopCount += 1
        isRecording = false
    }
}

@MainActor
enum FullRunTestFixtures {
    struct FourSectionTalk {
        let presentation: PresentationRecord
        let talkRevision: TalkRevisionRecord
        let sections: [SectionRevisionRecord]
    }

    static func writeContinuousQuietAAC(
        to url: URL,
        durationSeconds: Double,
        silentRange: Range<Double>? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sampleRate = 44_100.0
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "QuietFullRunAudio", code: 1)
        }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "QuietFullRunAudio", code: 2)
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0 ..< Int(frameCount) {
                let time = Double(frame) / sampleRate
                if let silentRange, silentRange.contains(time) {
                    channel[frame] = 0
                } else {
                    let phase = 2.0 * Double.pi * 440.0 * time
                    // Quiet low-amplitude tone so tests never emit loud sound.
                    channel[frame] = Float(sin(phase) * 0.01)
                }
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: AVAudioRecorderController.recordingSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    static func seedFourSectionTalk(
        in store: PresentationStore,
        title: String = "Launch Keynote"
    ) throws -> FourSectionTalk {
        let raw = """
        Alex: Welcome everyone to our live offline rehearsal demo.
        Jordan: Today we unveil Spelum for confident keynote speakers.
        Jordan: Watch as the product switches seamlessly during the silent live demo.
        Jordan: Thank you for joining us today and enjoy the launch.
        """
        let presentation = try store.importScript(text: raw, title: title)
        let first = try #require(store.orderedSections(for: presentation).first)

        let split1Idx = try #require(first.text.range(of: "Jordan: Today")).lowerBound
        let split1 = try store.splitSection(in: presentation, sectionID: first.sectionID, at: split1Idx)

        let split2Idx = try #require(split1.secondSection.text.range(of: "Jordan: Watch")).lowerBound
        let split2 = try store.splitSection(
            in: presentation,
            sectionID: split1.secondSection.sectionID,
            at: split2Idx
        )

        let split3Idx = try #require(split2.secondSection.text.range(of: "Jordan: Thank")).lowerBound
        let split3 = try store.splitSection(
            in: presentation,
            sectionID: split2.secondSection.sectionID,
            at: split3Idx
        )

        let currentSections = store.orderedSections(for: presentation)
        #expect(currentSections.count == 4)

        let drafts: [(UUID, String, String, SpeakerRole, SectionPurpose, [String])] = [
            (currentSections[0].sectionID, "Opening", "Alex", .teammate, .opening, ["welcome", "offline"]),
            (currentSections[1].sectionID, "Product Reveal", "Jordan", .presenter, .reveal, ["unveil", "Spelum"]),
            (currentSections[2].sectionID, "Live Demo", "Jordan", .presenter, .demo, ["switch", "silent"]),
            (currentSections[3].sectionID, "Close", "Jordan", .presenter, .close, ["thank", "launch"])
        ]

        var latestRevision = try #require(store.currentTalkRevision(for: presentation))
        for (sectionID, secTitle, speaker, role, purpose, cues) in drafts {
            let existing = try #require(store.orderedSections(in: latestRevision).first { $0.sectionID == sectionID })
            latestRevision = try store.saveSectionEdit(
                in: presentation,
                sectionID: sectionID,
                draft: SectionDraft(
                    title: secTitle,
                    text: existing.text,
                    speaker: speaker,
                    speakerRole: role,
                    purpose: purpose,
                    cueWords: cues,
                    exactPhrase: nil,
                    handoffCueOverride: nil
                )
            )
        }

        return FourSectionTalk(
            presentation: presentation,
            talkRevision: latestRevision,
            sections: store.orderedSections(in: latestRevision)
        )
    }
}

@Suite("Full Run Rehearsal, Monotonic Timeline, Recovery & Immutability")
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

        let session = RecordingSession(
            attemptStore: attemptStore,
            fullRunSnapshot: snapshot,
            practiceMode: .cueWords,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: recorder,
            interruptionMonitor: NoOpAudioInterruptionMonitor(),
            nowProvider: { clock }
        )

        await session.startRecording()
        #expect(session.phase == .recording)
        #expect(session.currentFullRunSection?.title == "Opening")
        #expect(session.fullRunTransitions.count == 1)

        // Advance to Reveal at 0.9s; test reveal counter resets hidden state on advance.
        session.toggleScriptReveal()
        #expect(session.isScriptRevealed)
        #expect(session.revealCount == 1)
        recorder.currentTime = 0.9
        clock = clock.addingTimeInterval(0.9)
        #expect(session.advanceFullRunSection())
        #expect(!session.isScriptRevealed)
        #expect(session.currentFullRunSection?.title == "Product Reveal")

        // Simulate slight recorder timestamp jitter (0.85 < 0.9) and verify monotonic clamping.
        recorder.currentTime = 0.85
        clock = clock.addingTimeInterval(1.1)
        session.addManualMarker(label: "Reveal peak")
        recorder.currentTime = 2.0
        #expect(session.advanceFullRunSection())
        #expect(session.currentFullRunSection?.title == "Live Demo")
        #expect(session.currentFullRunSection?.purpose == .demo)

        // Silent demo runs 2.0..3.0 inside the same continuous recording without splitting files.
        recorder.currentTime = 3.05
        clock = clock.addingTimeInterval(1.05)
        #expect(session.advanceFullRunSection())
        #expect(session.currentFullRunSection?.title == "Close")
        #expect(session.isOnFinalFullRunSection)

        // Extra advance at final section is a safe no-op.
        #expect(!session.advanceFullRunSection())

        recorder.currentTime = 4.0
        clock = clock.addingTimeInterval(0.95)
        let saved = try #require(session.stopRecording())
        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 1)
        #expect(saved.isFullRun)
        #expect(saved.status == .ready)
        #expect(saved.hasPlayableAudio)
        #expect(saved.revealCount == 1)

        // Repeated stop is idempotent and does not duplicate rows.
        #expect(session.stopRecording() == nil)
        #expect(try attemptStore.fetchFullRuns(forPresentationID: talk.presentation.id).count == 1)
        // Full runs do NOT pollute section-only take lists.
        #expect(try attemptStore.fetchSectionTakes(forPresentationID: talk.presentation.id).isEmpty)

        let payload = try #require(saved.fullRunPayload)
        #expect(payload.completionKind == .completedAllSections)
        #expect(payload.reachedSectionCount == 4)
        #expect(payload.unreachedSections.isEmpty)
        #expect(payload.transitions.map(\.sectionTitle) == ["Opening", "Product Reveal", "Live Demo", "Close"])
        #expect(payload.transitions.map(\.speaker) == ["Alex", "Jordan", "Jordan", "Jordan"])

        // Verify strictly monotonic start/end timestamps within audio duration.
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

        // Verify quiet local playback and seeking to every section transition and manual marker.
        let audioURL = try #require(attemptStore.resolvedAudioURL(for: saved))
        let player = TakeAudioPlayer(
            audioSessionManager: TrackingAudioSessionManager(),
            playerVolume: 0.0
        )
        player.load(url: audioURL)
        #expect(player.isLoaded)
        #expect(player.duration > 3.5)
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

    @Test("Starting from presenter handoff snapshots cue, starts at presenter section, and handles single-section talk")
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

        // Single-section talk degrades cleanly to entireTalk scope with 1 section.
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
        let session = RecordingSession(
            attemptStore: attemptStore,
            fullRunSnapshot: soloSnapshot,
            practiceMode: .fullScript,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: recorder,
            interruptionMonitor: NoOpAudioInterruptionMonitor()
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
        let session = RecordingSession(
            attemptStore: attemptStore,
            fullRunSnapshot: snapshot,
            practiceMode: .cueWords,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: recorder,
            interruptionMonitor: NoOpAudioInterruptionMonitor()
        )

        await session.startRecording()
        recorder.currentTime = 1.0
        #expect(session.advanceFullRunSection())
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
        let session = RecordingSession(
            attemptStore: attemptStore,
            fullRunSnapshot: snapshot,
            practiceMode: .cueWords,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: recorder,
            interruptionMonitor: NoOpAudioInterruptionMonitor()
        )
        await session.startRecording()
        recorder.currentTime = 0.6
        _ = session.advanceFullRunSection()
        recorder.currentTime = 2.0
        let savedRun = try #require(session.stopRecording())

        // Mutate talk heavily: edit text & speaker, reorder sections, delete a section.
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

        // Reload saved run and verify snapshot immutability & older revision flag.
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

    @Test("Interrupted run, save failure retry, and crash/relaunch recovery preserve full-run transitions")
    func interruptionSaveRetryAndCrashRecovery() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Recovery")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        var shouldFailSave = true
        let attemptStore = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveHook: { context in
                if shouldFailSave {
                    throw NSError(domain: "SimulatedFullRunSaveFailure", code: 500)
                }
                try context.save()
            }
        )
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .entireTalk
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 2.4
        recorder.silentDemoRange = nil
        let session = RecordingSession(
            attemptStore: attemptStore,
            fullRunSnapshot: snapshot,
            practiceMode: .cueWords,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: recorder,
            interruptionMonitor: NoOpAudioInterruptionMonitor()
        )

        // Allow beginAttempt to succeed, then fail finalizeAttempt save.
        shouldFailSave = false
        await session.startRecording()
        recorder.currentTime = 1.1
        #expect(session.advanceFullRunSection())

        shouldFailSave = true
        recorder.currentTime = 2.4
        session.handleInterruption(reason: "Incoming phone call")
        guard case .saveFailed(let recovery) = session.phase else {
            Issue.record("Expected saveFailed recovery state after simulated save error")
            return
        }
        #expect(recovery.attemptKind == .fullRun)
        #expect(recovery.fullRunPayload?.transitions.count == 2)

        // Retry save succeeds without duplicating records and preserves interrupted audio & transitions.
        shouldFailSave = false
        let retried = try #require(session.retryFailedSave())
        #expect(retried.isFullRun)
        #expect(retried.status == .interrupted)
        #expect(retried.hasPlayableAudio)
        #expect(retried.fullRunPayload?.completionKind == .interrupted)
        #expect(retried.fullRunPayload?.transitions.count == 2)
        #expect(try attemptStore.fetchFullRuns(forPresentationID: talk.presentation.id).count == 1)

        // Now simulate crash recovery of an in-progress full run on next launch.
        let crashAttemptID = UUID()
        let crashRelPath = AttemptStore.opaqueRelativeAudioPath(for: crashAttemptID)
        let crashAudioURL = workspace.storageRoot.appendingPathComponent(crashRelPath)
        try FullRunTestFixtures.writeContinuousQuietAAC(to: crashAudioURL, durationSeconds: 1.8)
        let partialPayload = FullRunAttemptPayload(
            snapshot: snapshot,
            transitions: [
                FullRunSectionTransition(
                    runIndex: 0,
                    talkSectionIndex: 0,
                    sectionID: snapshot.sections[0].sectionID,
                    sectionRevisionID: snapshot.sections[0].sectionRevisionID,
                    sectionTitle: snapshot.sections[0].title,
                    speaker: snapshot.sections[0].speaker,
                    speakerRole: snapshot.sections[0].speakerRole,
                    purpose: snapshot.sections[0].purpose,
                    startTime: 0
                ),
                FullRunSectionTransition(
                    runIndex: 1,
                    talkSectionIndex: 1,
                    sectionID: snapshot.sections[1].sectionID,
                    sectionRevisionID: snapshot.sections[1].sectionRevisionID,
                    sectionTitle: snapshot.sections[1].title,
                    speaker: snapshot.sections[1].speaker,
                    speakerRole: snapshot.sections[1].speakerRole,
                    purpose: snapshot.sections[1].purpose,
                    startTime: 0.9
                )
            ],
            completionKind: .interrupted,
            reachedSectionCount: 2
        )
        _ = try attemptStore.beginAttempt(
            id: crashAttemptID,
            snapshot: snapshot.makeAttemptSnapshotReference(),
            practiceMode: .cueWords,
            relativeAudioPath: crashRelPath,
            attemptKind: .fullRun,
            fullRunPayload: partialPayload
        )

        let relaunchedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let relaunchedAttempts = AttemptStore(
            modelContext: relaunchedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let summary = relaunchedAttempts.recoverInterruptedAttemptsOnLaunch()
        #expect(summary.recoveredCount == 1)
        let recovered = try #require(try relaunchedAttempts.attempt(withID: crashAttemptID))
        #expect(recovered.isFullRun)
        #expect(recovered.status == .interrupted)
        #expect(recovered.hasPlayableAudio)
        #expect(recovered.fullRunPayload?.transitions.count == 2)
        #expect(recovered.fullRunPayload?.transitions[1].endTime != nil)
    }

    @Test("Full run retries preserve mode and scope, and deleting one run keeps other runs playable")
    func retryAndIsolatedDeletion() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7RetryDelete")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .fromHandoff
            )
        )

        let recorder = SteppableFullRunRecorder()
        recorder.totalDuration = 1.6
        recorder.silentDemoRange = nil
        let session = RecordingSession(
            attemptStore: attemptStore,
            fullRunSnapshot: snapshot,
            practiceMode: .minimalCue,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: recorder,
            interruptionMonitor: NoOpAudioInterruptionMonitor()
        )

        await session.startRecording()
        recorder.currentTime = 1.6
        let firstRun = try #require(session.stopRecording())

        let retryTarget = TakeReview.makeFullRunRetryTarget(
            for: firstRun,
            payload: try #require(firstRun.fullRunPayload)
        )
        #expect(retryTarget.talkRevisionID == talk.talkRevision.id)
        #expect(retryTarget.startKind == .fromHandoff)
        #expect(retryTarget.initialMode == .minimalCue)

        session.prepareForFullRunRetry(snapshot: snapshot, practiceMode: retryTarget.initialMode)
        await session.startRecording()
        recorder.currentTime = 1.6
        let secondRun = try #require(session.stopRecording())

        #expect(firstRun.id != secondRun.id)
        #expect(firstRun.relativeAudioPath != secondRun.relativeAudioPath)

        // Delete first run; second run and its audio remain untouched.
        try attemptStore.deleteAttempt(firstRun)
        #expect(try attemptStore.attempt(withID: firstRun.id) == nil)
        let remaining = try #require(try attemptStore.attempt(withID: secondRun.id))
        let remainingURL = try #require(attemptStore.resolvedAudioURL(for: remaining))
        #expect(FileManager.default.fileExists(atPath: remainingURL.path))
    }
}
