import Foundation
import SQLite3
import SwiftData
import Testing
@testable import Spelum

@Suite("Build 1.0 (2) Persistence Compatibility")
@MainActor
struct Build2CompatibilityTests {
    private struct Build2SeedSummary {
        let presentationID: UUID
        let attemptID: UUID
        let relativeAudioPath: String
        let sectionText: String
        let exactPhrase: String?
        let cueWords: [String]
    }

    @Test("Existing Build 1.0 (2) SQLite store migrates cleanly and preserves talks, revisions, and takes")
    func buildTwoSQLiteStoreMigratesAndEnrichesCleanly() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T5Build2Compat")
        defer { workspace.cleanup() }

        let seeded = try seedGenuineBuildTwoStore(in: workspace)
        #expect(try !sqliteColumnExists(
            columnName: "ZTIMINGANALYSISDATA",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))

        let migratedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let migratedLibrary = PresentationStore(modelContext: migratedContainer.mainContext)
        let migratedAttempts = AttemptStore(
            modelContext: migratedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )

        let presentations = try migratedLibrary.fetchPresentations()
        #expect(presentations.count == 1)
        #expect(presentations.first?.title == "Build 2 Keynote")

        let restoredTake = try #require(try migratedAttempts.attempt(withID: seeded.attemptID))
        #expect(restoredTake.relativeAudioPath == seeded.relativeAudioPath)
        #expect(restoredTake.hasPlayableAudio)
        #expect(restoredTake.revealCount == 2)
        #expect(restoredTake.markers.count == 1)
        #expect(restoredTake.markers.first?.label == "Build 2 Marker")
        #expect(restoredTake.timingAnalysis == nil)

        try verifyPlayableAudio(for: restoredTake, using: migratedAttempts)
        let savedAnalysisID = try enrichAndMark(restoredTake, seeded: seeded, in: migratedAttempts)
        try verifyReopenedStore(
            in: workspace,
            seeded: seeded,
            expectedAnalysisID: savedAnalysisID
        )
    }

    private func verifyPlayableAudio(for attempt: AttemptRecord, using store: AttemptStore) throws {
        let audioURL = try #require(store.resolvedAudioURL(for: attempt))
        let player = TakeAudioPlayer(audioSessionManager: TrackingAudioSessionManager())
        player.load(url: audioURL)
        #expect(player.isLoaded)
        player.stop()
    }

    private func enrichAndMark(
        _ restoredTake: AttemptRecord,
        seeded: Build2SeedSummary,
        in attemptStore: AttemptStore
    ) throws -> UUID {
        let fixture = try TimingFixtureLoader.fixture(id: "tenSecondTwentyWords")
        let baseInput = TimingFixtureLoader.makeInput(from: fixture)
        let analysis = TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: restoredTake.id,
                talkRevisionID: restoredTake.talkRevisionID,
                sectionRevisionID: restoredTake.sectionRevisionID,
                elapsedAudioDuration: restoredTake.playableDuration,
                scriptText: seeded.sectionText,
                exactPhrase: seeded.exactPhrase,
                cueWords: seeded.cueWords,
                hasMultipleSpeakersOrHandoff: true,
                segments: baseInput.segments,
                localeIdentifier: "en_US",
                hasUntimedFinalText: false
            )
        )
        let savedFlag = try attemptStore.saveTimingAnalysis(
            analysis,
            forAttemptID: restoredTake.id,
            expectedRelativeAudioPath: restoredTake.relativeAudioPath,
            expectedTalkRevisionID: restoredTake.talkRevisionID,
            expectedSectionRevisionID: restoredTake.sectionRevisionID
        )
        #expect(savedFlag)

        let addedMarker = try attemptStore.addManualMarker(
            toAttemptID: restoredTake.id,
            timestamp: 1.1,
            label: "Post-Migration Review Mark"
        )
        #expect(addedMarker != nil)
        return analysis.analysisID
    }

    private func verifyReopenedStore(
        in workspace: PracticeTestWorkspace,
        seeded: Build2SeedSummary,
        expectedAnalysisID: UUID
    ) throws {
        let reopenedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let reopenedAttempts = AttemptStore(
            modelContext: reopenedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let persistedTake = try #require(try reopenedAttempts.attempt(withID: seeded.attemptID))
        #expect(persistedTake.timingAnalysis?.analysisID == expectedAnalysisID)
        #expect(persistedTake.relativeAudioPath == seeded.relativeAudioPath)
        #expect(persistedTake.markers.count == 2)
        #expect(try reopenedAttempts.fetchAttempts(forPresentationID: seeded.presentationID).count == 1)
    }

    private func seedGenuineBuildTwoStore(in workspace: PracticeTestWorkspace) throws -> Build2SeedSummary {
        let build2Schema = Schema([
            PresentationRecord.self,
            TalkRevisionRecord.self,
            TalkRevisionEntryRecord.self,
            SectionRevisionRecord.self,
            Build2LegacyModels.AttemptRecord.self
        ])
        let build2Config = ModelConfiguration(schema: build2Schema, url: workspace.storeURL)
        let build2Container = try ModelContainer(for: build2Schema, configurations: [build2Config])
        let library = PresentationStore(modelContext: build2Container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Build 2 Keynote")

        let attemptID = UUID()
        let relativePath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        let audioURL = workspace.storageRoot.appendingPathComponent(relativePath)
        try PracticeTestFixtures.writeSyntheticAACM4A(to: audioURL, durationSeconds: 2.0)

        let marker = AttemptMarker(timestamp: 0.75, label: "Build 2 Marker")
        let markersData = try JSONEncoder().encode([marker])
        let legacyAttempt = Build2LegacyModels.AttemptRecord(
            id: attemptID,
            snapshot: seeded.snapshot,
            startedAt: Date().addingTimeInterval(-30),
            finishedAt: Date().addingTimeInterval(-28),
            relativeAudioPath: relativePath,
            playableDuration: 2.0,
            revealCount: 2,
            markersData: markersData
        )
        build2Container.mainContext.insert(legacyAttempt)
        try build2Container.mainContext.save()

        return Build2SeedSummary(
            presentationID: seeded.presentation.id,
            attemptID: attemptID,
            relativeAudioPath: relativePath,
            sectionText: seeded.section.text,
            exactPhrase: seeded.section.exactPhrase,
            cueWords: seeded.section.cueWords
        )
    }

    private func sqliteColumnExists(columnName: String, tableName: String, sqliteURL: URL) throws -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(sqliteURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "SQLiteTestHelper", code: 1)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let pragmaSQL = "PRAGMA table_info(\(tableName));"
        var hasColumn = false
        if sqlite3_prepare_v2(db, pragmaSQL, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cName = sqlite3_column_text(statement, 1),
                   String(cString: cName).uppercased() == columnName.uppercased() {
                    hasColumn = true
                }
            }
        }
        sqlite3_finalize(statement)
        return hasColumn
    }
}

