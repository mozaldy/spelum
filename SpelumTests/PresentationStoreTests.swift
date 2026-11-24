import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Presentation Store")
@MainActor
struct PresentationStoreTests {
    private static let twoSpeakerUnicodeScript = """
    Alex: Welcome everyone to our preview.

    We’ve spent months asking — “what if rehearsal felt calm?” ✨

    Jordan: Thanks Alex!
    Today we’re introducing “Spelum” 🚀
    Watch how the live transition lands…
    """

    private struct ImportedSnapshotIDs {
        let presentationID: UUID
        let initialTalkRevisionID: UUID
        let splitTalkRevisionID: UUID
        let editedTalkRevisionID: UUID
        let initialSectionRevisionID: UUID
        let secondSectionID: UUID
        let editedSecondSectionRevisionID: UUID
    }

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpelumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("spelum.sqlite")
    }

    private func removeTemporaryDirectory(for storeURL: URL) {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    private func populateTwoSpeakerPresentation(
        at storeURL: URL
    ) throws -> ImportedSnapshotIDs {
        let scriptURL = storeURL.deletingLastPathComponent().appendingPathComponent("launch-script.txt")
        try #require(Self.twoSpeakerUnicodeScript.data(using: .utf8)).write(to: scriptURL)

        let container = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let store = PresentationStore(modelContext: container.mainContext)

        let presentation = try store.importScript(fromFileURL: scriptURL, title: "Launch Keynote")
        let initialRev = try #require(store.currentTalkRevision(for: presentation))
        let initialSection = try #require(store.orderedSections(in: initialRev).first)
        #expect(presentation.sourceText == Self.twoSpeakerUnicodeScript)
        #expect(initialSection.text == Self.twoSpeakerUnicodeScript)

        let splitTarget = try #require(initialSection.text.range(of: "Jordan:"))
        let split = try store.splitSection(
            in: presentation,
            sectionID: initialSection.sectionID,
            at: splitTarget.lowerBound
        )
        #expect(split.firstSection.text + split.secondSection.text == Self.twoSpeakerUnicodeScript)

        _ = try store.saveSectionEdit(
            in: presentation,
            sectionID: split.firstSection.sectionID,
            draft: SectionDraft(
                title: "Opening Setup",
                text: split.firstSection.text,
                speaker: "Alex",
                speakerRole: .teammate,
                purpose: .story,
                cueWords: ["preview", "calm rehearsal"],
                exactPhrase: "“what if rehearsal felt calm?” ✨",
                handoffCueOverride: nil
            )
        )
        let finalRev = try store.saveSectionEdit(
            in: presentation,
            sectionID: split.secondSection.sectionID,
            draft: SectionDraft(
                title: "Product Reveal",
                text: split.secondSection.text,
                speaker: "Jordan",
                speakerRole: .presenter,
                purpose: .reveal,
                cueWords: ["introducing", "live transition"],
                exactPhrase: "Today we’re introducing “Spelum” 🚀",
                handoffCueOverride: nil
            )
        )
        let finalSecond = try #require(store.orderedSections(in: finalRev).last)

        return ImportedSnapshotIDs(
            presentationID: presentation.id,
            initialTalkRevisionID: initialRev.id,
            splitTalkRevisionID: split.talkRevision.id,
            editedTalkRevisionID: finalRev.id,
            initialSectionRevisionID: initialSection.revisionID,
            secondSectionID: split.secondSection.sectionID,
            editedSecondSectionRevisionID: finalSecond.revisionID
        )
    }

    @Test("Two-speaker UTF-8 script preserves exact Unicode wording across import, split, save, and relaunch")
    func unicodeScriptSurvivesImportSplitSaveAndRelaunch() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let ids = try populateTwoSpeakerPresentation(at: storeURL)

        let reopenedContainer = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let store = PresentationStore(modelContext: reopenedContainer.mainContext)

        let presentation = try #require(try store.presentation(withID: ids.presentationID))
        #expect(presentation.title == "Launch Keynote")
        #expect(presentation.sourceText == Self.twoSpeakerUnicodeScript)
        #expect(presentation.currentRevisionID == ids.editedTalkRevisionID)

        let sections = store.orderedSections(for: presentation)
        #expect(sections.count == 2)
        #expect(sections[0].text + sections[1].text == Self.twoSpeakerUnicodeScript)
        #expect(sections[0].speaker == "Alex")
        #expect(sections[0].speakerRole == .teammate)
        #expect(sections[0].purpose == .story)
        #expect(sections[0].cueWords == ["preview", "calm rehearsal"])
        #expect(sections[0].exactPhrase == "“what if rehearsal felt calm?” ✨")

        #expect(sections[1].sectionID == ids.secondSectionID)
        #expect(sections[1].revisionID == ids.editedSecondSectionRevisionID)
        #expect(sections[1].speaker == "Jordan")
        #expect(sections[1].speakerRole == .presenter)
        #expect(sections[1].purpose == .reveal)
        #expect(sections[1].cueWords == ["introducing", "live transition"])
        #expect(sections[1].exactPhrase == "Today we’re introducing “Spelum” 🚀")

        let earlierRev = try #require(try store.talkRevision(withID: ids.initialTalkRevisionID))
        let earlierSections = store.orderedSections(in: earlierRev)
        #expect(earlierSections.count == 1)
        #expect(earlierSections[0].revisionID == ids.initialSectionRevisionID)
        #expect(earlierSections[0].text == Self.twoSpeakerUnicodeScript)

        let splitRev = try #require(try store.talkRevision(withID: ids.splitTalkRevisionID))
        #expect(store.orderedSections(in: splitRev).count == 2)
        #expect(store.revisionHistory(for: presentation).count == 4)
    }

    @Test("Paste import and Files UTF-8 import use the same import path and produce equivalent sections")
    func pasteAndFilesImportProduceIdenticalContent() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let container = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let store = PresentationStore(modelContext: container.mainContext)

        let fileURL = storeURL.deletingLastPathComponent().appendingPathComponent("pasted.txt")
        try #require(Self.twoSpeakerUnicodeScript.data(using: .utf8)).write(to: fileURL)

        let pasted = try store.importScript(text: Self.twoSpeakerUnicodeScript, title: "Talk")
        let imported = try store.importScript(fromFileURL: fileURL, title: "Talk")

        let pastedSection = try #require(store.orderedSections(for: pasted).first)
        let importedSection = try #require(store.orderedSections(for: imported).first)

        #expect(pasted.sourceText == imported.sourceText)
        #expect(pastedSection.text == importedSection.text)
        #expect(pastedSection.speaker == importedSection.speaker)
        #expect(pastedSection.speakerRole == importedSection.speakerRole)
        #expect(pastedSection.purpose == importedSection.purpose)
    }

    @Test("Empty, whitespace-only, missing, or non-UTF-8 inputs fail and leave previous talk intact")
    func invalidInputsLeavePreviousTalkIntact() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let container = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let store = PresentationStore(modelContext: container.mainContext)

        let existing = try store.importScript(text: Self.twoSpeakerUnicodeScript, title: "Existing Talk")
        let existingRevisionID = try #require(existing.currentRevisionID)

        #expect(throws: PresentationImportError.emptyScript) {
            try store.importScript(text: "", title: "Blank")
        }
        #expect(throws: PresentationImportError.emptyScript) {
            try store.importScript(text: "   \n\t\n  ", title: "Whitespace")
        }

        let missingFile = storeURL.deletingLastPathComponent().appendingPathComponent("does-not-exist.txt")
        #expect(throws: PresentationImportError.unreadableFile) {
            try store.importScript(fromFileURL: missingFile)
        }

        let invalidUTF8File = storeURL.deletingLastPathComponent().appendingPathComponent("invalid.bin")
        try Data([0xFF, 0xFE, 0x80, 0x81]).write(to: invalidUTF8File)
        #expect(throws: PresentationImportError.invalidUTF8) {
            try store.importScript(fromFileURL: invalidUTF8File)
        }

        let presentations = try store.fetchPresentations()
        #expect(presentations.count == 1)
        #expect(presentations[0].id == existing.id)
        #expect(presentations[0].currentRevisionID == existingRevisionID)
        #expect(store.orderedSections(for: presentations[0]).first?.text == Self.twoSpeakerUnicodeScript)
    }

    @Test("Saved edits create immutable revisions while keeping prior revision IDs untouched")
    func savedEditsCreateImmutableRevisions() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let container = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let store = PresentationStore(modelContext: container.mainContext)

        let presentation = try store.importScript(text: "First draft line.\nSecond draft line.", title: "Draft")
        let rev1 = try #require(store.currentTalkRevision(for: presentation))
        let sectionV1 = try #require(store.orderedSections(in: rev1).first)

        let draft = SectionDraft(
            title: "Revised Opening",
            text: "Updated draft line.\nSecond draft line.",
            speaker: "Taylor",
            speakerRole: .presenter,
            purpose: .closing,
            cueWords: ["updated", "close"],
            exactPhrase: "Updated draft line.",
            handoffCueOverride: nil
        )
        let rev2 = try store.saveSectionEdit(in: presentation, sectionID: sectionV1.sectionID, draft: draft)
        let sectionV2 = try #require(store.orderedSections(in: rev2).first)

        #expect(rev2.id != rev1.id)
        #expect(rev2.revisionNumber == 2)
        #expect(sectionV2.sectionID == sectionV1.sectionID)
        #expect(sectionV2.revisionID != sectionV1.revisionID)

        let fetchedRev1 = try #require(try store.talkRevision(withID: rev1.id))
        let fetchedSectionV1 = try #require(try store.sectionRevision(withID: sectionV1.revisionID))
        #expect(fetchedRev1.revisionNumber == 1)
        #expect(fetchedSectionV1.text == "First draft line.\nSecond draft line.")
        #expect(fetchedSectionV1.purpose == .general)
        #expect(fetchedSectionV1.exactPhrase == nil)
    }

    @Test("Invalid split positions and deleting the last section fail without mutating the presentation")
    func invalidSplitAndLastSectionDeleteLeaveTalkIntact() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let container = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let store = PresentationStore(modelContext: container.mainContext)

        let script = "\n   \nOnly paragraph here.\n   \n"
        let presentation = try store.importScript(text: script, title: "Guardrails")
        let initialRevisionID = try #require(presentation.currentRevisionID)
        let section = try #require(store.orderedSections(for: presentation).first)

        #expect(throws: SectionEditError.invalidSplitPosition) {
            try store.splitSection(in: presentation, sectionID: section.sectionID, at: script.startIndex)
        }
        #expect(throws: SectionEditError.invalidSplitPosition) {
            try store.splitSection(in: presentation, sectionID: section.sectionID, at: script.endIndex)
        }
        let whitespaceBoundary = try #require(script.range(of: "Only")).lowerBound
        #expect(throws: SectionEditError.invalidSplitPosition) {
            try store.splitSection(in: presentation, sectionID: section.sectionID, at: whitespaceBoundary)
        }
        #expect(throws: SectionEditError.cannotDeleteLastSection) {
            try store.deleteSection(in: presentation, sectionID: section.sectionID)
        }

        #expect(presentation.currentRevisionID == initialRevisionID)
        #expect(store.revisionHistory(for: presentation).count == 1)
    }
}
