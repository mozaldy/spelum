import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Build 2 & Build 3 Upgrade Compatibility and Full Run Accessibility")
@MainActor
struct FullRunComparisonAndUpgradeTests {
    @Test("Build 1.0 (3) SQLite store and legacy sidecar migrate cleanly with audio, markers, and coaching intact")
    func buildThreeUpgradeCompatibility() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Build3Compat")
        defer { workspace.cleanup() }

        let seeded = try FullRunUpgradeTestHelpers.seedGenuineBuildThreeStore(in: workspace)

        #expect(try FullRunUpgradeTestHelpers.sqliteColumnExists(
            columnName: "ZTIMINGANALYSISDATA",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))
        #expect(try !FullRunUpgradeTestHelpers.sqliteColumnExists(
            columnName: "ZATTEMPTKINDRAWVALUE",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))
        #expect(try !FullRunUpgradeTestHelpers.sqliteColumnExists(
            columnName: "ZFULLRUNDATA",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))

        let legacyPendingID = UUID()
        let legacyPendingRelPath = AttemptStore.opaqueRelativeAudioPath(for: legacyPendingID)
        try FullRunTestFixtures.writeContinuousQuietAAC(
            to: workspace.storageRoot.appendingPathComponent(legacyPendingRelPath),
            durationSeconds: 1.4
        )
        try FullRunUpgradeTestHelpers.writeLegacyBuildThreeManifestJSON(
            attemptID: legacyPendingID,
            snapshot: seeded.snapshot,
            relativeAudioPath: legacyPendingRelPath,
            storageRoot: workspace.storageRoot
        )

        try verifyMigratedBuildThreeStore(
            seeded: seeded,
            legacyPendingID: legacyPendingID,
            workspace: workspace
        )
    }

    @Test("Build 1.0 (2) migrated section takes stay section-only and coexist with Task 7 full runs")
    func buildTwoMigratedRecordsCoexistWithFullRuns() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Build2Compat")
        defer { workspace.cleanup() }

        let seeded = try FullRunUpgradeTestHelpers.seedGenuineBuildTwoStoreForTask7(in: workspace)
        #expect(try !FullRunUpgradeTestHelpers.sqliteColumnExists(
            columnName: "ZTIMINGANALYSISDATA",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))
        #expect(try !FullRunUpgradeTestHelpers.sqliteColumnExists(
            columnName: "ZATTEMPTKINDRAWVALUE",
            tableName: "ZATTEMPTRECORD",
            sqliteURL: workspace.storeURL
        ))

        let migratedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let migratedLibrary = PresentationStore(modelContext: migratedContainer.mainContext)
        let migratedAttempts = AttemptStore(
            modelContext: migratedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )

        let restoredTake = try #require(try migratedAttempts.attempt(withID: seeded.attemptID))
        #expect(!restoredTake.isFullRun)
        #expect(restoredTake.attemptKind == .section)
        #expect(restoredTake.fullRunPayload == nil)
        #expect(restoredTake.hasPlayableAudio)
        #expect(restoredTake.markers.map(\.label) == ["Build 2 Handoff Mark"])

        let presentation = try #require(try migratedLibrary.presentation(withID: seeded.snapshot.presentationID))
        let currentRev = try #require(migratedLibrary.currentTalkRevision(for: presentation))
        let fullSnapshot = try #require(
            migratedLibrary.makeFullRunSnapshot(for: presentation, talkRevision: currentRev, startKind: .entireTalk)
        )
        let newRun = try FullRunTestFixtures.saveSyntheticFullRun(
            SyntheticFullRunSpec(
                snapshot: fullSnapshot,
                startedAt: Date(),
                duration: 2.0,
                transitionTimes: [0, 1.0]
            ),
            in: migratedAttempts,
            workspace: workspace
        )
        #expect(newRun.isFullRun)
        #expect(try migratedAttempts.fetchFullRuns(forPresentationID: presentation.id).count == 1)
        #expect(try migratedAttempts.fetchSectionTakes(forPresentationID: presentation.id).count == 1)
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
            library.makeFullRunSnapshot(
                for: talk.presentation,
                talkRevision: talk.talkRevision,
                startKind: .entireTalk
            )
        )
        let run1 = try FullRunTestFixtures.saveSyntheticFullRun(
            SyntheticFullRunSpec(
                snapshot: snapshot,
                startedAt: Date(timeIntervalSince1970: 1_000),
                duration: 3.0,
                revealCount: 1,
                transitionTimes: [0, 0.8, 1.6, 2.3]
            ),
            in: attemptStore,
            workspace: workspace
        )
        let run2 = try FullRunTestFixtures.saveSyntheticFullRun(
            SyntheticFullRunSpec(
                snapshot: snapshot,
                startedAt: Date(timeIntervalSince1970: 2_000),
                duration: 2.6,
                revealCount: 0,
                transitionTimes: [0, 0.7, 1.4, 2.0]
            ),
            in: attemptStore,
            workspace: workspace
        )

        let schemes: [ColorScheme] = [.light, .dark]
        let typeSizes: [DynamicTypeSize] = [.large, .accessibility3]
        for scheme in schemes {
            for typeSize in typeSizes {
                renderAllTask7Screens(
                    talk: talk,
                    run1: run1,
                    run2: run2,
                    container: container,
                    appearance: (scheme, typeSize)
                )
            }
        }
    }
}

