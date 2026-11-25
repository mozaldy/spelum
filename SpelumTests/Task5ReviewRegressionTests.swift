import CoreMedia
import Foundation
import Speech
import Testing
@testable import Spelum

@Suite("Task 5 Review Regressions — Untimed Barriers and Invalid Ranges")
@MainActor
struct Task5ReviewRegressionTests {
    // MARK: - Finding (1): Untimed interior spoken word must break contiguity and gap detection

    @Test("Finding 1: untimed interior spoken word breaks phrase contiguity and silence gap")
    func untimedInteriorWordBreaksPhraseContiguityAndSilenceGap() {
        var attributed = makeTimedWord("Today ", start: 0.5, end: 1.0)
        attributed.append(AttributedString("slowly "))
        attributed.append(makeTimedWord("unveil", start: 2.0, end: 2.5))

        let extracted = SpeechResultSegmentExtractor.extract(
            from: attributed,
            isFinal: true,
            localeIdentifier: "en_US"
        )
        #expect(extracted.hasUntimedFinalText)
        #expect(extracted.untimedFragments.count == 1)
        #expect(extracted.untimedFragments[0].text == "slowly")
        #expect(extracted.untimedFragments[0].insertionIndex == 1)

        let result = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: "Today unveil.",
                exactPhrase: "Today unveil",
                segments: extracted.segments,
                localeIdentifier: "en_US",
                hasUntimedFinalText: extracted.hasUntimedFinalText,
                untimedFragments: extracted.untimedFragments
            )
        )

        #expect(result.hasUntimedFinalText)
        #expect(result.estimatedWordsPerMinute == nil)
        #expect(result.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
        #expect(result.observations.filter { $0.kind == .phraseGap }.isEmpty)
        #expect(result.ambiguousNotes.contains {
            $0.reason == .incompleteTimingCoverage && $0.offersManualMarking
        })
    }

    @Test("Finding 1: cross-batch untimed barrier and unlocated untimed flag suppress fake matches and gaps")
    func crossBatchBarrierAndUnlocatedUntimedSuppressUnsupportedClaims() {
        var accumulator = SpeechResultStreamAccumulator(localeIdentifier: "en_US")
        accumulator.append(text: makeTimedWord("Today ", start: 0.5, end: 1.0), isFinal: true)
        accumulator.append(text: AttributedString("slowly "), isFinal: true)
        accumulator.append(text: makeTimedWord("unveil", start: 2.0, end: 2.5), isFinal: true)
        let output = accumulator.finish()

        #expect(output.hasUntimedFinalText)
        #expect(output.segments.count == 2)
        #expect(output.untimedFragments.map(\.insertionIndex) == [1])

        let crossBatch = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: "Today slowly unveil.",
                exactPhrase: "Today slowly unveil",
                segments: output.segments,
                localeIdentifier: "en_US",
                hasUntimedFinalText: output.hasUntimedFinalText,
                untimedFragments: output.untimedFragments
            )
        )
        #expect(crossBatch.estimatedWordsPerMinute == nil)
        #expect(crossBatch.observations.isEmpty)
        #expect(crossBatch.ambiguousNotes.contains {
            $0.reason == .incompleteTimingCoverage && $0.offersManualMarking
        })

        let unlocated = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: "Today unveil.",
                exactPhrase: "Today unveil",
                segments: [
                    TimedTranscriptSegment(text: "Today", startTime: 0.5, endTime: 1.0),
                    TimedTranscriptSegment(text: "unveil", startTime: 2.0, endTime: 2.5)
                ],
                localeIdentifier: "en_US",
                hasUntimedFinalText: true
            )
        )
        #expect(unlocated.estimatedWordsPerMinute == nil)
        #expect(unlocated.observations.isEmpty)
        #expect(unlocated.ambiguousNotes.contains {
            $0.reason == .incompleteTimingCoverage && $0.offersManualMarking
        })
    }

    @Test("Finding 1: repeated word inside untimed barrier prevents false unique alignment")
    func repeatedWordInUntimedBarrierPreventsFalseUniqueMatch() {
        var attributed = AttributedString("Lumera ")
        attributed.append(makeTimedWord("Lumera", start: 1.5, end: 2.0))

        let extracted = SpeechResultSegmentExtractor.extract(
            from: attributed,
            isFinal: true,
            localeIdentifier: "en_US"
        )
        let result = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: "Lumera",
                exactPhrase: "Lumera",
                segments: extracted.segments,
                localeIdentifier: "en_US",
                hasUntimedFinalText: extracted.hasUntimedFinalText,
                untimedFragments: extracted.untimedFragments
            )
        )
        #expect(result.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
        #expect(result.ambiguousNotes.contains { $0.reason == .repeatedPhrase && $0.offersManualMarking })
    }

    // MARK: - Finding (2): Dropped/invalid finalized words, out-of-bounds, overlaps, and coarse ranges

    @Test("Finding 2: out-of-bounds trailing word on 4s take suppresses 2-word 30 WPM estimate")
    func outOfBoundsTrailingWordSuppressesPartialWPM() {
        let input = TimingAnalysisInput(
            attemptID: UUID(),
            talkRevisionID: UUID(),
            sectionRevisionID: UUID(),
            elapsedAudioDuration: 4.0,
            scriptText: "Today we unveil. [hold for demo]",
            exactPhrase: "Today we unveil",
            segments: [
                TimedTranscriptSegment(text: "Today", startTime: 0.5, endTime: 1.0, isFinal: true),
                TimedTranscriptSegment(text: "we", startTime: 1.1, endTime: 1.4, isFinal: true),
                TimedTranscriptSegment(text: "unveil", startTime: 3.5, endTime: 4.35, isFinal: true)
            ],
            localeIdentifier: "en_US"
        )

        let result = TimingObservationsEngine.analyze(input)
        #expect(result.estimatedWordsPerMinute == nil)
        #expect(result.hasUntimedFinalText)
        #expect(result.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
        #expect(!result.ambiguousNotes.contains { $0.reason == .stageDirectionSilence })
        #expect(result.ambiguousNotes.contains {
            $0.reason == .incompleteTimingCoverage && $0.offersManualMarking
        })
    }

    @Test("Finding 2: real extractor records invalid CMTimeRange runs as ordered barriers")
    func realExtractorRecordsInvalidCMTimeRangesAsBarriers() {
        let badRanges: [CMTimeRange] = [
            CMTimeRange(start: .indefinite, duration: CMTime(seconds: 0.5, preferredTimescale: 600)),
            CMTimeRange(
                start: CMTime(seconds: -0.3, preferredTimescale: 600),
                duration: CMTime(seconds: 0.5, preferredTimescale: 600)
            ),
            CMTimeRange(
                start: CMTime(seconds: 1.5, preferredTimescale: 600),
                duration: CMTime(seconds: -0.4, preferredTimescale: 600)
            ),
            CMTimeRange(start: CMTime(seconds: 1.5, preferredTimescale: 600), duration: .zero)
        ]

        for badRange in badRanges {
            var attributed = makeTimedWord("Today ", start: 0.5, end: 1.0)
            var badWord = AttributedString("slowly ")
            badWord.audioTimeRange = badRange
            attributed.append(badWord)
            attributed.append(makeTimedWord("unveil", start: 2.0, end: 2.5))

            let extracted = SpeechResultSegmentExtractor.extract(
                from: attributed,
                isFinal: true,
                localeIdentifier: "en_US"
            )
            #expect(extracted.hasUntimedFinalText)
            #expect(extracted.segments.map(\.text) == ["Today", "unveil"])
            #expect(extracted.untimedFragments.map(\.text) == ["slowly"])
            #expect(extracted.untimedFragments.map(\.insertionIndex) == [1])
        }
    }

    @Test("Finding 2: invalid NaN, reversed, negative, and out-of-bounds interior words break contiguity and gaps")
    func invalidInteriorWordsBreakContiguityGapsAndWPM() {
        let invalidSegments: [TimedTranscriptSegment] = [
            TimedTranscriptSegment(text: "slowly", startTime: .nan, endTime: 1.5, isFinal: true),
            TimedTranscriptSegment(text: "slowly", startTime: 1.8, endTime: 1.2, isFinal: true),
            TimedTranscriptSegment(text: "slowly", startTime: -0.4, endTime: 0.2, isFinal: true),
            TimedTranscriptSegment(text: "slowly", startTime: 4.5, endTime: 5.0, isFinal: true)
        ]

        for badSegment in invalidSegments {
            let result = TimingObservationsEngine.analyze(
                TimingAnalysisInput(
                    attemptID: UUID(),
                    talkRevisionID: UUID(),
                    sectionRevisionID: UUID(),
                    elapsedAudioDuration: 4.0,
                    scriptText: "Today unveil.",
                    exactPhrase: "Today unveil",
                    segments: [
                        TimedTranscriptSegment(text: "Today", startTime: 0.5, endTime: 1.0, isFinal: true),
                        badSegment,
                        TimedTranscriptSegment(text: "unveil", startTime: 2.0, endTime: 2.5, isFinal: true)
                    ],
                    localeIdentifier: "en_US"
                )
            )
            #expect(result.estimatedWordsPerMinute == nil)
            #expect(result.hasUntimedFinalText)
            #expect(result.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
            #expect(result.observations.filter { $0.kind == .phraseGap }.isEmpty)
            #expect(result.ambiguousNotes.contains {
                $0.reason == .incompleteTimingCoverage && $0.offersManualMarking
            })
        }
    }

    @Test("Finding 2: coarse multi-word timing and all-invalid speech suppress WPM with manual fallback")
    func coarseAndAllInvalidTimingSuppressWPMWithManualFallback() {
        let coarse = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: "Today we unveil Lumera.",
                exactPhrase: "Today we unveil Lumera.",
                segments: [
                    TimedTranscriptSegment(text: "Today we", startTime: 0.4, endTime: 1.2, isFinal: true),
                    TimedTranscriptSegment(text: "unveil Lumera.", startTime: 1.4, endTime: 2.4, isFinal: true)
                ],
                localeIdentifier: "en_US"
            )
        )
        #expect(coarse.timingGranularity == .phraseLevel)
        #expect(coarse.estimatedWordsPerMinute == nil)
        #expect(coarse.ambiguousNotes.contains {
            $0.reason == .incompleteTimingCoverage && $0.offersManualMarking
        })

        let allInvalid = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: "Today we unveil.",
                segments: [
                    TimedTranscriptSegment(text: "Today", startTime: 3.5, endTime: 4.4, isFinal: true)
                ],
                localeIdentifier: "en_US"
            )
        )
        #expect(allInvalid.recognizedWordCount == 0)
        #expect(allInvalid.estimatedWordsPerMinute == nil)
        #expect(allInvalid.hasUntimedFinalText)
        #expect(allInvalid.ambiguousNotes.contains {
            $0.reason == .incompleteTimingCoverage && $0.offersManualMarking
        })
    }
}

private extension Task5ReviewRegressionTests {
    func makeTimedWord(_ text: String, start: TimeInterval, end: TimeInterval) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        return attributed
    }
}
