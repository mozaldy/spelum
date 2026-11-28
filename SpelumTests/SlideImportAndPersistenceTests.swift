import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Slide Import, Pairing Preview & Revision-Safe Persistence")
@MainActor
struct SlideImportAndPersistenceTests {
    static let multiSectionAnnotatedScript = """
    Preamble notes before the first slide heading (consumes 0 PDF pages).

    # Opening
    ## Title Card
    Welcome everyone. / Today we walk through the roadmap.
    ## Transition Graphic
    [Click to reveal the comparison diagram]
    ## Core Problem
    Teams lose time when visuals and notes drift apart. //
    # Product Walkthrough
    ## Live Demo
    Watch how slide and cues stay locked together. \u{2197}
    ## Summary
    One deck, one script, zero drift. \u{2198}
    """

    @Test("Script-only import creates structured sections and slide headings without requiring a PDF")
    func scriptOnlyStructuredImport() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlideScriptOnly")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        let presentation = try store.importScript(text: Self.multiSectionAnnotatedScript, title: "Script Only Talk")
        let revision = try #require(store.currentTalkRevision(for: presentation))
        #expect(revision.slideDeckRelativePath == nil)
        #expect(revision.slideDeckPageCount == nil)

        let sections = store.orderedSections(in: revision)
        #expect(sections.count == 3)
        #expect(sections[0].slideReferences.isEmpty)
        #expect(sections[1].title == "Opening")
        #expect(sections[1].slideReferences.count == 3)
        #expect(sections[1].slideReferences.allSatisfy { $0.pdfPageIndex == nil })
        #expect(sections[2].title == "Product Walkthrough")
        #expect(sections[2].slideReferences.count == 2)
        #expect(sections[2].slideReferences.allSatisfy { $0.pdfPageIndex == nil })
    }

    @Test("PDF order pairing previews mismatches, allows correction, and enforces 1:1 pairing")
    func pairingPreviewMismatchCorrectionAndEnforcement() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlidePairing")
        defer { workspace.cleanup() }

        let fourPagePDF = workspace.storageRoot.appendingPathComponent("four-pages.pdf")
        try SyntheticPDFTestHelper.writeMultiPagePDF(to: fourPagePDF, pageTitles: ["1", "2", "3", "4"])
        let fivePagePDF = workspace.storageRoot.appendingPathComponent("five-pages.pdf")
        try SyntheticPDFTestHelper.writeMultiPagePDF(
            to: fivePagePDF,
            pageTitles: ["Title", "Diagram", "Problem", "Demo", "Summary"]
        )

        assertMismatchAndCorrectionPlans()

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        #expect(throws: PresentationImportError.slideCountMismatch(headings: 5, pages: 4)) {
            try store.importScript(
                text: Self.multiSectionAnnotatedScript,
                title: "Mismatch Talk",
                pdfFileURL: fourPagePDF
            )
        }
        #expect(try store.fetchPresentations().isEmpty)
        let decksDir = workspace.storageRoot.appendingPathComponent("Decks", isDirectory: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: decksDir.path)) ?? []).isEmpty)

        let presentation = try store.importScript(
            text: Self.multiSectionAnnotatedScript,
            title: "Matched Talk",
            pdfFileURL: fivePagePDF
        )
        let revision = try #require(store.currentTalkRevision(for: presentation))
        #expect(revision.slideDeckPageCount == 5)
        let sections = store.orderedSections(in: revision)
        #expect(sections.count == 3)
        #expect(sections[0].slideReferences.isEmpty)
        #expect(sections[1].slideReferences.map(\.pdfPageIndex) == [0, 1, 2])
        #expect(sections[2].slideReferences.map(\.pdfPageIndex) == [3, 4])
    }

    @Test("Corrupt, empty, locked PDFs and save failures never create partial talks or leak deck files")
    func invalidPDFsAndAtomicSaveRollback() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlideFailures")
        defer { workspace.cleanup() }

        let corruptURL = workspace.storageRoot.appendingPathComponent("corrupt.pdf")
        let emptyURL = workspace.storageRoot.appendingPathComponent("empty.pdf")
        let lockedURL = workspace.storageRoot.appendingPathComponent("locked.pdf")
        let validURL = workspace.storageRoot.appendingPathComponent("valid.pdf")
        try SyntheticPDFTestHelper.writeCorruptPDF(to: corruptURL)
        try SyntheticPDFTestHelper.writeEmptyPDF(to: emptyURL)
        try SyntheticPDFTestHelper.writeLockedPDF(to: lockedURL, pageCount: 2)
        try SyntheticPDFTestHelper.writeMultiPagePDF(to: validURL, pageTitles: ["A", "B"])

        let twoSlideScript = "## Slide A\nHello.\n## Slide B\nGoodbye."
        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        #expect(throws: PresentationImportError.unreadableOrCorruptPDF) {
            try store.importScript(text: twoSlideScript, pdfFileURL: corruptURL)
        }
        #expect(throws: PresentationImportError.emptyPDF) {
            try store.importScript(text: twoSlideScript, pdfFileURL: emptyURL)
        }
        #expect(throws: PresentationImportError.lockedPDF) {
            try store.importScript(text: twoSlideScript, pdfFileURL: lockedURL)
        }
        #expect(try store.fetchPresentations().isEmpty)

        struct SimulatedSaveFailure: Error {}
        let failingStore = PresentationStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { _ in throw SimulatedSaveFailure() }
        )
        #expect(throws: SimulatedSaveFailure.self) {
            try failingStore.importScript(text: twoSlideScript, pdfFileURL: validURL)
        }
        let decksDir = workspace.storageRoot.appendingPathComponent("Decks", isDirectory: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: decksDir.path)) ?? []).isEmpty)
        #expect(try store.fetchPresentations().isEmpty)
    }

    @Test("App-owned PDF survives source deletion and relaunch; edits, splits, reorders, and deletion stay safe")
    func relaunchRevisionSafetyAndCleanup() async throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlideLifecycle")
        defer { workspace.cleanup() }

        let sourcePDF = workspace.storageRoot.appendingPathComponent("external-source.pdf")
        try SyntheticPDFTestHelper.writeMultiPagePDF(
            to: sourcePDF,
            pageTitles: ["Title", "Diagram", "Problem", "Demo", "Summary"]
        )

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let presentation = try store.importScript(
            text: Self.multiSectionAnnotatedScript,
            title: "Durable Deck Talk",
            pdfFileURL: sourcePDF
        )
        let rev1 = try #require(store.currentTalkRevision(for: presentation))
        let deckRelativePath = try #require(rev1.slideDeckRelativePath)
        #expect(deckRelativePath.hasPrefix("Decks/"))
        #expect(deckRelativePath.hasSuffix(".pdf"))
        try FileManager.default.removeItem(at: sourcePDF)

        let reopenedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let reopenedStore = PresentationStore(
            modelContext: reopenedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let reopenedTalk = try #require(try reopenedStore.presentation(withID: presentation.id))
        let reopenedRev1 = try #require(reopenedStore.currentTalkRevision(for: reopenedTalk))
        let resolvedURL = try #require(reopenedStore.resolvedDeckURL(for: reopenedRev1.slideDeckRelativePath))
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))

        let renderer = SlideDeckRenderer(countLimit: 2, totalCostLimit: 4 * 1024 * 1024)
        #expect(await renderer.renderPage(url: resolvedURL, pageIndex: 0, maxPixelDimension: 480) != nil)

        try verifyEditSplitReorderAndDelete(
            talk: reopenedTalk,
            rev1: reopenedRev1,
            store: reopenedStore,
            resolvedDeckURL: resolvedURL
        )
    }
}

