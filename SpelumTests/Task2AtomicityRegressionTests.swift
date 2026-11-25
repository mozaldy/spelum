import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 2 Atomicity Regressions")
@MainActor
struct Task2AtomicityRegressionTests {
    private struct SeededLibrary {
        let primaryID: UUID
        let secondaryID: UUID
        let primaryRevisionID: UUID
        let firstSectionID: UUID
        let secondSectionID: UUID
    }

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpelumAtomicity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("spelum.sqlite")
    }

    private func removeTemporaryDirectory(for storeURL: URL) {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    private func seedLibrary(at storeURL: URL) throws -> SeededLibrary {
        let container = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let store = PresentationStore(modelContext: container.mainContext)

        let secondary = try store.importScript(
            text: "Other talk opening line.\nOther talk closing line.",
            title: "Other Talk"
        )
        let primary = try store.importScript(
            text: "Line one from Alex.\nSecond Alex line.\nLine two from Jordan.",
            title: "Primary Talk"
        )
        let initial = try #require(store.orderedSections(for: primary).first)
        let splitRange = try #require(initial.text.range(of: "Line two"))
        let split = try store.splitSection(
            in: primary,
            sectionID: initial.sectionID,
            at: splitRange.lowerBound
        )
        let primaryRevID = try #require(primary.currentRevisionID)
        return SeededLibrary(
            primaryID: primary.id,
            secondaryID: secondary.id,
            primaryRevisionID: primaryRevID,
            firstSectionID: split.firstSection.sectionID,
            secondSectionID: split.secondSection.sectionID
        )
    }

    @Test("Failed edit, split, rename, reorder, and section delete on read-only store stay atomic")
    func readOnlyEditSplitRenameReorderDeleteSectionAreAtomic() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let seeded = try seedLibrary(at: storeURL)
        let readOnly = try PresentationStore.makeModelContainer(storeURL: storeURL, allowsSave: false)
        let store = PresentationStore(modelContext: readOnly.mainContext)

        let primary = try #require(try store.presentation(withID: seeded.primaryID))
        let originalRevCount = primary.talkRevisions.count
        let originalSectionCount = primary.sectionRevisions.count
        let firstSection = try #require(store.orderedSections(for: primary).first)

        var editedDraft = SectionDraft(record: firstSection)
        editedDraft.text = "Unsaved edited line."
        #expect(throws: Error.self) {
            try store.saveSectionEdit(in: primary, sectionID: seeded.firstSectionID, draft: editedDraft)
        }
        #expect(throws: Error.self) {
            try store.saveSectionEdit(in: primary, sectionID: seeded.firstSectionID, draft: editedDraft)
        }
        let splitIdx = try #require(firstSection.text.range(of: "Second Alex")).lowerBound
        #expect(throws: Error.self) {
            try store.splitSection(in: primary, sectionID: seeded.firstSectionID, at: splitIdx)
        }
        #expect(throws: Error.self) {
            try store.renamePresentation(primary, to: "Corrupted Title")
        }
        #expect(throws: Error.self) {
            try store.reorderSections(in: primary, orderedSectionIDs: [seeded.secondSectionID, seeded.firstSectionID])
        }
        #expect(throws: Error.self) {
            try store.deleteSection(in: primary, sectionID: seeded.secondSectionID)
        }

        #expect(!store.modelContext.hasChanges)
        #expect(primary.title == "Primary Talk")
        #expect(primary.currentRevisionID == seeded.primaryRevisionID)
        #expect(primary.talkRevisions.count == originalRevCount)
        #expect(primary.sectionRevisions.count == originalSectionCount)
        #expect(store.orderedSections(for: primary).map(\.sectionID) == [
            seeded.firstSectionID,
            seeded.secondSectionID
        ])

        let reopened = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let reopenedStore = PresentationStore(modelContext: reopened.mainContext)
        let reopenedPrimary = try #require(try reopenedStore.presentation(withID: seeded.primaryID))
        #expect(reopenedPrimary.title == "Primary Talk")
        #expect(reopenedPrimary.currentRevisionID == seeded.primaryRevisionID)
        #expect(reopenedPrimary.talkRevisions.count == originalRevCount)

        let retried = try reopenedStore.saveSectionEdit(
            in: reopenedPrimary,
            sectionID: seeded.firstSectionID,
            draft: editedDraft
        )
        #expect(retried.revisionNumber == originalRevCount + 1)
        #expect(reopenedPrimary.talkRevisions.count == originalRevCount + 1)
    }

    @Test("Failed import and failed presentation deletion on read-only store preserve library and reopen cleanly")
    func readOnlyImportAndPresentationDeleteAreAtomic() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let seeded = try seedLibrary(at: storeURL)
        let readOnly = try PresentationStore.makeModelContainer(storeURL: storeURL, allowsSave: false)
        let store = PresentationStore(modelContext: readOnly.mainContext)

        let primary = try #require(try store.presentation(withID: seeded.primaryID))
        let originalRevCount = primary.talkRevisions.count

        #expect(throws: Error.self) {
            try store.importScript(text: "Phantom script line.", title: "Phantom Talk")
        }
        #expect(!store.modelContext.hasChanges)
        #expect(try store.fetchPresentations().count == 2)

        #expect(throws: Error.self) {
            try store.deletePresentation(primary)
        }
        #expect(!store.modelContext.hasChanges)

        let remaining = try store.fetchPresentations()
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.id == seeded.primaryID })
        #expect(remaining.contains { $0.id == seeded.secondaryID })
        #expect(primary.talkRevisions.count == originalRevCount)
        #expect(store.orderedSections(for: primary).count == 2)

        let reopened = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let reopenedStore = PresentationStore(modelContext: reopened.mainContext)
        #expect(try reopenedStore.fetchPresentations().count == 2)
        let reopenedPrimary = try #require(try reopenedStore.presentation(withID: seeded.primaryID))
        try reopenedStore.deletePresentation(reopenedPrimary)
        #expect(try reopenedStore.fetchPresentations().map(\.id) == [seeded.secondaryID])
    }

    @Test("Same-context transient save failure rolls back and retries exactly once with no phantom revisions")
    func sameContextTransientSaveFailureRetriesExactlyOnce() throws {
        enum SimulatedDiskError: Error { case transientWriteFailure }

        let storeURL = try makeTemporaryStoreURL()
        defer { removeTemporaryDirectory(for: storeURL) }

        let seeded = try seedLibrary(at: storeURL)
        let container = try PresentationStore.makeModelContainer(storeURL: storeURL)
        var shouldFailSave = true
        let store = PresentationStore(modelContext: container.mainContext) { context in
            if shouldFailSave {
                throw SimulatedDiskError.transientWriteFailure
            }
            try context.save()
        }

        let primary = try #require(try store.presentation(withID: seeded.primaryID))
        let originalRevCount = primary.talkRevisions.count
        let firstSection = try #require(store.orderedSections(for: primary).first)

        var draft = SectionDraft(record: firstSection)
        draft.text = "Committed on first retry."

        // Transient edit failure -> rollback -> single retry succeeds with exact rev N+1
        #expect(throws: SimulatedDiskError.transientWriteFailure) {
            try store.saveSectionEdit(in: primary, sectionID: seeded.firstSectionID, draft: draft)
        }
        #expect(!store.modelContext.hasChanges)
        #expect(primary.currentRevisionID == seeded.primaryRevisionID)
        #expect(primary.talkRevisions.count == originalRevCount)

        // Transient import and delete failures -> rollback -> library untouched
        #expect(throws: SimulatedDiskError.transientWriteFailure) {
            try store.importScript(text: "Transient import text.", title: "Transient Import")
        }
        #expect(throws: SimulatedDiskError.transientWriteFailure) {
            try store.deletePresentation(primary)
        }
        #expect(!store.modelContext.hasChanges)
        #expect(try store.fetchPresentations().count == 2)

        // Clear transient fault and retry edit exactly once on the same store/context
        shouldFailSave = false
        let retried = try store.saveSectionEdit(in: primary, sectionID: seeded.firstSectionID, draft: draft)
        #expect(retried.revisionNumber == originalRevCount + 1)
        #expect(primary.talkRevisions.count == originalRevCount + 1)

        // Reopen database from disk and confirm zero phantom revisions and intact sibling talk
        let reopened = try PresentationStore.makeModelContainer(storeURL: storeURL)
        let reopenedStore = PresentationStore(modelContext: reopened.mainContext)
        let verified = try #require(try reopenedStore.presentation(withID: seeded.primaryID))
        #expect(verified.talkRevisions.count == originalRevCount + 1)
        #expect(reopenedStore.orderedSections(for: verified).first?.text == "Committed on first retry.")
        #expect(try reopenedStore.presentation(withID: seeded.secondaryID)?.title == "Other Talk")
    }
}
