import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Annotated Slide Rehearsal Navigation & Revision Immutability")
@MainActor
struct AnnotatedSlideRehearsalTests {
    static let syntheticRehearsalScript = """
    # Opening Narrative
    ## Title Slide
    Welcome to the Spelum rehearsal showcase. / Let's set the stage. \u{2197}
    [Pause and make eye contact with the front row]
    ## Visual Transition
    [Click remote to reveal the benchmark chart and hold two seconds]
    ## Handoff Setup
    That sets up the live walkthrough with Jordan. // \u{2198}
    # Live Demo
    ## Interactive Overview
    Thanks Alex. / Watch the controls respond in real time.
    ## Extended Walkthrough
    First we verify the pacing indicator. /
    Next we check that the pinned slide artwork stays visible while longer notes scroll smoothly underneath. //
    [Point to the lower telemetry panel]
    Finally we close with a crisp summary takeaway. /// \u{2198}
    """

    struct SeededSlideTalk {
        let presentation: PresentationRecord
        let revision: TalkRevisionRecord
        let sections: [SectionRevisionRecord]
        let snapshot: FullRunSnapshot
        let deckURL: URL
    }

    @Test("Idle full run moves slide and text together across section boundaries in both directions")
    func idleFullRunBoundaryNavigationBothDirections() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlideIdleNav")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let seeded = try Self.seedTwoSectionFiveSlideTalk(in: library, workspace: workspace)

        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: seeded.snapshot,
            initialMode: .fullScript,
            recorder: SteppableFullRunRecorder()
        )

        #expect(session.currentFullRunSectionIndex == 0)
        #expect(session.currentFullRunSlide?.pdfPageIndex == 0)
        #expect(!session.canRetreatFullRunStep)

        #expect(session.advanceFullRunStep())
        #expect(session.currentFullRunSlide?.pdfPageIndex == 1)
        #expect(session.currentFullRunSlide?.hasOnlyDirectionsOrNoSpeech == true)

        #expect(session.advanceFullRunStep())
        #expect(session.currentFullRunSlide?.pdfPageIndex == 2)

        // Crossing into Section 2 updates section, speaker, text, and slide artwork page 3 together.
        #expect(session.advanceFullRunStep())
        #expect(session.currentFullRunSectionIndex == 1)
        #expect(session.currentFullRunSlideIndex == 0)
        #expect(session.currentFullRunSection?.speaker == "Jordan")
        #expect(session.currentFullRunSlide?.pdfPageIndex == 3)

        #expect(session.advanceFullRunStep())
        #expect(session.currentFullRunSlide?.pdfPageIndex == 4)
        #expect(!session.canAdvanceFullRunStep)

        // Retreat back across section boundary into Section 1 Slide 3 (page 2).
        #expect(session.retreatFullRunStep())
        #expect(session.currentFullRunSlide?.pdfPageIndex == 3)
        #expect(session.retreatFullRunStep())
        #expect(session.currentFullRunSectionIndex == 0)
        #expect(session.currentFullRunSlideIndex == 2)
        #expect(session.currentFullRunSlide?.pdfPageIndex == 2)
    }

    @Test("Active full run keeps timeline coherent, preserves fullscreen state, and reopens after edits")
    func activeFullRunTimelineFullscreenAndReopenAfterEdits() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlideActiveNav")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let seeded = try Self.seedTwoSectionFiveSlideTalk(in: library, workspace: workspace)

        let session = FullRunTestFixtures.makeSession(
            attemptStore: attemptStore,
            snapshot: seeded.snapshot,
            initialMode: .fullScript,
            recorder: SteppableFullRunRecorder()
        )

        session.startSilentRecall()
        #expect(session.fullRunTransitions.count == 1)

        // Advancing within Section 1 does not add spurious section transitions.
        #expect(session.advanceFullRunStep())
        #expect(session.currentFullRunSlideIndex == 1)
        #expect(session.fullRunTransitions.count == 1)

        // Toggling fullscreen renders identical session state without resetting section or slide index.
        let stage = FullRunFullscreenStageView(
            session: session,
            snapshot: seeded.snapshot,
            isAccessibilitySize: false,
            onExitFullscreen: {}
        )
        _ = RehearsalAccessibilityInspector.collectStrings(from: stage)
        #expect(session.currentFullRunSectionIndex == 0)
        #expect(session.currentFullRunSlideIndex == 1)

        #expect(session.advanceFullRunStep())
        #expect(session.fullRunTransitions.count == 1)

        // Crossing into Section 2 records the second section transition cleanly.
        #expect(session.advanceFullRunStep())
        #expect(session.currentFullRunSectionIndex == 1)
        #expect(session.currentFullRunSlideIndex == 0)
        #expect(session.fullRunTransitions.count == 2)
        #expect(!session.canRetreatFullRunStep)

        #expect(session.advanceFullRunStep())
        #expect(session.canRetreatFullRunStep)
        #expect(session.retreatFullRunStep())
        let finishedAttempt = try #require(session.finishFullRunEarly())

        // Rewrite Section 1 without slides; reopening old take still shows snapshotted slides.
        let sec1 = seeded.sections[0]
        try library.saveSectionEdit(
            in: seeded.presentation,
            sectionID: sec1.sectionID,
            draft: SectionDraft(
                title: "Rewritten",
                text: "Brand new single-paragraph talk without slides.",
                speaker: sec1.speaker,
                speakerRole: sec1.speakerRole,
                purpose: sec1.purpose,
                cueWords: [],
                exactPhrase: "",
                handoffCueOverride: ""
            )
        )
        let savedAttempt = try #require(try attemptStore.attempt(withID: finishedAttempt.id))
        let payload = try #require(savedAttempt.fullRunPayload)
        #expect(payload.snapshot.sections[0].resolvedSlideReferences.map(\.pdfPageIndex) == [0, 1, 2])
        #expect(payload.snapshot.sections[1].resolvedSlideReferences.map(\.pdfPageIndex) == [3, 4])
    }

    static func seedTwoSectionFiveSlideTalk(
        in library: PresentationStore,
        workspace: PracticeTestWorkspace
    ) throws -> SeededSlideTalk {
        let pdfURL = workspace.storageRoot.appendingPathComponent("synthetic-five-slides.pdf")
        try SyntheticPDFTestHelper.writeMultiPagePDF(
            to: pdfURL,
            pageTitles: [
                "Title Slide",
                "Visual Transition",
                "Handoff Setup",
                "Interactive Overview",
                "Extended Walkthrough"
            ]
        )

        let presentation = try library.importScript(
            text: syntheticRehearsalScript,
            title: "Annotated Slide Showcase",
            pdfFileURL: pdfURL
        )
        let rev1 = try #require(library.currentTalkRevision(for: presentation))
        let sections = library.orderedSections(in: rev1)
        #expect(sections.count == 2)

        try applyTestMetadata(to: presentation, sections: sections, in: library)

        let finalRev = try #require(library.currentTalkRevision(for: presentation))
        let finalSections = library.orderedSections(in: finalRev)
        let snapshot = try #require(
            library.makeFullRunSnapshot(
                for: presentation,
                talkRevision: finalRev,
                startKind: .entireTalk
            )
        )
        let deckURL = try #require(library.resolvedDeckURL(for: finalRev.slideDeckRelativePath))
        return SeededSlideTalk(
            presentation: presentation,
            revision: finalRev,
            sections: finalSections,
            snapshot: snapshot,
            deckURL: deckURL
        )
    }

    private static func applyTestMetadata(
        to presentation: PresentationRecord,
        sections: [SectionRevisionRecord],
        in library: PresentationStore
    ) throws {
        try library.saveSectionEdit(
            in: presentation,
            sectionID: sections[0].sectionID,
            draft: SectionDraft(
                title: sections[0].title,
                text: sections[0].text,
                speaker: "Alex",
                speakerRole: .presenter,
                purpose: .story,
                cueWords: ["Roadmap Hook"],
                exactPhrase: "Set the stage",
                handoffCueOverride: ""
            )
        )
        let rev2 = try #require(library.currentTalkRevision(for: presentation))
        let rev2Sections = library.orderedSections(in: rev2)
        try library.saveSectionEdit(
            in: presentation,
            sectionID: rev2Sections[1].sectionID,
            draft: SectionDraft(
                title: rev2Sections[1].title,
                text: rev2Sections[1].text,
                speaker: "Jordan",
                speakerRole: .teammate,
                purpose: .demonstration,
                cueWords: ["Live Controls"],
                exactPhrase: "",
                handoffCueOverride: ""
            )
        )
    }
}

