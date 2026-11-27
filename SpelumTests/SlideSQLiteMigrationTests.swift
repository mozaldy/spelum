import Foundation
import SQLite3
import SwiftData
import Testing
@testable import Spelum

@Suite("Pre-Slide SQLite Lightweight Migration")
@MainActor
struct SlideSQLiteMigrationTests {
    struct PreSlideSeed {
        let presentationID: UUID
        let attemptID: UUID
        let sectionText: String
    }

    @Test("Genuine pre-slide on-disk SQLite store migrates cleanly without losing existing talks or takes")
    func preSlideSQLiteStoreMigratesCleanly() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "PreSlideMigration")
        defer { workspace.cleanup() }

        let seeded = try seedGenuinePreSlideStore(in: workspace)
        #expect(try !sqliteColumnExists(
            columnName: "ZSLIDEDECKRELATIVEPATH",
            tableName: "ZTALKREVISIONRECORD",
            sqliteURL: workspace.storeURL
        ))
        #expect(try !sqliteColumnExists(
            columnName: "ZSLIDEASSIGNMENTSDATA",
            tableName: "ZSECTIONREVISIONRECORD",
            sqliteURL: workspace.storeURL
        ))

        let migratedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let migratedStore = PresentationStore(
            modelContext: migratedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let migratedAttempts = AttemptStore(
            modelContext: migratedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )

        let presentations = try migratedStore.fetchPresentations()
        #expect(presentations.count == 1)
        let talk = try #require(presentations.first)
        #expect(talk.title == "Pre-Slide Keynote")
        let revision = try #require(migratedStore.currentTalkRevision(for: talk))
        #expect(revision.slideDeckRelativePath == nil)
        #expect(revision.slideDeckPageCount == nil)

        let sections = migratedStore.orderedSections(in: revision)
        #expect(sections.count == 1)
        #expect(sections[0].text == seeded.sectionText)
        #expect(sections[0].slideReferences.isEmpty)

        let restoredAttempt = try #require(try migratedAttempts.attempt(withID: seeded.attemptID))
        #expect(restoredAttempt.sectionTitleSnapshot == "Opening")
    }
}

private extension SlideSQLiteMigrationTests {
    func seedGenuinePreSlideStore(in workspace: PracticeTestWorkspace) throws -> PreSlideSeed {
        let legacySchema = Schema([
            PreSlideLegacyModels.PresentationRecord.self,
            PreSlideLegacyModels.TalkRevisionRecord.self,
            PreSlideLegacyModels.TalkRevisionEntryRecord.self,
            PreSlideLegacyModels.SectionRevisionRecord.self,
            AttemptRecord.self,
            CoachingCueRecord.self
        ])
        let config = ModelConfiguration(schema: legacySchema, url: workspace.storeURL)
        let container = try ModelContainer(for: legacySchema, configurations: [config])
        let context = container.mainContext
        return try insertLegacyRecords(into: context)
    }

    func insertLegacyRecords(into context: ModelContext) throws -> PreSlideSeed {
        let now = Date()
        let sectionText = "Legacy talk line before slide support existed."
        let presentation = PreSlideLegacyModels.PresentationRecord(
            title: "Pre-Slide Keynote",
            sourceText: sectionText,
            createdAt: now,
            updatedAt: now
        )
        let revision = PreSlideLegacyModels.TalkRevisionRecord(
            revisionNumber: 1,
            title: "Pre-Slide Keynote",
            changeSummary: "Imported script",
            createdAt: now,
            presentation: presentation
        )
        let section = PreSlideLegacyModels.SectionRevisionRecord(
            title: "Opening",
            text: sectionText,
            speaker: "Presenter",
            speakerRoleRawValue: SpeakerRole.presenter.rawValue,
            purposeRawValue: SectionPurpose.general.rawValue,
            createdAt: now,
            presentation: presentation
        )
        let entry = PreSlideLegacyModels.TalkRevisionEntryRecord(
            orderIndex: 0,
            sectionRevisionID: section.revisionID,
            talkRevision: revision,
            sectionRevision: section
        )
        revision.entries.append(entry)
        presentation.sectionRevisions.append(section)
        presentation.talkRevisions.append(revision)
        presentation.currentRevisionID = revision.id

        let snapshot = AttemptSnapshotReference(
            presentationID: presentation.id,
            talkRevisionID: revision.id,
            talkRevisionNumber: 1,
            sectionID: section.sectionID,
            sectionRevisionID: section.revisionID,
            sectionTitle: section.title
        )
        let attempt = AttemptRecord(
            snapshot: snapshot,
            startedAt: now.addingTimeInterval(-10),
            finishedAt: now,
            practiceMode: .cueWords,
            status: .silentCompleted,
            playableDuration: 0,
            revealCount: 1
        )
        context.insert(presentation)
        context.insert(revision)
        context.insert(section)
        context.insert(entry)
        context.insert(attempt)
        try context.save()
        return PreSlideSeed(presentationID: presentation.id, attemptID: attempt.id, sectionText: sectionText)
    }

