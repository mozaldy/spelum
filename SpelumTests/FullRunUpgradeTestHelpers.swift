import Foundation
import SQLite3
import SwiftData
import Testing
@testable import Spelum

@MainActor
enum FullRunUpgradeTestHelpers {
    struct Build3SeedSummary {
        let snapshot: AttemptSnapshotReference
        let attemptID: UUID
        let analysisID: UUID
        let preparationRequest: PreparationCoachingRequest
    }

    struct Build2SeedSummary {
        let snapshot: AttemptSnapshotReference
        let attemptID: UUID
    }

    static func seedGenuineBuildThreeStore(in workspace: PracticeTestWorkspace) throws -> Build3SeedSummary {
        let build3Schema = Schema([
            PresentationRecord.self,
            TalkRevisionRecord.self,
            TalkRevisionEntryRecord.self,
            SectionRevisionRecord.self,
            Build3LegacyModels.AttemptRecord.self,
            CoachingCueRecord.self
        ])
        let config = ModelConfiguration(schema: build3Schema, url: workspace.storeURL)
        let container = try ModelContainer(for: build3Schema, configurations: [config])
        let library = PresentationStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Build 3 Keynote")

        let attemptID = UUID()
        let relPath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        try FullRunTestFixtures.writeContinuousQuietAAC(
            to: workspace.storageRoot.appendingPathComponent(relPath),
            durationSeconds: 1.8
        )
        let analysis = try makeBuildThreeAnalysis(attemptID: attemptID, seeded: seeded)
        let markersData = try JSONEncoder().encode([
            AttemptMarker(timestamp: 0.6, label: "Build 3 Reveal Mark")
        ])
        let legacyAttempt = Build3LegacyModels.AttemptRecord(
            id: attemptID,
            snapshot: seeded.snapshot,
            relativeAudioPath: relPath,
            playableDuration: 1.8,
            markersData: markersData,
            timingAnalysisData: try JSONEncoder().encode(analysis)
        )
        container.mainContext.insert(legacyAttempt)

        let prepRequest = try seedBuildThreeCoachingCue(for: seeded, in: container.mainContext)
        try container.mainContext.save()

        return Build3SeedSummary(
            snapshot: seeded.snapshot,
            attemptID: attemptID,
            analysisID: analysis.analysisID,
            preparationRequest: prepRequest
        )
    }

    static func seedGenuineBuildTwoStoreForTask7(
        in workspace: PracticeTestWorkspace
    ) throws -> Build2SeedSummary {
        let build2Schema = Schema([
            PresentationRecord.self,
            TalkRevisionRecord.self,
            TalkRevisionEntryRecord.self,
            SectionRevisionRecord.self,
            Build2Task7LegacyModels.AttemptRecord.self
        ])
        let config = ModelConfiguration(schema: build2Schema, url: workspace.storeURL)
        let container = try ModelContainer(for: build2Schema, configurations: [config])
        let library = PresentationStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Build 2 Keynote")

        let attemptID = UUID()
        let relPath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        try FullRunTestFixtures.writeContinuousQuietAAC(
            to: workspace.storageRoot.appendingPathComponent(relPath),
            durationSeconds: 1.6
        )
        let markersData = try JSONEncoder().encode([
            AttemptMarker(timestamp: 0.5, label: "Build 2 Handoff Mark")
        ])
        let legacyAttempt = Build2Task7LegacyModels.AttemptRecord(
            id: attemptID,
            snapshot: seeded.snapshot,
            relativeAudioPath: relPath,
            playableDuration: 1.6,
            markersData: markersData
        )
        container.mainContext.insert(legacyAttempt)
        try container.mainContext.save()
        return Build2SeedSummary(snapshot: seeded.snapshot, attemptID: attemptID)
    }

