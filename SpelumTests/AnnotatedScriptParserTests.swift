import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Annotated Script Parser & Timing/Handoff Integration")
@MainActor
struct AnnotatedScriptParserTests {
    @Test("Parses multi-section scripts with LF and CRLF line endings while preserving raw source text")
    func multiSectionLFAndCRLFAndVerbatimPreservation() {
        let lfScript = """
        # Opening
        ## Welcome
        Good morning everyone. / Let's begin.
        [Smile and pause for the room]
        ## Context
        Here is what changed this year. //
        # Live Demo
        ## Walkthrough
        Watch this timeline update. ↗
        """
        let crlfScript = lfScript.replacingOccurrences(of: "\n", with: "\r\n")

        let lfParsed = AnnotatedScriptParser.parseDocument(lfScript)
        let crlfParsed = AnnotatedScriptParser.parseDocument(crlfScript)

        #expect(lfParsed.hasStructuredHeadings)
        #expect(lfParsed.sections.count == 2)
        #expect(lfParsed.sections[0].title == "Opening")
        #expect(lfParsed.sections[0].slides.count == 2)
        #expect(lfParsed.sections[1].title == "Live Demo")
        #expect(lfParsed.sections[1].slides.count == 1)
        #expect(lfParsed.explicitSlides.count == 3)

        #expect(crlfParsed.sections.count == lfParsed.sections.count)
        #expect(crlfParsed.explicitSlides.count == lfParsed.explicitSlides.count)
        #expect(crlfParsed.explicitSlides.map(\.displayTitle) == ["Welcome", "Context", "Walkthrough"])
        #expect(crlfParsed.sourceText == crlfScript)
        #expect(crlfParsed.sections[0].rawText.contains("\r\n"))
        #expect(lfParsed.sections[0].slides[0].rawSliceText.contains("## Welcome"))
        #expect(lfParsed.sections[0].slides[0].rawSliceText.contains("[Smile and pause for the room]"))
    }

    @Test("Handles slides without explicit section, leading text (0 pages), empty/repeated titles, and markers")
    func edgeCasesHeadingsPrefixAndAdjacentMarkers() {
        let script = """
        Opening preamble note before any slide heading.

        ##
        ## Repeated Title
        ## Repeated Title
        [Step forward][Click remote]
        Hello /// ↗ world!
        """

        let parsed = AnnotatedScriptParser.parseDocument(script)
        #expect(parsed.sections.count == 1)
        #expect(!parsed.sections[0].isExplicitSection)
        #expect(parsed.sections[0].slides.count == 4)
        #expect(!parsed.sections[0].slides[0].isExplicitSlide)
        #expect(parsed.sections[0].slides[0].explicitSlideIndex == nil)
        #expect(parsed.explicitSlides.count == 3)

        #expect(parsed.explicitSlides[0].displayTitle == "Slide 1")
        #expect(parsed.explicitSlides[1].displayTitle == "Repeated Title")
        #expect(parsed.explicitSlides[2].displayTitle == "Repeated Title")
        #expect(parsed.explicitSlides[1].explicitSlideIndex == 1)
        #expect(parsed.explicitSlides[2].explicitSlideIndex == 2)

        let lastSlide = parsed.explicitSlides[2]
        #expect(lastSlide.stageDirections == ["[Step forward]", "[Click remote]"])
        #expect(lastSlide.spokenLines == ["Hello world!"])
    }