    func sqliteColumnExists(columnName: String, tableName: String, sqliteURL: URL) throws -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(sqliteURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw PresentationImportError.unreadableFile
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(tableName));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1) {
                if String(cString: cName).caseInsensitiveCompare(columnName) == .orderedSame {
                    return true
                }
            }
        }
        return false
    }
}

private enum PreSlideLegacyModels {
    @Model
    final class PresentationRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var sourceText: String
        var createdAt: Date
        var updatedAt: Date
        var currentRevisionID: UUID?
        @Relationship(deleteRule: .cascade, inverse: \TalkRevisionRecord.presentation)
        var talkRevisions: [TalkRevisionRecord]
        @Relationship(deleteRule: .cascade, inverse: \SectionRevisionRecord.presentation)
        var sectionRevisions: [SectionRevisionRecord]

        init(
            id: UUID = UUID(),
            title: String,
            sourceText: String,
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            currentRevisionID: UUID? = nil
        ) {
            self.id = id
            self.title = title
            self.sourceText = sourceText
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.currentRevisionID = currentRevisionID
            self.talkRevisions = []
            self.sectionRevisions = []
        }
    }

    @Model
    final class TalkRevisionRecord {
        @Attribute(.unique) var id: UUID
        var revisionNumber: Int
        var title: String
        var changeSummary: String
        var createdAt: Date
        var presentation: PresentationRecord?
        @Relationship(deleteRule: .cascade, inverse: \TalkRevisionEntryRecord.talkRevision)
        var entries: [TalkRevisionEntryRecord]

        init(
            id: UUID = UUID(),
            revisionNumber: Int,
            title: String,
            changeSummary: String,
            createdAt: Date = Date(),
            presentation: PresentationRecord? = nil
        ) {
            self.id = id
            self.revisionNumber = revisionNumber
            self.title = title
            self.changeSummary = changeSummary
            self.createdAt = createdAt
            self.presentation = presentation
            self.entries = []
        }
    }

    @Model
    final class TalkRevisionEntryRecord {
        var orderIndex: Int
        var sectionRevisionID: UUID
        var talkRevision: TalkRevisionRecord?
        var sectionRevision: SectionRevisionRecord?

        init(
            orderIndex: Int,
            sectionRevisionID: UUID,
            talkRevision: TalkRevisionRecord? = nil,
            sectionRevision: SectionRevisionRecord? = nil
        ) {
            self.orderIndex = orderIndex
            self.sectionRevisionID = sectionRevisionID
            self.talkRevision = talkRevision
            self.sectionRevision = sectionRevision
        }
    }

    @Model
    final class SectionRevisionRecord {
        @Attribute(.unique) var revisionID: UUID
        var sectionID: UUID
        var title: String
        var text: String
        var speaker: String
        var speakerRoleRawValue: String
        var purposeRawValue: String
        var cueWordsData: Data
        var exactPhrase: String?
        var handoffCueOverride: String?
        var handoffCueSourceSectionID: UUID?
        var handoffCueIsOpening: Bool?
        var createdAt: Date
        var presentation: PresentationRecord?

        init(
            revisionID: UUID = UUID(),
            sectionID: UUID = UUID(),
            title: String,
            text: String,
            speaker: String,
            speakerRoleRawValue: String,
            purposeRawValue: String,
            cueWordsData: Data = Data(),
            createdAt: Date = Date(),
            presentation: PresentationRecord? = nil
        ) {
            self.revisionID = revisionID
            self.sectionID = sectionID
            self.title = title
            self.text = text
            self.speaker = speaker
            self.speakerRoleRawValue = speakerRoleRawValue
            self.purposeRawValue = purposeRawValue
            self.cueWordsData = cueWordsData
            self.createdAt = createdAt
            self.presentation = presentation
        }
    }
}