@Suite("Enlarged Slide Sheet Title Formatting")
@MainActor
struct EnlargedSlideSheetTitleTests {
    @Test("Enlarged slide sheet avoids repeating slide-number prefixes")
    func enlargedSlideSheetAvoidsRepeatingSlidePrefix() {
        #expect(
            EnlargedSlideSheet.resolvedSheetTitle(
                slideNumber: 1,
                totalSlides: 3,
                pageIndex: 0,
                visibleSlideTitle: "Reliable Rehearsal"
            ) == "Slide 1: Reliable Rehearsal"
        )
        #expect(
            EnlargedSlideSheet.resolvedSheetTitle(
                slideNumber: 1,
                totalSlides: 3,
                pageIndex: 0,
                visibleSlideTitle: "Slide 1: Reliable Rehearsal"
            ) == "Slide 1: Reliable Rehearsal"
        )
        #expect(
            EnlargedSlideSheet.resolvedSheetTitle(
                slideNumber: 1,
                totalSlides: 3,
                pageIndex: 0,
                visibleSlideTitle: "Slide 1"
            ) == "Slide 1"
        )
        #expect(
            EnlargedSlideSheet.resolvedSheetTitle(
                slideNumber: 2,
                totalSlides: 3,
                pageIndex: 1,
                visibleSlideTitle: "slide 2 — Core Problem"
            ) == "slide 2 — Core Problem"
        )
        #expect(
            EnlargedSlideSheet.resolvedSheetTitle(
                slideNumber: 1,
                totalSlides: 1,
                pageIndex: 2,
                visibleSlideTitle: "Slide 3: On-Device Flow"
            ) == "Slide 3: On-Device Flow"
        )
        #expect(
            EnlargedSlideSheet.resolvedSheetTitle(
                slideNumber: 1,
                totalSlides: 3,
                pageIndex: 0,
                visibleSlideTitle: "Slides Overview"
            ) == "Slide 1: Slides Overview"
        )
        #expect(
            EnlargedSlideSheet.resolvedSheetTitle(
                slideNumber: 1,
                totalSlides: 2,
                pageIndex: 0,
                visibleSlideTitle: nil
            ) == "Slide 1 of 2 · Page 1"
        )
    }
}
