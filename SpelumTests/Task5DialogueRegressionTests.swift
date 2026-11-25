import Foundation
import Testing
@testable import Spelum

@Suite("Task 5 Review Regressions — Parenthetical Dialogue, Colons, and Metadata")
@MainActor
struct Task5DialogueRegressionTests {
    @Test("Finding 3: ordinary parenthetical dialogue is preserved verbatim in exact phrase, cues, and script")
    func ordinaryParentheticalDialogueIsPreserved() throws {
        let phrase = "Today we unveil Lumera (our fastest model yet) offline."
        let structure = EnglishWordTokenizer.extractScriptStructure(from: phrase)
        #expect(structure.stageDirections.isEmpty)
        #expect(structure.spokenCandidatePhrases == [phrase])

        let spokenSegments: [TimedTranscriptSegment] = [
            TimedTranscriptSegment(text: "Today", startTime: 0.2, endTime: 0.5),
            TimedTranscriptSegment(text: "we", startTime: 0.55, endTime: 0.7),
            TimedTranscriptSegment(text: "unveil", startTime: 0.75, endTime: 1.1),
            TimedTranscriptSegment(text: "Lumera", startTime: 1.15, endTime: 1.6),
            TimedTranscriptSegment(text: "our", startTime: 1.65, endTime: 1.85),
            TimedTranscriptSegment(text: "fastest", startTime: 1.9, endTime: 2.3),
            TimedTranscriptSegment(text: "model", startTime: 2.35, endTime: 2.7),
            TimedTranscriptSegment(text: "yet", startTime: 2.75, endTime: 3.0),
            TimedTranscriptSegment(text: "offline.", startTime: 3.05, endTime: 3.5)
        ]

        let result = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 5.0,
                scriptText: phrase,
                exactPhrase: phrase,
                cueWords: ["(our fastest model yet)"],
                segments: spokenSegments,
                localeIdentifier: "en_US"
            )
        )
        let exactMatch = try #require(result.observations.first { $0.kind == .alignedExactPhrase })
        #expect(exactMatch.matchedPhrase == phrase)
        #expect(abs(exactMatch.startTime - 0.2) < 0.001)
        #expect(abs(exactMatch.endTime - 3.5) < 0.001)

        let cueMatch = try #require(result.observations.first { $0.kind == .alignedCuePhrase })
        #expect(cueMatch.matchedPhrase == "(our fastest model yet)")
        #expect(abs(cueMatch.startTime - 1.65) < 0.001)
        #expect(abs(cueMatch.endTime - 3.0) < 0.001)

        // Skipping parenthetical words must NOT match the exact phrase
        let skippedResult = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 5.0,
                scriptText: phrase,
                exactPhrase: phrase,
                segments: Array(spokenSegments.prefix(4)) + [
                    TimedTranscriptSegment(text: "offline.", startTime: 1.7, endTime: 2.2)
                ],
                localeIdentifier: "en_US"
            )
        )
        #expect(skippedResult.observations.filter { $0.kind == .alignedExactPhrase }.isEmpty)
    }

    @Test("Finding 3: rhetorical colons are preserved verbatim while real speaker metadata is distinguished")
    func rhetoricalColonsPreservedAndMetadataSpeakersDistinguished() throws {
        let sentence = "One more thing: today we unveil Lumera."
        let segments: [TimedTranscriptSegment] = [
            TimedTranscriptSegment(text: "One", startTime: 0.3, endTime: 0.55),
            TimedTranscriptSegment(text: "more", startTime: 0.6, endTime: 0.85),
            TimedTranscriptSegment(text: "thing", startTime: 0.9, endTime: 1.2),
            TimedTranscriptSegment(text: "today", startTime: 1.3, endTime: 1.65),
            TimedTranscriptSegment(text: "we", startTime: 1.7, endTime: 1.85),
            TimedTranscriptSegment(text: "unveil", startTime: 1.9, endTime: 2.3),
            TimedTranscriptSegment(text: "Lumera.", startTime: 2.35, endTime: 2.8)
        ]

        // 1. Preserved in fallback script alignment
        let fallback = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: sentence,
                knownSpeakerNames: ["Jordan"],
                segments: segments,
                localeIdentifier: "en_US"
            )
        )
        let alignedScript = try #require(fallback.observations.first { $0.kind == .alignedScriptPhrase })
        #expect(alignedScript.matchedPhrase == sentence)
        #expect(abs(alignedScript.startTime - 0.3) < 0.001)
        #expect(abs(alignedScript.endTime - 2.8) < 0.001)

        // 2. Preserved in explicit exactPhrase and cueWords
        let explicit = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: UUID(),
                talkRevisionID: UUID(),
                sectionRevisionID: UUID(),
                elapsedAudioDuration: 4.0,
                scriptText: sentence,
                exactPhrase: sentence,
                cueWords: ["One more thing: today"],
                knownSpeakerNames: ["Jordan"],
                segments: segments,
                localeIdentifier: "en_US"
            )
        )
        let exact = try #require(explicit.observations.first { $0.kind == .alignedExactPhrase })
        #expect(exact.matchedPhrase == sentence)
        let cue = try #require(explicit.observations.first { $0.kind == .alignedCuePhrase })
        #expect(cue.matchedPhrase == "One more thing: today")

        // 3. Real assigned speaker metadata strips only known speakers and preserves inner rhetorical colons
        let multiSpeaker = EnglishWordTokenizer.extractScriptStructure(
            from: "Alex: Passing it over to you.\nJordan: One more thing: today we unveil Lumera.",
            knownSpeakerNames: ["Alex", "Jordan"]
        )
        #expect(multiSpeaker.spokenCandidatePhrases == [
            "Passing it over to you.",
            "One more thing: today we unveil Lumera."
        ])
    }

    @Test("Finding 3: explicit bracketed stage directions remain distinguished from spoken text")
    func explicitBracketedStageDirectionsAreSeparatedConservatively() {
        let structure = EnglishWordTokenizer.extractScriptStructure(
            from: "Today we unveil Lumera (our fastest model yet). [pause for demo] Notice how fast it is.",
            knownSpeakerNames: ["Jordan"]
        )
        #expect(structure.stageDirections == ["[pause for demo]"])
        #expect(structure.hasInteriorStageDirection)
        #expect(!structure.hasTrailingStageDirection)
        #expect(structure.spokenCandidatePhrases == [
            "Today we unveil Lumera (our fastest model yet).",
            "Notice how fast it is."
        ])
    }
}
