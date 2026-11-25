import AVFoundation
import CoreMedia
import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 3 Real AAC-in-M4A Audio Coverage")
@MainActor
struct Task3AACAudioCoverageTests {
    // Verifies real AVFoundation AAC-in-M4A encoding, decoding, container/codec inspection,
    // duration measurement, persistence, and TakeAudioPlayer playback using generated audio
    // without requiring a physical microphone. Physical iPhone microphone capture, hardware
    // interruption routing, and airplane-mode recording remain explicit physical-device checks.
    @Test("Generated AAC-in-M4A audio passes container, codec, decode, and duration checks")
    func generatedAACInM4APassesFormatDecodeAndDurationChecks() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3AACFormat")
        defer { workspace.cleanup() }

        let audioURL = workspace.storageRoot.appendingPathComponent("Takes/encoded-check.m4a")
        try PracticeTestFixtures.writeSyntheticAACM4A(to: audioURL, durationSeconds: 1.6, frequencyHz: 523.25)

        // 1. ISO Base Media / M4A container header check.
        let headerBytes = try Data(contentsOf: audioURL, options: .mappedIfSafe).prefix(16)
        let ftypTag = String(bytes: headerBytes.dropFirst(4).prefix(4), encoding: .ascii)
        #expect(ftypTag == "ftyp")

        // 2. AVURLAsset codec and stream format description check.
        let asset = AVURLAsset(url: audioURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try #require(audioTracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let formatDesc = try #require(formatDescriptions.first)
        #expect(CMFormatDescriptionGetMediaSubType(formatDesc) == kAudioFormatMPEG4AAC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc))
        #expect(asbd.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.pointee.mSampleRate == 44_100.0)
        #expect(asbd.pointee.mChannelsPerFrame == 1)

        // 3. Asset and inspector duration checks.
        let assetDuration = try await asset.load(.duration).seconds
        #expect(assetDuration > 1.4 && assetDuration < 1.85)
        let inspectedDuration = try #require(AVAudioFileInspector().playableDuration(at: audioURL))
        #expect(inspectedDuration > 1.4 && inspectedDuration < 1.85)

        // 4. Real AAC -> PCM decode check confirms non-empty frames and non-silent signal energy.
        let readableFile = try AVAudioFile(forReading: audioURL)
        let capacity = AVAudioFrameCount(max(readableFile.length, 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: readableFile.processingFormat, frameCapacity: capacity))
        try readableFile.read(into: buffer)
        #expect(buffer.frameLength > 60_000)
        let rms = try rootMeanSquareEnergy(of: buffer)
        #expect(rms > 0.05)
    }

    @Test("Real AAC-in-M4A take persists across store reopen and plays/seeks cleanly in TakeAudioPlayer")
    func realAACInM4ATakePersistsAndPlaysCleanly() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3AACPlayback")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        let pending = try store.beginAttempt(
            snapshot: seeded.snapshot,
            practiceMode: .cueWords,
            isSilentRecall: false
        )
        let relativePath = try #require(pending.relativeAudioPath)
        #expect(relativePath.hasSuffix(".m4a"))
        let audioURL = try store.resolvedAudioURL(for: relativePath)
        try PracticeTestFixtures.writeSyntheticAACM4A(to: audioURL, durationSeconds: 1.6)

        let finalized = try store.finalizeAttempt(
            AttemptFinalizationInput(
                id: pending.id,
                snapshot: seeded.snapshot,
                practiceMode: .cueWords,
                startedAt: pending.startedAt,
                relativeAudioPath: relativePath,
                elapsedDuration: 1.6,
                revealCount: 1,
                markers: [AttemptMarker(timestamp: 0.75, label: "Midpoint")],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil
            )
        )
        #expect(finalized.status == .ready)
        #expect(finalized.playableDuration > 1.4 && finalized.playableDuration < 1.85)

        let reopened = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let reopenedStore = AttemptStore(modelContext: reopened.mainContext, storageRootURL: workspace.storageRoot)
        let fetched = try #require(try reopenedStore.attempt(withID: pending.id))
        let reopenedURL = try #require(reopenedStore.resolvedAudioURL(for: fetched))

        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: reopenedURL)
        #expect(player.isLoaded)
        #expect(player.errorMessage == nil)
        #expect(player.duration > 1.4 && player.duration < 1.85)
        player.seek(to: 0.75, autoPlay: true)
        #expect(player.isPlaying)
        #expect(abs(player.currentTime - 0.75) < 0.1)
        player.pause()
        #expect(!player.isPlaying)
        player.stop()
        #expect(!player.isLoaded)
    }

    private func rootMeanSquareEnergy(of buffer: AVAudioPCMBuffer) throws -> Double {
        let samples = try #require(buffer.floatChannelData?[0])
        var sumSquares = 0.0
        for index in 0 ..< Int(buffer.frameLength) {
            let sample = Double(samples[index])
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Double(max(buffer.frameLength, 1)))
    }
}
