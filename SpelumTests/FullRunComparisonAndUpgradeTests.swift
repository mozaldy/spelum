import Foundation
import SQLite3
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Attempt Comparisons, Build 3 Upgrade Compatibility & Full Run Accessibility")
@MainActor
struct FullRunComparisonAndUpgradeTests {
    @Test("Comparison defaults to same revision and scope and flags mismatched scope, revision, or kind")
    func comparisonScopeAndDefaultPairSelection() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Compare")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)

        let entireSnapshot = try #require(
            library.makeFullRunSnapshot(for: talk.presentation, talkRevision: talk.talkRevision, startKind: .entireTalk)
        )
        let handoffSnapshot = try #require(
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .fromHandoff
            )
        )

        let run1 = try saveSyntheticFullRun(
            snapshot: entireSnapshot,
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 3.4,
            revealCount: 2,
            transitionTimes: [0, 0.8, 1.7, 2.5],
            in: attemptStore,
            workspace: workspace
        )
        let run2 = try saveSyntheticFullRun(
            snapshot: entireSnapshot,
            startedAt: Date(timeIntervalSince1970: 200),
            duration: 2.9,
            revealCount: 0,
            transitionTimes: [0, 0.7, 1.5, 2.2],
            in: attemptStore,
            workspace: workspace
        )
        let handoffRun = try saveSyntheticFullRun(
            snapshot: handoffSnapshot,
            startedAt: Date(timeIntervalSince1970: 300),
            duration: 2.1,
            revealCount: 1,
            transitionTimes: [0, 0.7, 1.4],
            in: attemptStore,
            workspace: workspace
        )

        let revealSection = talk.sections[1]
        let sectionTake1 = try saveSyntheticSectionTake(
            presentation: talk.presentation,
            talkRevision: talk.talkRevision,
            section: revealSection,
            startedAt: Date(timeIntervalSince1970: 150),
            duration: 1.8,
            revealCount: 1,
            in: attemptStore,
            workspace: workspace
        )
        let sectionTake2 = try saveSyntheticSectionTake(
            presentation: talk.presentation,
            talkRevision: talk.talkRevision,
            section: revealSection,
            startedAt: Date(timeIntervalSince1970: 250),
            duration: 1.5,
            revealCount: 0,
            in: attemptStore,
            workspace: workspace
        )

        let allRecords = try attemptStore.fetchAttempts(forPresentationID: talk.presentation.id)
        let descriptors = allRecords.map(ComparableAttemptDescriptor.init(record:))
        let currentSecRevIDs = Set(talk.sections.map(\.revisionID))

        // Full runs filter defaults to run1 vs run2 (same revision & entireTalk scope), NOT handoffRun!
        let defaultFullRun = try #require(
            AttemptComparisonEngine.defaultComparablePair(
                from: descriptors,
                filter: .fullRuns,
                currentTalkRevisionID: talk.talkRevision.id,
                currentSectionRevisionIDs: currentSecRevIDs
            )
        )
        #expect(defaultFullRun.earlierID == run1.id)
        #expect(defaultFullRun.laterID == run2.id)
        #expect(defaultFullRun.scope.isDirectlyComparable)

        let fullRunSummary = AttemptComparisonEngine.compare(
            ComparableAttemptDescriptor(record: run2),
            ComparableAttemptDescriptor(record: run1),
            currentTalkRevisionID: talk.talkRevision.id,
            currentSectionRevisionIDs: currentSecRevIDs
        )
        // Always ordered chronologically (earlier -> later).
        #expect(fullRunSummary.earlier.id == run1.id)
        #expect(fullRunSummary.later.id == run2.id)
        #expect(fullRunSummary.revealDelta == -2)
        #expect(fullRunSummary.durationDelta < 0)
        #expect(fullRunSummary.fullRunSectionRows.count == 4)

        // Entire Talk vs From Handoff is explicitly marked different scopes.
        let differentScope = AttemptComparisonEngine.compare(
            ComparableAttemptDescriptor(record: run2),
            ComparableAttemptDescriptor(record: handoffRun),
            currentTalkRevisionID: talk.talkRevision.id,
            currentSectionRevisionIDs: currentSecRevIDs
        )
        #expect(!differentScope.scope.isDirectlyComparable)
        if case .differentFullRunScopeOrRevision(let sameRev, let sameScope, _, _, _, _) = differentScope.scope {
            #expect(sameRev)
            #expect(!sameScope)
        } else {
            Issue.record("Expected differentFullRunScopeOrRevision scope")
        }

        // Section takes filter defaults to sectionTake1 vs sectionTake2 (same section revision).
        let defaultSection = try #require(
            AttemptComparisonEngine.defaultComparablePair(
                from: descriptors,
                filter: .sectionTakes,
                currentTalkRevisionID: talk.talkRevision.id,
                currentSectionRevisionIDs: currentSecRevIDs
            )
        )
        #expect(defaultSection.earlierID == sectionTake1.id)
        #expect(defaultSection.laterID == sectionTake2.id)
        #expect(defaultSection.scope.isDirectlyComparable)

        // Mixing section take with full run is explicitly labeled mixedAttemptKinds.
        let mixed = AttemptComparisonEngine.compare(
            ComparableAttemptDescriptor(record: sectionTake1),
            ComparableAttemptDescriptor(record: run1),
            currentTalkRevisionID: talk.talkRevision.id,
            currentSectionRevisionIDs: currentSecRevIDs
        )
        #expect(mixed.scope == .mixedAttemptKinds)
        #expect(!mixed.scope.isDirectlyComparable)
    }

    @Test("Existing Build 1.0 (3) SQLite store and pending sidecar migrate cleanly without altering coaching data")
    func buildThreeUpgradeCompatibility() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Build3Compat")
        defer { workspace.cleanup() }

        let seeded = try seedGenuineBuildThreeStore(in: workspace)

        // Confirm seeded SQLite genuinely has Build 3 schema (has timingAnalysisData, lacks Task 7 columns).
        #expect(try sqliteColumnExists(
            columnName: "ZTIMINGANALYSISDATA",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))
        #expect(try !sqliteColumnExists(
            columnName: "ZATTEMPTKINDRAWVALUE",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))
        #expect(try !sqliteColumnExists(
            columnName: "ZFULLRUNDATA",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))

        // Also seed a legacy Build 3 PendingSaveManifest JSON (without attemptKind or fullRunPayload).
        let legacyPendingID = UUID()
        let legacyPendingRelPath = AttemptStore.opaqueRelativeAudioPath(for: legacyPendingID)
        try FullRunTestFixtures.writeContinuousQuietAAC(
            to: workspace.storageRoot.appendingPathComponent(legacyPendingRelPath),
            durationSeconds: 1.4
        )
        try writeLegacyBuildThreeManifestJSON(
            attemptID: legacyPendingID,
            snapshot: seeded.snapshot,
            relativeAudioPath: legacyPendingRelPath,
            storageRoot: workspace.storageRoot
        )

        // Open with Task 7 schema (lightweight migration).
        let migratedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let migratedLibrary = PresentationStore(modelContext: migratedContainer.mainContext)
        let migratedAttempts = AttemptStore(
            modelContext: migratedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let migratedCoaching = CoachingStore(modelContext: migratedContainer.mainContext)

        let recoverySummary = migratedAttempts.recoverInterruptedAttemptsOnLaunch()
        #expect(recoverySummary.recoveredCount == 1)

        // Existing Build 3 take retains audio, timingAnalysis, markers, and resolves as .section.
        let restoredTake = try #require(try migratedAttempts.attempt(withID: seeded.attemptID))
        #expect(!restoredTake.isFullRun)
        #expect(restoredTake.attemptKind == .section)
        #expect(restoredTake.fullRunPayload == nil)
        #expect(restoredTake.timingAnalysis?.analysisID == seeded.analysisID)
        #expect(restoredTake.hasPlayableAudio)

        // Legacy Build 3 pending manifest recovered as .section take.
        let recoveredPending = try #require(try migratedAttempts.attempt(withID: legacyPendingID))
        #expect(!recoveredPending.isFullRun)
        #expect(recoveredPending.attemptKind == .section)
        #expect(recoveredPending.hasPlayableAudio)

        // Existing Build 3 CoachingCueRecord preserved intact.
        let restoredCue = try migratedCoaching.cachedCue(forCacheKey: seeded.coachingCacheKey)
        #expect(restoredCue?.headline == "Anchor the reveal pause")

        // New Task 7 full run saves cleanly alongside migrated Build 3 takes.
        let presentation = try #require(try migratedLibrary.presentation(withID: seeded.snapshot.presentationID))
        let currentRev = try #require(migratedLibrary.currentTalkRevision(for: presentation))
        let fullSnapshot = try #require(
            migratedLibrary.makeFullRunSnapshot(for: presentation, talkRevision: currentRev, startKind: .entireTalk)
        )
        let newRun = try saveSyntheticFullRun(
            snapshot: fullSnapshot,
            startedAt: Date(),
            duration: 2.0,
            revealCount: 0,
            transitionTimes: [0, 1.0],
            in: migratedAttempts,
            workspace: workspace
        )
        #expect(newRun.isFullRun)
        #expect(try migratedAttempts.fetchFullRuns(forPresentationID: presentation.id).count == 1)
        #expect(try migratedAttempts.fetchSectionTakes(forPresentationID: presentation.id).count == 2)
    }

    @Test("Full run, review, history, and comparison views render across Light, Dark, and Accessibility sizes")
    func uiAndAccessibilityRenderingSmoke() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7UISmoke")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(for: talk.presentation, talkRevision: talk.talkRevision, startKind: .entireTalk)
        )
        let run1 = try saveSyntheticFullRun(
            snapshot: snapshot,
            startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 3.0,
            revealCount: 1,
            transitionTimes: [0, 0.8, 1.6, 2.3],
            in: attemptStore,
            workspace: workspace
        )
        let run2 = try saveSyntheticFullRun(
            snapshot: snapshot,
            startedAt: Date(timeIntervalSince1970: 2_000),
            duration: 2.6,
            revealCount: 0,
            transitionTimes: [0, 0.7, 1.4, 2.0],
            in: attemptStore,
            workspace: workspace
        )

        let schemes: [ColorScheme] = [.light, .dark]
        let typeSizes: [DynamicTypeSize] = [.large, .accessibility3]
        for scheme in schemes {
            for typeSize in typeSizes {
                let target = FullRunTarget(presentationID: talk.presentation.id, talkRevisionID: talk.talkRevision.id)
                renderSmoke(
                    FullRunView(presentation: talk.presentation, target: target, onOpenReview: { _ in }),
                    container: container,
                    scheme: scheme,
                    typeSize: typeSize
                )
                renderSmoke(
                    TakeReview(attemptID: run2.id, onRetry: { _ in }),
                    container: container,
                    scheme: scheme,
                    typeSize: typeSize
                )
                renderSmoke(
                    AttemptHistory(presentation: talk.presentation, onOpenReview: { _ in }),
                    container: container,
                    scheme: scheme,
                    typeSize: typeSize
                )
                renderSmoke(
                    AttemptComparisonView(
                        presentation: talk.presentation,
                        initialFirstID: run1.id,
                        initialSecondID: run2.id,
                        onOpenReview: { _ in }
                    ),
                    container: container,
                    scheme: scheme,
                    typeSize: typeSize
                )
            }
        }
    }
}