private enum Build2LegacyModels {
    @Model
    final class AttemptRecord {
        var id: UUID
        var presentationID: UUID
        var talkRevisionID: UUID
        var talkRevisionNumber: Int
        var sectionID: UUID
        var sectionRevisionID: UUID
        var sectionTitleSnapshot: String
        var startedAt: Date
        var finishedAt: Date?
        var practiceModeRawValue: String
        var statusRawValue: String
        var relativeAudioPath: String?
        var playableDuration: TimeInterval
        var elapsedDuration: TimeInterval
        var revealCount: Int
        var markersData: Data
        var interruptionReason: String?
        var isSilentRecall: Bool

        init(
            id: UUID,
            snapshot: AttemptSnapshotReference,
            startedAt: Date,
            finishedAt: Date?,
            relativeAudioPath: String?,
            playableDuration: TimeInterval,
            revealCount: Int,
            markersData: Data
        ) {
            self.id = id
            self.presentationID = snapshot.presentationID
            self.talkRevisionID = snapshot.talkRevisionID
            self.talkRevisionNumber = snapshot.talkRevisionNumber
            self.sectionID = snapshot.sectionID
            self.sectionRevisionID = snapshot.sectionRevisionID
            self.sectionTitleSnapshot = snapshot.sectionTitle
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.practiceModeRawValue = PracticeMode.cueWords.rawValue
            self.statusRawValue = AttemptStatus.ready.rawValue
            self.relativeAudioPath = relativeAudioPath
            self.playableDuration = playableDuration
            self.elapsedDuration = playableDuration
            self.revealCount = revealCount
            self.markersData = markersData
            self.interruptionReason = nil
            self.isSilentRecall = false
        }
    }
}