    @Test("Preserves literal hashes, URLs, ordinary slashes, and unmatched brackets while parsing cues")
    func literalHashesURLsOrdinarySlashesAndAnnotations() {
        let line1 = "Our #1 goal in C# is 24/7 speed and/or scale at https://example.com/a/b/c and ./local/path."
        let line2 = "Ready?/ Now!// Wait\u{2026}/// Look, / listen \u{2197} " +
            "carefully \u{2198} up \u{2191} down \u{2193}."
        let line3 = "A stray] closing bracket, empty [], and unmatched [open bracket stay literal."
        let line4 = "### Subheading with three hashes stays ordinary prose."

        let script = [line1, line2, line3, line4].joined(separator: "\n")
        let parsed = AnnotatedScriptParser.parseDocument(script)
        #expect(!parsed.hasStructuredHeadings)
        #expect(parsed.explicitSlides.isEmpty)

        let blocks = parsed.sections[0].slides[0].blocks
        guard case .speech(_, let tokens1, let spoken1) = blocks[0] else {
            Issue.record("Expected speech block for line 1")
            return
        }
        #expect(!tokens1.contains { if case .pause = $0 { return true }; return false })
        #expect(spoken1.contains("https://example.com/a/b/c"))
        #expect(spoken1.contains("24/7"))
        #expect(spoken1.contains("and/or"))
        #expect(spoken1.contains("./local/path"))
        #expect(spoken1.contains("#1"))

        guard case .speech(_, let tokens2, let spoken2) = blocks[1] else {
            Issue.record("Expected speech block for line 2")
            return
        }
        let pauses = tokens2.compactMap { token -> ScriptPauseKind? in
            if case .pause(let kind) = token { return kind }
            return nil
        }
        let pitches = tokens2.compactMap { token -> ScriptPitchDirection? in
            if case .pitch(let direction, _) = token { return direction }
            return nil
        }
        #expect(pauses == [.short, .medium, .long, .short])
        #expect(pitches == [.rising, .falling, .rising, .falling])
        #expect(spoken2 == "Ready? Now! Wait\u{2026} Look, listen carefully up down.")

        let accessible = AnnotatedScriptInlineParser.accessibleDescription(for: tokens2)
        #expect(accessible.contains("(short pause)"))
        #expect(accessible.contains("(medium pause)"))
        #expect(accessible.contains("(long pause)"))
        #expect(accessible.contains("(rising pitch)"))
        #expect(accessible.contains("(falling pitch)"))

        guard case .speech(_, _, let spoken3) = blocks[2] else {
            Issue.record("Expected speech block for line 3")
            return
        }
        #expect(spoken3.contains("[open bracket"))
        #expect(spoken3.contains("stray]"))

        guard case .speech(_, _, let spoken4) = blocks[3] else {
            Issue.record("Expected speech block for line 4")
            return
        }
        #expect(spoken4 == line4)
    }

    @Test("Handoff skips trailing direction and timing analysis excludes headings, pauses, and pitch cues")
    func handoffAndTimingAnalysisIntegration() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let store = PresentationStore(modelContext: container.mainContext)
        let script = """
        # Opening
        ## Intro
        Welcome to the architecture review. /
        Handing over to Jordan now. \u{2198}
        [Step aside and gesture toward the demo desk]
        # Demo
        ## Live Walkthrough
        Thanks Alex, let's look at the live metrics. //
        """

        let presentation = try store.importScript(text: script, title: "Architecture Review")
        let revision = try #require(store.currentTalkRevision(for: presentation))
        let sections = store.orderedSections(in: revision)
        #expect(sections.count == 2)

        try store.saveSectionEdit(
            in: presentation,
            sectionID: sections[1].sectionID,
            draft: SectionDraft(
                title: sections[1].title,
                text: sections[1].text,
                speaker: "Jordan",
                speakerRole: .teammate,
                purpose: .demonstration,
                cueWords: [],
                exactPhrase: "",
                handoffCueOverride: ""
            )
        )
        let updatedRevision = try #require(store.currentTalkRevision(for: presentation))
        let updatedSections = store.orderedSections(in: updatedRevision)
        let handoff = try #require(
            store.handoffContext(forSectionID: updatedSections[1].sectionID, in: updatedRevision)
        )

        #expect(handoff.derivedFinalLine == "Handing over to Jordan now.")
        #expect(handoff.isSpeakerChange)

        let timingStructure = EnglishWordTokenizer.extractScriptStructure(
            from: updatedSections[0].text
        )
        #expect(!timingStructure.spokenText.contains("## Intro"))
        #expect(!timingStructure.spokenText.contains("[Step aside"))
        #expect(!timingStructure.spokenText.contains("/"))
        #expect(!timingStructure.spokenText.contains("\u{2198}"))
        #expect(timingStructure.spokenText.contains("Welcome to the architecture review."))
        #expect(timingStructure.spokenText.contains("Handing over to Jordan now."))
        #expect(timingStructure.stageDirections == ["[Step aside and gesture toward the demo desk]"])
        #expect(timingStructure.hasTrailingStageDirection)
        #expect(!timingStructure.hasInteriorStageDirection)
    }

    @Test("Default title and snippet helpers use parsed headings and clean spoken lines")
    func scriptTextHelpersUseParsedAnnotations() {
        let script = """
        # Keynote Opening
        ## Slide One
        [Take a breath]
        Today we launch / something new \u{2197}.
        """
        #expect(PresentationStore.defaultTitle(fromText: script) == "Keynote Opening")
        let snippet = PresentationStore.displaySnippet(for: script)
        #expect(snippet == "Today we launch something new.")
    }
}