private extension FullRunComparisonAndUpgradeTests {
    struct Build3SeedSummary {
        let snapshot: AttemptSnapshotReference
        let attemptID: UUID
        let analysisID: UUID
        let coachingCacheKey: String
    }

    func saveSyntheticFullRun(
        snapshot: FullRunSnapshot,
        startedAt: Date,
        duration: TimeInterval,
        revealCount: Int,
        transitionTimes: [TimeInterval],
        in attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws -> AttemptRecord {
        let attemptID = UUID()
        let relPath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        let url = workspace.storageRoot.appendingPathComponent(relPath)
        try FullRunTestFixtures.writeContinuousQuietAAC(to: url, durationSeconds: duration)
        let transitions = zip(snapshot.sections, transitionTimes).map { section, startTime in
            FullRunSectionTransition(
                runIndex: section.runIndex,
                talkSectionIndex: section.talkSectionIndex,
                sectionID: section.sectionID,
                sectionRevisionID: section.sectionRevisionID,
                sectionTitle: section.title,
                speaker: section.speaker,
                speakerRole: section.speakerRole,
                purpose: section.purpose,
                startTime: startTime
            )
        }
        let payload = FullRunAttemptPayload(
            snapshot: snapshot,
            transitions: transitions,
            completionKind: .completedAllSections,
            reachedSectionCount: transitions.count
        )
        return try attemptStore.finalizeAttempt(
            AttemptFinalizationInput(
                id: attemptID,
                snapshot: snapshot.makeAttemptSnapshotReference(),
                practiceMode: .cueWords,
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(duration),
                relativeAudioPath: relPath,
                elapsedDuration: duration,
                revealCount: revealCount,
                markers: [],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil,
                attemptKind: .fullRun,
                fullRunPayload: payload
            )
        )
    }

    func saveSyntheticSectionTake(
        presentation: PresentationRecord,
        talkRevision: TalkRevisionRecord,
        section: SectionRevisionRecord,
        startedAt: Date,
        duration: TimeInterval,
        revealCount: Int,
        in attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws -> AttemptRecord {
        let attemptID = UUID()
        let relPath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        let url = workspace.storageRoot.appendingPathComponent(relPath)
        try FullRunTestFixtures.writeContinuousQuietAAC(to: url, durationSeconds: duration)
        let ref = AttemptSnapshotReference(
            presentationID: presentation.id,
            talkRevisionID: talkRevision.id,
            talkRevisionNumber: talkRevision.revisionNumber,
            sectionID: section.sectionID,
            sectionRevisionID: section.revisionID,
            sectionTitle: section.title
        )
        return try attemptStore.finalizeAttempt(
            AttemptFinalizationInput(
                id: attemptID,
                snapshot: ref,
                practiceMode: .cueWords,
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(duration),
                relativeAudioPath: relPath,
                elapsedDuration: duration,
                revealCount: revealCount,
                markers: [],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil
            )
        )
    }

    func seedGenuineBuildThreeStore(in workspace: PracticeTestWorkspace) throws -> Build3SeedSummary {
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
        let fixture = try TimingFixtureLoader.fixture(id: "tenSecondTwentyWords")
        let analysis = TimingObservationsEngine.analyze(
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
        let analysisData = try JSONEncoder().encode(analysis)
        let legacyAttempt = Build3LegacyModels.AttemptRecord(
            id: attemptID,
            snapshot: seeded.snapshot,
            relativeAudioPath: relPath,
            playableDuration: 1.8,
            timingAnalysisData: analysisData
        )
        container.mainContext.insert(legacyAttempt)

        let cacheKey = "build3-prep-\(seeded.section.revisionID.uuidString)"
        let cue = CoachingCueRecord(
            cacheKey: cacheKey,
            stage: .preparation,
            origin: .authoredFallback,
            presentationID: seeded.presentation.id,
            talkRevisionID: seeded.talkRevision.id,
            sectionID: seeded.section.sectionID,
            sectionRevisionID: seeded.section.revisionID,
            attemptID: nil,
            techniqueID: "reveal_pause_beat",
            headline: "Anchor the reveal pause",
            actionableStep: "Pause one beat before delivering the reveal line.",
            rationale: "Builds contrast after handoff.",
            focusExcerpt: seeded.section.exactPhrase,
            suggestedPracticeMode: .cueWords
        )
        container.mainContext.insert(cue)
        try container.mainContext.save()

        return Build3SeedSummary(
            snapshot: seeded.snapshot,
            attemptID: attemptID,
            analysisID: analysis.analysisID,
            coachingCacheKey: cacheKey
        )
    }

    func writeLegacyBuildThreeManifestJSON(
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
            markers: [],
            isSilentRecall: false,
            interrupted: true,
            interruptionReason: "Legacy build 3 save interruption"
        )
        let pendingDir = storageRoot.appendingPathComponent("PendingAttemptSaves", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let fileURL = pendingDir.appendingPathComponent("\(attemptID.uuidString).json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: fileURL, options: [.atomic])
    }

    func sqliteColumnExists(columnName: String, tableName: String, sqliteURL: URL) throws -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(sqliteURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "SQLiteTestHelper", code: 1)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var hasColumn = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(tableName));", -1, &statement, nil) == SQLITE_OK {
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

    func renderSmoke<V: View>(
        _ view: V,
        container: ModelContainer,
        scheme: ColorScheme,
        typeSize: DynamicTypeSize
    ) {
        let host = UIHostingController(
            rootView: NavigationStack { view }
                .modelContainer(container)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
        )
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == 393)
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
            self.markersData = Data()
            self.interruptionReason = nil
            self.isSilentRecall = false
            self.timingAnalysisData = timingAnalysisData
        }
    }
}
