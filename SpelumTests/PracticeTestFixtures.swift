import AVFoundation
import Foundation
import Testing
@testable import Spelum

struct PracticeTestWorkspace {
    let directory: URL
    let storeURL: URL
    let storageRoot: URL

    static func create(prefix: String = "SpelumTests") throws -> PracticeTestWorkspace {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("spelum.sqlite")
        let storageRoot = directory.appendingPathComponent("Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        return PracticeTestWorkspace(directory: directory, storeURL: storeURL, storageRoot: storageRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct SeededSectionFixture {
    let presentation: PresentationRecord
    let talkRevision: TalkRevisionRecord
    let section: SectionRevisionRecord

    var snapshot: AttemptSnapshotReference {
        AttemptSnapshotReference(
            presentationID: presentation.id,
            talkRevisionID: talkRevision.id,
            talkRevisionNumber: talkRevision.revisionNumber,
            sectionID: section.sectionID,
            sectionRevisionID: section.revisionID,
            sectionTitle: section.title
        )
    }
}

@MainActor
enum PracticeTestFixtures {
    static func writeSyntheticAudio(to url: URL, durationSeconds: Double = 1.2) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "SyntheticAudio", code: 1)
        }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "SyntheticAudio", code: 2)
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0 ..< Int(frameCount) {
                let phase = 2.0 * Double.pi * 440.0 * Double(frame) / sampleRate
                channel[frame] = Float(sin(phase) * 0.25)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func seedPresentation(
        in store: PresentationStore,
        title: String = "Keynote Secret Launch"
    ) throws -> SeededSectionFixture {
        let script = """
        Alex: Welcome to our rehearsal preview.
        Jordan: Today we unveil Spelum offline.
        """
        let presentation = try store.importScript(text: script, title: title)
        let initial = try #require(store.orderedSections(for: presentation).first)
        let splitIdx = try #require(initial.text.range(of: "Jordan:")).lowerBound
        let split = try store.splitSection(in: presentation, sectionID: initial.sectionID, at: splitIdx)
        let editedRev = try store.saveSectionEdit(
            in: presentation,
            sectionID: split.secondSection.sectionID,
            draft: SectionDraft(
                title: "Product Reveal",
                text: split.secondSection.text,
                speaker: "Jordan",
                speakerRole: .presenter,
                purpose: .reveal,
                cueWords: ["unveil", "offline"],
                exactPhrase: "Today we unveil Spelum offline.",
                handoffCueOverride: nil
            )
        )
        let revealSection = try #require(store.orderedSections(in: editedRev).last)
        return SeededSectionFixture(
            presentation: presentation,
            talkRevision: editedRev,
            section: revealSection
        )
    }

    static func saveSyntheticTake(
        in store: AttemptStore,
        snapshot: AttemptSnapshotReference,
        mode: PracticeMode,
        durationSeconds: Double
    ) throws -> (attempt: AttemptRecord, audioURL: URL) {
        let pending = try store.beginAttempt(snapshot: snapshot, practiceMode: mode, isSilentRecall: false)
        let path = try #require(pending.relativeAudioPath)
        let url = try store.resolvedAudioURL(for: path)
        try writeSyntheticAudio(to: url, durationSeconds: durationSeconds)
        let finalized = try store.finalizeAttempt(
            AttemptFinalizationInput(
                id: pending.id,
                snapshot: snapshot,
                practiceMode: mode,
                startedAt: pending.startedAt,
                relativeAudioPath: path,
                elapsedDuration: durationSeconds,
                revealCount: 0,
                markers: [],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil
            )
        )
        return (finalized, url)
    }
}
