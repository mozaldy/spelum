import Foundation
import Testing
@testable import Spelum

@Suite("Timing Observations and Local Transcription")
@MainActor
struct TimingObservationsTests {
    @Test("10-second fixture with 20 words produces 120 estimated WPM, 0.8s gap, and aligned phrase with lead-in seek")
    func tenSecondTwentyWordsFixtureAndSeekWithLeadIn() throws {
        let fixture = try TimingFixtureLoader.fixture(id: "tenSecondTwentyWords")
        let result = TimingObservationsEngine.analyze(TimingFixtureLoader.makeInput(from: fixture))

        #expect(result.outcome == .completed)
        #expect(result.recognizedWordCount == 20)
        #expect(result.elapsedAudioDuration == 10.0)
        #expect(result.timingGranularity == .wordLevel)
        let wpm = try #require(result.estimatedWordsPerMinute)
        #expect(abs(wpm - 120.0) < 0.001)

        let gaps = result.observations.filter { $0.kind == .phraseGap }
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        #expect(abs((gap.gapDuration ?? 0) - 0.8) < 0.001)
        #expect(abs(gap.startTime - 2.0) < 0.001)
        #expect(abs(gap.endTime - 2.8) < 0.001)
        #expect(gap.isEstimate)

        let exactMatch = try #require(result.observations.first { $0.kind == .alignedExactPhrase })
        #expect(exactMatch.matchedPhrase == "Today we unveil Lumera offline.")
        #expect(abs(exactMatch.startTime - 2.8) < 0.001)
        #expect(abs(exactMatch.endTime - 4.95) < 0.001)
        #expect(abs(exactMatch.seekTarget(maxDuration: 10.0) - 2.3) < 0.001)

        try verifyLeadInSeekAgainstTenSecondAudio(observation: exactMatch)
    }

    @Test("Repeated product names omit alignment and surface ambiguous evidence offering manual marking")
    func repeatedProductNameOmitsAlignmentAndOffersManualMarker() throws {
        let fixture = try TimingFixtureLoader.fixture(id: "repeatedProductName")
        let result = TimingObservationsEngine.analyze(TimingFixtureLoader.makeInput(from: fixture))

        #expect(result.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
        let repeatedNotes = result.ambiguousNotes.filter { $0.reason == .repeatedPhrase }
        #expect(!repeatedNotes.isEmpty)
        #expect(repeatedNotes.allSatisfy { $0.offersManualMarking })

        let localCue = result.observations.first { $0.kind == .alignedCuePhrase && $0.matchedPhrase == "local" }
        #expect(localCue != nil)
    }

    @Test("Stage direction followed by trailing silence omits trailing gap and does not treat direction as spoken")
    func stageDirectionTrailingSilenceOmitsUnsupportedGap() throws {
        let fixture = try TimingFixtureLoader.fixture(id: "stageDirectionTrailingSilence")
        let result = TimingObservationsEngine.analyze(TimingFixtureLoader.makeInput(from: fixture))

        #expect(result.observations.filter { $0.kind == .phraseGap }.isEmpty)
        #expect(result.observations.contains { $0.kind == .alignedExactPhrase })
        #expect(result.ambiguousNotes.contains { $0.reason == .stageDirectionSilence })
    }

    @Test("Stage direction between two phrases supports bounded 0.8s gap neutrally")
    func stageDirectionBetweenPhrasesSupportsBoundedGap() throws {
        let fixture = try TimingFixtureLoader.fixture(id: "stageDirectionBetweenPhrases")
        let result = TimingObservationsEngine.analyze(TimingFixtureLoader.makeInput(from: fixture))

        let gaps = result.observations.filter { $0.kind == .phraseGap }
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        #expect(abs((gap.gapDuration ?? 0) - 0.8) < 0.001)
        #expect(result.observations.contains { $0.kind == .alignedExactPhrase })
    }