private extension SlideImportAndPersistenceTests {
    func assertMismatchAndCorrectionPlans() {
        let mismatch = SlidePairingPlan.build(
            scriptText: Self.multiSectionAnnotatedScript,
            pdfPageCount: 4,
            pdfAspectRatios: Array(repeating: 16.0 / 9.0, count: 4)
        )
        #expect(mismatch.hasMismatch)
        #expect(!mismatch.isValidForImport)
        #expect(mismatch.explicitHeadingCount == 5)
        #expect(mismatch.pairedCount == 4)
        #expect(mismatch.unmatchedHeadingCount == 1)
        #expect(mismatch.rows.last?.status == .unmatchedHeading)
        #expect(mismatch.rows[1].hasOnlyDirectionsOrNoSpeech)

        let matched = SlidePairingPlan.build(
            scriptText: Self.multiSectionAnnotatedScript,
            pdfPageCount: 5,
            pdfAspectRatios: Array(repeating: 16.0 / 9.0, count: 5)
        )
        #expect(matched.isValidForImport)
        #expect(matched.rows.allSatisfy { $0.status == .paired })

        let scriptOnly = SlidePairingPlan.build(
            scriptText: Self.multiSectionAnnotatedScript,
            pdfPageCount: nil
        )
        #expect(scriptOnly.isValidForImport)
        #expect(!scriptOnly.hasPDF)
    }