    static func writeLegacyBuildThreeManifestJSON(
        attemptID: UUID,
        snapshot: AttemptSnapshotReference,
        relativeAudioPath: String,
        storageRoot: URL
    ) throws {
        struct LegacyBuild3Manifest: Codable {
            let attemptID: UUID
            let snapshot: AttemptSnapshotReference
            let practiceMode: PracticeMode
            let startedAt: Date
            let finishedAt: Date
            let relativeAudioPath: String?
            let elapsedDuration: TimeInterval
            let revealCount: Int
            let markers: [AttemptMarker]
            let isSilentRecall: Bool
            let interrupted: Bool
            let interruptionReason: String?
        }
        let manifest = LegacyBuild3Manifest(
            attemptID: attemptID,
            snapshot: snapshot,
            practiceMode: .cueWords,
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            relativeAudioPath: relativeAudioPath,
            elapsedDuration: 1.4,
            revealCount: 0,
            markers: [AttemptMarker(timestamp: 0.4, label: "Build 3 Sidecar Mark")],
            isSilentRecall: false,
            interrupted: true,
            interruptionReason: "Legacy build 3 save interruption"
        )
        let pendingDir = storageRoot.appendingPathComponent(
            AttemptStore.pendingSavesSubdirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let fileURL = pendingDir.appendingPathComponent("\(attemptID.uuidString.lowercased()).json")
        try JSONEncoder().encode(manifest).write(to: fileURL, options: [.atomic])
    }

    static func sqliteColumnExists(
        columnName: String,
        tableName: String,
        sqliteURL: URL
    ) throws -> Bool {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(sqliteURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openRC == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "SQLiteTestHelper", code: Int(openRC))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)

        var statement: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(db, "PRAGMA table_info(\(tableName));", -1, &statement, nil)
        guard prepareRC == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "SQLiteTestHelper",
                code: Int(prepareRC),
                userInfo: [NSLocalizedDescriptionKey: "PRAGMA table_info failed: \(message)"]
            )
        }
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while true {
            let stepRC = sqlite3_step(statement)
            if stepRC == SQLITE_ROW {
                if let cName = sqlite3_column_text(statement, 1) {
                    columns.append(String(cString: cName).uppercased())
                }
            } else if stepRC == SQLITE_DONE {
                break
            } else {
                let message = String(cString: sqlite3_errmsg(db))
                throw NSError(
                    domain: "SQLiteTestHelper",
                    code: Int(stepRC),
                    userInfo: [NSLocalizedDescriptionKey: "PRAGMA table_info step failed: \(message)"]
                )
            }
        }
        guard !columns.isEmpty else {
            throw NSError(
                domain: "SQLiteTestHelper",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Table \(tableName) returned zero columns"]
            )
        }
        return columns.contains(columnName.uppercased())
    }

    private static func makeBuildThreeAnalysis(
        attemptID: UUID,
        seeded: SeededSectionFixture
    ) throws -> TimingAnalysisResult {
        let fixture = try TimingFixtureLoader.fixture(id: "tenSecondTwentyWords")
        return TimingObservationsEngine.analyze(
            TimingAnalysisInput(
                attemptID: attemptID,
                talkRevisionID: seeded.talkRevision.id,
                sectionRevisionID: seeded.section.revisionID,
                elapsedAudioDuration: 1.8,
                scriptText: seeded.section.text,
                exactPhrase: seeded.section.exactPhrase,
                cueWords: seeded.section.cueWords,
                hasMultipleSpeakersOrHandoff: true,
                segments: TimingFixtureLoader.makeInput(from: fixture).segments,
                localeIdentifier: "en_US",
                hasUntimedFinalText: false
            )
        )
    }

    private static func seedBuildThreeCoachingCue(
        for seeded: SeededSectionFixture,
        in context: ModelContext
    ) throws -> PreparationCoachingRequest {
        let candidates = TechniqueLibrary.candidateTechniques(
            for: seeded.section.purpose,
            hasHandoff: true
        )
        let request = PreparationCoachingRequest(
            presentationID: seeded.presentation.id,
            sectionRevisionID: seeded.section.revisionID,
            talkRevisionID: seeded.talkRevision.id,
            sectionTitle: seeded.section.title,
            scriptText: seeded.section.text,
            exactPhrase: seeded.section.exactPhrase,
            cueWords: seeded.section.cueWords,
            purpose: seeded.section.purpose,
            handoffCueText: "Welcome to our rehearsal preview.",
            isSpeakerChangeHandoff: true,
            knownSpeakerNames: ["Alex", "Jordan"],
            selectedTechniqueID: candidates.first?.id,
            candidateTechniques: candidates,
            promptVersion: "v2"
        )
        let suggestion = CoachingSuggestion(
            task: .preparation,
            origin: .authoredFallback,
            techniqueID: candidates.first?.id,
            techniqueTitle: candidates.first?.title,
            sourceWork: candidates.first?.sourceWork,
            sourceTimestamp: candidates.first?.sourceTimestamp,
            sourcePassageSummary: candidates.first?.sourcePassageSummary,
            exactPhrase: seeded.section.exactPhrase,
            action: "Pause one beat before delivering the reveal line.",
            rationale: "Builds contrast after handoff.",
            promptVersion: request.promptVersion,
            sectionRevisionID: seeded.section.revisionID
        )
        let coachingStore = CoachingStore(modelContext: context)
        try coachingStore.savePreparationCue(suggestion, for: request)
        return request
    }
}

private enum Build3LegacyModels {
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
        var timingAnalysisData: Data?

        init(
            id: UUID,
            snapshot: AttemptSnapshotReference,
            relativeAudioPath: String?,
            playableDuration: TimeInterval,
            markersData: Data,
            timingAnalysisData: Data?
        ) {
            self.id = id
            self.presentationID = snapshot.presentationID
            self.talkRevisionID = snapshot.talkRevisionID
            self.talkRevisionNumber = snapshot.talkRevisionNumber
            self.sectionID = snapshot.sectionID
            self.sectionRevisionID = snapshot.sectionRevisionID
            self.sectionTitleSnapshot = snapshot.sectionTitle
            self.startedAt = Date().addingTimeInterval(-60)
            self.finishedAt = Date().addingTimeInterval(-58)
            self.practiceModeRawValue = PracticeMode.cueWords.rawValue
            self.statusRawValue = AttemptStatus.ready.rawValue
            self.relativeAudioPath = relativeAudioPath
            self.playableDuration = playableDuration
            self.elapsedDuration = playableDuration
            self.revealCount = 1
            self.markersData = markersData
            self.interruptionReason = nil
            self.isSilentRecall = false
            self.timingAnalysisData = timingAnalysisData
        }
    }
}

private enum Build2Task7LegacyModels {
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
            relativeAudioPath: String?,
            playableDuration: TimeInterval,
            markersData: Data
        ) {
            self.id = id
            self.presentationID = snapshot.presentationID
            self.talkRevisionID = snapshot.talkRevisionID
            self.talkRevisionNumber = snapshot.talkRevisionNumber
            self.sectionID = snapshot.sectionID
            self.sectionRevisionID = snapshot.sectionRevisionID
            self.sectionTitleSnapshot = snapshot.sectionTitle
            self.startedAt = Date().addingTimeInterval(-90)
            self.finishedAt = Date().addingTimeInterval(-88)
            self.practiceModeRawValue = PracticeMode.cueWords.rawValue
            self.statusRawValue = AttemptStatus.ready.rawValue
            self.relativeAudioPath = relativeAudioPath
            self.playableDuration = playableDuration
            self.elapsedDuration = playableDuration
            self.revealCount = 1
            self.markersData = markersData
            self.interruptionReason = nil
            self.isSilentRecall = false
        }
    }
}
