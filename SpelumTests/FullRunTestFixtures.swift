import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Spelum

@MainActor
final class SteppableFullRunRecorder: AudioRecorderControlling {
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

struct FullRunSectionDraftSpec {
    let sectionID: UUID
    let title: String
    let speaker: String
    let role: SpeakerRole
    let purpose: SectionPurpose
    let cueWords: [String]
}

struct SyntheticFullRunSpec {
    let snapshot: FullRunSnapshot
    let startedAt: Date
    let duration: TimeInterval
    let revealCount: Int
    let transitionTimes: [TimeInterval]
    let practiceMode: PracticeMode
    let completionKind: FullRunCompletionKind

    init(
        snapshot: FullRunSnapshot,
        startedAt: Date,
        duration: TimeInterval,
        revealCount: Int = 0,
        transitionTimes: [TimeInterval],
        practiceMode: PracticeMode = .cueWords,
        completionKind: FullRunCompletionKind = .completedAllSections
    ) {
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.duration = duration
        self.revealCount = revealCount
        self.transitionTimes = transitionTimes
        self.practiceMode = practiceMode
        self.completionKind = completionKind
    }
}

struct SyntheticSectionTakeSpec {
    let presentation: PresentationRecord
    let talkRevision: TalkRevisionRecord
    let section: SectionRevisionRecord
    let startedAt: Date
    let duration: TimeInterval
    let revealCount: Int
    let practiceMode: PracticeMode

    init(
        presentation: PresentationRecord,
        talkRevision: TalkRevisionRecord,
        section: SectionRevisionRecord,
        startedAt: Date,
        duration: TimeInterval,
        revealCount: Int = 0,
        practiceMode: PracticeMode = .cueWords
    ) {
        self.presentation = presentation
        self.talkRevision = talkRevision
        self.section = section
        self.startedAt = startedAt
        self.duration = duration
        self.revealCount = revealCount
        self.practiceMode = practiceMode
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
                    // Quiet low-amplitude tone so simulator runs stay quiet.
                    channel[frame] = Float(sin(phase) * 0.005)
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
        _ = try store.splitSection(
            in: presentation,
            sectionID: split2.secondSection.sectionID,
            at: split3Idx
        )

        let sections = store.orderedSections(for: presentation)
        #expect(sections.count == 4)

        var latestRevision = try #require(store.currentTalkRevision(for: presentation))
        for spec in defaultSectionDraftSpecs(for: sections) {
            let existing = try #require(
                store.orderedSections(in: latestRevision).first { $0.sectionID == spec.sectionID }
            )
            latestRevision = try store.saveSectionEdit(
                in: presentation,
                sectionID: spec.sectionID,
                draft: SectionDraft(
                    title: spec.title,
                    text: existing.text,
                    speaker: spec.speaker,
                    speakerRole: spec.role,
                    purpose: spec.purpose,
                    cueWords: spec.cueWords,
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

    private static func defaultSectionDraftSpecs(
        for sections: [SectionRevisionRecord]
    ) -> [FullRunSectionDraftSpec] {
        [
            FullRunSectionDraftSpec(
                sectionID: sections[0].sectionID,
                title: "Opening",
                speaker: "Alex",
                role: .teammate,
                purpose: .story,
                cueWords: ["welcome", "offline"]
            ),
            FullRunSectionDraftSpec(
                sectionID: sections[1].sectionID,
                title: "Product Reveal",
                speaker: "Jordan",
                role: .presenter,
                purpose: .reveal,
                cueWords: ["unveil", "Spelum"]
            ),
            FullRunSectionDraftSpec(
                sectionID: sections[2].sectionID,
                title: "Live Demo",
                speaker: "Jordan",
                role: .presenter,
                purpose: .demonstration,
                cueWords: ["switch", "silent"]
            ),
            FullRunSectionDraftSpec(
                sectionID: sections[3].sectionID,
                title: "Close",
                speaker: "Jordan",
                role: .presenter,
                purpose: .closing,
                cueWords: ["thank", "launch"]
            )
        ]
    }

    static func makeSession(
        attemptStore: AttemptStore,
        snapshot: FullRunSnapshot,
        initialMode: PracticeMode = .cueWords,
        recorder: SteppableFullRunRecorder,
        nowProvider: @escaping () -> Date = Date.init
    ) -> RecordingSession {
        RecordingSession(
            attemptStore: attemptStore,
            fullRunSnapshot: snapshot,
            initialMode: initialMode,
            permissionProvider: ControlledMicrophonePermissionProvider(status: .granted),
            audioSessionManager: TrackingAudioSessionManager(),
            recorder: recorder,
            notificationCenter: NotificationCenter(),
            nowProvider: nowProvider
        )
    }

    static func saveSyntheticFullRun(
        _ spec: SyntheticFullRunSpec,
        in attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws -> AttemptRecord {
        let attemptID = UUID()
        let relPath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        let url = workspace.storageRoot.appendingPathComponent(relPath)
        try writeContinuousQuietAAC(to: url, durationSeconds: spec.duration)
        let transitions = zip(spec.snapshot.sections, spec.transitionTimes).map { section, startTime in
            FullRunSectionTransition(
                runIndex: section.runIndex,
                talkSectionIndex: section.talkSectionIndex,
                sectionID: section.sectionID,
                sectionRevisionID: section.sectionRevisionID,
                sectionTitle: section.title,
                speaker: section.speaker,
                speakerRole: section.speakerRole,
                purpose: section.purpose,
                startTime: startTime
            )
        }
        let payload = FullRunAttemptPayload(
            snapshot: spec.snapshot,
            transitions: transitions,
            completionKind: spec.completionKind,
            reachedSectionCount: transitions.count
        )
        return try attemptStore.finalizeAttempt(
            AttemptFinalizationInput(
                id: attemptID,
                snapshot: spec.snapshot.makeAttemptSnapshotReference(),
                practiceMode: spec.practiceMode,
                startedAt: spec.startedAt,
                finishedAt: spec.startedAt.addingTimeInterval(spec.duration),
                relativeAudioPath: relPath,
                elapsedDuration: spec.duration,
                revealCount: spec.revealCount,
                markers: [],
                isSilentRecall: false,
                interrupted: spec.completionKind == .interrupted,
                interruptionReason: spec.completionKind == .interrupted ? "Interrupted" : nil,
                attemptKind: .fullRun,
                fullRunPayload: payload
            )
        )
    }

    static func saveSyntheticSectionTake(
        _ spec: SyntheticSectionTakeSpec,
        in attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws -> AttemptRecord {
        let attemptID = UUID()
        let relPath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        let url = workspace.storageRoot.appendingPathComponent(relPath)
        try writeContinuousQuietAAC(to: url, durationSeconds: spec.duration)
        let ref = AttemptSnapshotReference(
            presentationID: spec.presentation.id,
            talkRevisionID: spec.talkRevision.id,
            talkRevisionNumber: spec.talkRevision.revisionNumber,
            sectionID: spec.section.sectionID,
            sectionRevisionID: spec.section.revisionID,
            sectionTitle: spec.section.title
        )
        return try attemptStore.finalizeAttempt(
            AttemptFinalizationInput(
                id: attemptID,
                snapshot: ref,
                practiceMode: spec.practiceMode,
                startedAt: spec.startedAt,
                finishedAt: spec.startedAt.addingTimeInterval(spec.duration),
                relativeAudioPath: relPath,
                elapsedDuration: spec.duration,
                revealCount: spec.revealCount,
                markers: [],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil
            )
        )
    }
}