    func verifyEditSplitReorderAndDelete(
        talk: PresentationRecord,
        rev1: TalkRevisionRecord,
        store: PresentationStore,
        resolvedDeckURL: URL
    ) throws {
        let rev1Sections = store.orderedSections(in: rev1)
        #expect(rev1Sections.count == 3)
        let sec1 = rev1Sections[1]
        let editedText = """
        ## Title Card
        Updated welcome.
        ## Transition Graphic
        [Updated cue]
        ## Core Problem
        Updated problem.
        """
        try store.saveSectionEdit(
            in: talk,
            sectionID: sec1.sectionID,
            draft: SectionDraft(
                title: "Opening Edited",
                text: editedText,
                speaker: sec1.speaker,
                speakerRole: sec1.speakerRole,
                purpose: sec1.purpose,
                cueWords: sec1.cueWords,
                exactPhrase: sec1.exactPhrase ?? "",
                handoffCueOverride: sec1.handoffCueOverride ?? ""
            )
        )
        let rev2 = try #require(store.currentTalkRevision(for: talk))
        let rev2Sections = store.orderedSections(in: rev2)
        #expect(rev2Sections[1].slideReferences.map(\.pdfPageIndex) == [0, 1, 2])
        #expect(rev1Sections[1].title == "Opening")

        let splitIdx = try #require(rev2Sections[1].text.range(of: "## Core Problem")?.lowerBound)
        try store.splitSection(in: talk, sectionID: rev2Sections[1].sectionID, at: splitIdx)
        let rev3 = try #require(store.currentTalkRevision(for: talk))
        let rev3Sections = store.orderedSections(in: rev3)
        #expect(rev3Sections.count == 4)
        #expect(rev3Sections[0].slideReferences.isEmpty)
        #expect(rev3Sections[1].slideReferences.map(\.pdfPageIndex) == [0, 1])
        #expect(rev3Sections[2].slideReferences.map(\.pdfPageIndex) == [2])
        #expect(rev3Sections[3].slideReferences.map(\.pdfPageIndex) == [3, 4])

        try store.reorderSections(
            in: talk,
            orderedSectionIDs: [
                rev3Sections[3].sectionID,
                rev3Sections[0].sectionID,
                rev3Sections[1].sectionID,
                rev3Sections[2].sectionID
            ]
        )
        let rev4 = try #require(store.currentTalkRevision(for: talk))
        let rev4Sections = store.orderedSections(in: rev4)
        #expect(rev4Sections[0].slideReferences.map(\.pdfPageIndex) == [3, 4])

        try store.deletePresentation(talk)
        #expect(!FileManager.default.fileExists(atPath: resolvedDeckURL.path))
    }
}