private extension FullRunComparisonAndUpgradeTests {
    func verifyMigratedBuildThreeStore(
        seeded: FullRunUpgradeTestHelpers.Build3SeedSummary,
        legacyPendingID: UUID,
        workspace: PracticeTestWorkspace
    ) throws {
        let migratedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let migratedLibrary = PresentationStore(modelContext: migratedContainer.mainContext)
        let migratedAttempts = AttemptStore(
            modelContext: migratedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let migratedCoaching = CoachingStore(modelContext: migratedContainer.mainContext)

        let recoverySummary = try migratedAttempts.recoverUnfinishedAttempts()
        #expect(recoverySummary.totalRecoveredCount == 1)
        #expect(recoverySummary.recoveredPlayableCount == 1)

        let restoredTake = try #require(try migratedAttempts.attempt(withID: seeded.attemptID))
        #expect(!restoredTake.isFullRun)
        #expect(restoredTake.attemptKind == .section)
        #expect(restoredTake.fullRunPayload == nil)
        #expect(restoredTake.timingAnalysis?.analysisID == seeded.analysisID)
        #expect(restoredTake.markers.map(\.label) == ["Build 3 Reveal Mark"])
        #expect(restoredTake.hasPlayableAudio)

        let recoveredPending = try #require(try migratedAttempts.attempt(withID: legacyPendingID))
        #expect(!recoveredPending.isFullRun)
        #expect(recoveredPending.attemptKind == .section)
        #expect(recoveredPending.markers.map(\.label) == ["Build 3 Sidecar Mark"])
        #expect(recoveredPending.hasPlayableAudio)

        let restoredCue = try #require(
            try migratedCoaching.fetchCachedPreparationCue(for: seeded.preparationRequest)
        )
        #expect(restoredCue.action == "Pause one beat before delivering the reveal line.")

        let presentation = try #require(try migratedLibrary.presentation(withID: seeded.snapshot.presentationID))
        let currentRev = try #require(migratedLibrary.currentTalkRevision(for: presentation))
        let fullSnapshot = try #require(
            migratedLibrary.makeFullRunSnapshot(for: presentation, talkRevision: currentRev, startKind: .entireTalk)
        )
        let newRun = try FullRunTestFixtures.saveSyntheticFullRun(
            SyntheticFullRunSpec(
                snapshot: fullSnapshot,
                startedAt: Date(),
                duration: 2.0,
                transitionTimes: [0, 1.0]
            ),
            in: migratedAttempts,
            workspace: workspace
        )
        #expect(newRun.isFullRun)
        #expect(try migratedAttempts.fetchFullRuns(forPresentationID: presentation.id).count == 1)
        #expect(try migratedAttempts.fetchSectionTakes(forPresentationID: presentation.id).count == 2)
    }

    func renderAllTask7Screens(
        talk: FullRunTestFixtures.FourSectionTalk,
        run1: AttemptRecord,
        run2: AttemptRecord,
        container: ModelContainer,
        appearance: (ColorScheme, DynamicTypeSize)
    ) {
        let target = FullRunTarget(presentationID: talk.presentation.id, talkRevisionID: talk.talkRevision.id)
        renderSmoke(
            FullRunView(presentation: talk.presentation, target: target, onOpenReview: { _ in }),
            container: container,
            appearance: appearance
        )
        renderSmoke(
            TakeReview(attemptID: run2.id, onRetry: { _ in }),
            container: container,
            appearance: appearance
        )
        renderSmoke(
            AttemptHistory(presentation: talk.presentation, onOpenReview: { _ in }),
            container: container,
            appearance: appearance
        )
        renderSmoke(
            AttemptComparisonView(
                presentation: talk.presentation,
                initialFirstID: run1.id,
                initialSecondID: run2.id,
                onOpenReview: { _ in }
            ),
            container: container,
            appearance: appearance
        )
    }

    func renderSmoke<V: View>(
        _ view: V,
        container: ModelContainer,
        appearance: (ColorScheme, DynamicTypeSize)
    ) {
        let host = UIHostingController(
            rootView: NavigationStack { view }
                .modelContainer(container)
                .environment(\.colorScheme, appearance.0)
                .environment(\.dynamicTypeSize, appearance.1)
        )
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == 393)
    }
}