    @Test("Multi-speaker handoff gap is never attributed to a speaker name")
    func multiSpeakerHandoffNeverAttributesGapToSpeaker() throws {
        let fixture = try TimingFixtureLoader.fixture(id: "multiSpeakerHandoffGap")
        let result = TimingObservationsEngine.analyze(TimingFixtureLoader.makeInput(from: fixture))

        let gap = try #require(result.observations.first { $0.kind == .phraseGap })
        #expect(abs((gap.gapDuration ?? 0) - 0.8) < 0.001)
        #expect(!gap.title.localizedCaseInsensitiveContains("Alex"))
        #expect(!gap.title.localizedCaseInsensitiveContains("Jordan"))
        #expect(!gap.detail.localizedCaseInsensitiveContains("Alex"))
        #expect(!gap.detail.localizedCaseInsensitiveContains("Jordan"))
        #expect(result.ambiguousNotes.contains { $0.reason == .multiSpeakerBoundary })
    }

    @Test("Paraphrases, missing words, overlapping ranges, volatile segments, and empty audio omit guesses")
    func unsupportedCasesOmitGuesses() throws {
        let paraphrased = try TimingFixtureLoader.fixture(id: "paraphrasedAndMissingWords")
        let paraphrasedResult = TimingObservationsEngine.analyze(TimingFixtureLoader.makeInput(from: paraphrased))
        #expect(paraphrasedResult.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
        #expect(paraphrasedResult.ambiguousNotes.contains {
            $0.reason == .paraphrasedOrMissingWords && $0.offersManualMarking
        })

        let overlapping = try TimingFixtureLoader.fixture(id: "overlappingRanges")
        let overlapResult = TimingObservationsEngine.analyze(TimingFixtureLoader.makeInput(from: overlapping))
        #expect(overlapResult.hasOverlappingSegments)
        #expect(overlapResult.estimatedWordsPerMinute == nil)
        #expect(overlapResult.observations.isEmpty)
        #expect(overlapResult.ambiguousNotes.contains { $0.reason == .overlappingRanges })

        let volatileInput = TimingAnalysisInput(
            attemptID: UUID(),
            talkRevisionID: UUID(),
            sectionRevisionID: UUID(),
            elapsedAudioDuration: 4.0,
            scriptText: "Today we unveil Lumera.",
            exactPhrase: "Today we unveil Lumera.",
            cueWords: [],
            hasMultipleSpeakersOrHandoff: false,
            segments: [
                TimedTranscriptSegment(text: "Today", startTime: 0.2, endTime: 0.5, isFinal: false),
                TimedTranscriptSegment(text: "we", startTime: 0.6, endTime: 0.8, isFinal: false)
            ],
            localeIdentifier: "en_US",
            hasUntimedFinalText: false
        )
        let volatileResult = TimingObservationsEngine.analyze(volatileInput)
        #expect(volatileResult.recognizedWordCount == 0)
        #expect(volatileResult.estimatedWordsPerMinute == nil)
        #expect(volatileResult.observations.isEmpty)
        #expect(volatileResult.ambiguousNotes.contains { $0.reason == .emptyTranscript })

        let tokens = EnglishWordTokenizer.tokenize("Don't rush — Lumera's launch, live!", localeIdentifier: "en_US")
        #expect(tokens.map(\.normalized) == ["don't", "rush", "lumera's", "launch", "live"])
    }

    private func verifyLeadInSeekAgainstTenSecondAudio(observation: TimingObservation) throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5AudioSeek")
        defer { workspace.cleanup() }
        let audioURL = workspace.storageRoot.appendingPathComponent("fixture-10s.m4a")
        try PracticeTestFixtures.writeSyntheticAACM4A(to: audioURL, durationSeconds: 10.0)

        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: audioURL)
        #expect(player.isLoaded)
        #expect(abs(player.duration - 10.0) < 0.25)

        let seekTime = observation.seekTarget(maxDuration: player.duration)
        player.seek(to: seekTime, autoPlay: false)
        #expect(abs(player.currentTime - seekTime) < 0.05)

        let earlyObservation = TimingObservation(
            kind: .alignedCuePhrase,
            title: "Cue (Estimate)",
            detail: "Early cue",
            startTime: 0.2,
            endTime: 0.5
        )
        #expect(earlyObservation.seekTarget(maxDuration: player.duration) == 0.0)
        player.stop()
    }
}
