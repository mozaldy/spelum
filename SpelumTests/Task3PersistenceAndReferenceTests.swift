import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 3 Persistence, Missing Parent, and Reference Safety")
@MainActor
struct Task3PersistenceAndReferenceTests {
    @Test("Deleting presentation cleans pending silent-recall manifest without DB row and prevents orphan recovery")
    func deletingPresentationCleansPendingSilentRecallManifestWithoutDBRow() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3SilentOrphan")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        var shouldFailSave = true
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            saveContext: { context in
                if shouldFailSave { throw NSError(domain: "SilentSaveFail", code: 500) }
                try context.save()
            }
        )
        let attemptID = UUID()
        #expect(throws: Error.self) {
            _ = try store.finalizeAttempt(
                AttemptFinalizationInput(
                    id: attemptID,
                    snapshot: seeded.snapshot,
                    practiceMode: .memory,
                    startedAt: Date().addingTimeInterval(-3),
                    relativeAudioPath: nil,
                    elapsedDuration: 3.0,
                    revealCount: 1,
                    markers: [],
                    isSilentRecall: true,
                    interrupted: false,
                    interruptionReason: nil
                )
            )
        }
        #expect(try store.attempt(withID: attemptID) == nil)

        shouldFailSave = false
        try store.deletePresentationAndAttempts(seeded.presentation)

        let reopened = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let reopenedStore = AttemptStore(modelContext: reopened.mainContext, storageRootURL: workspace.storageRoot)
        let summary = try reopenedStore.recoverUnfinishedAttempts()
        #expect(summary.totalRecoveredCount == 0)
        #expect(try reopenedStore.attempt(withID: attemptID) == nil)
        let orphans = try reopenedStore.fetchAttempts(
            forPresentationID: seeded.presentation.id,
            includeInProgress: true
        )
        #expect(orphans.isEmpty)
    }

    @Test("Mid-cleanup failure during presentation delete and recovery preserves retry and completes cleanly")
    func midCleanupFailureDuringDeleteAndRecoveryCompletesOnRetry() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3MidCleanup")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let deletedTalk = try PracticeTestFixtures.seedPresentation(in: library, title: "Deleted Talk")
        let survivingTalk = try PracticeTestFixtures.seedPresentation(in: library, title: "Surviving Talk")

        let fixture = try seedOrphanAndSurvivingPendingArtifacts(
            in: container.mainContext,
            workspace: workspace,
            deletedTalk: deletedTalk,
            survivingTalk: survivingTalk
        )

        var failOrphanAudioDelete = true
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            removeFileItem: { url in
                if failOrphanAudioDelete && url.lastPathComponent == fixture.orphanAudioURL.lastPathComponent {
                    throw NSError(domain: "SimulatedMidCleanupIOError", code: 28)
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        // Presentation deletion fails mid-cleanup after committing DB delete: manifest stays for recovery retry.
        #expect(throws: Error.self) {
            try store.deletePresentationAndAttempts(deletedTalk.presentation)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.orphanAudioURL.path))
        #expect(try store.loadPendingSaveManifest(for: fixture.orphanAudioID) != nil)
        #expect(try store.loadPendingSaveManifest(for: fixture.orphanSilentID) == nil)

        // First recovery pass still fails on the blocked file, yet recovers the surviving talk cleanly.
        #expect(throws: Error.self) {
            _ = try store.recoverUnfinishedAttempts()
        }
        #expect(try store.attempt(withID: fixture.validID) != nil)
        #expect(try store.attempt(withID: fixture.orphanAudioID) == nil)
        #expect(try store.attempt(withID: fixture.orphanInProgressID) == nil)
        #expect(try store.loadPendingSaveManifest(for: fixture.orphanAudioID) != nil)

        // Retry recovery once IO recovers: remaining orphan audio + manifest clean up cleanly.
        failOrphanAudioDelete = false
        let retrySummary = try store.recoverUnfinishedAttempts()
        #expect(retrySummary.totalRecoveredCount == 0)
        #expect(retrySummary.removedStaleSidecarCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.orphanAudioURL.path))
        #expect(try store.loadPendingSaveManifest(for: fixture.orphanAudioID) == nil)

        // Repeated recovery is idempotent.
        let finalSummary = try store.recoverUnfinishedAttempts()
        #expect(finalSummary.totalRecoveredCount == 0)
        #expect(finalSummary.removedStaleSidecarCount == 0)
    }

    @Test("Orphan in-progress DB row with missing parent retries mid-cleanup failure without resurrection")
    func orphanInProgressRowWithMissingParentIsCleanedWithoutResurrection() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3OrphanInProgress")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library)

        var failAudioDelete = true
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            removeFileItem: { url in
                if failAudioDelete {
                    throw NSError(domain: "OrphanInProgressDeleteFail", code: 13)
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let pending = try store.beginAttempt(
            snapshot: seeded.snapshot,
            practiceMode: .cueWords,
            isSilentRecall: false
        )
        let audioURL = try store.resolvedAudioURL(for: try #require(pending.relativeAudioPath))
        try PracticeTestFixtures.writeSyntheticAACM4A(to: audioURL, durationSeconds: 1.0)

        try library.performAtomicWrite {
            container.mainContext.delete(seeded.presentation)
        }

        // Mid-cleanup audio deletion failure preserves the orphan row so the next recovery retries it.
        #expect(throws: Error.self) {
            _ = try store.recoverUnfinishedAttempts()
        }
        #expect(try store.attempt(withID: pending.id) != nil)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        failAudioDelete = false
        let summary = try store.recoverUnfinishedAttempts()
        #expect(summary.totalRecoveredCount == 0)
        #expect(summary.removedStaleSidecarCount == 1)
        #expect(try store.attempt(withID: pending.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test("Failed path-reference fetch never deletes audio files during delete or cleanup")
    func failedPathReferenceFetchNeverDeletesAudioFile() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3UnknownRefs")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        var failReferenceFetch = false
        let store = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot,
            fetchAudioPathReferences: { context, relativePath in
                if failReferenceFetch { throw NSError(domain: "ReferenceFetchFailed", code: 500) }
                let descriptor = FetchDescriptor<AttemptRecord>(
                    predicate: #Predicate<AttemptRecord> { record in
                        record.relativeAudioPath == relativePath
                    }
                )
                return try context.fetch(descriptor)
            }
        )

        let saved = try PracticeTestFixtures.saveSyntheticTake(
            in: store,
            snapshot: seeded.snapshot,
            mode: .fullScript,
            durationSeconds: 1.1
        )
        let relativePath = try #require(saved.attempt.relativeAudioPath)

        failReferenceFetch = true
        #expect(throws: Error.self) {
            _ = try store.removeAudioFileIfUnreferenced(relativePath: relativePath)
        }
        #expect(FileManager.default.fileExists(atPath: saved.audioURL.path))

        try store.deleteAttempt(saved.attempt)
        #expect(try store.attempt(withID: saved.attempt.id) == nil)
        #expect(FileManager.default.fileExists(atPath: saved.audioURL.path))

        failReferenceFetch = false
        #expect(try store.removeAudioFileIfUnreferenced(relativePath: relativePath))
        #expect(!FileManager.default.fileExists(atPath: saved.audioURL.path))
    }

    @Test("Attached sibling DB records, surviving manifests, and unreadable manifests protect shared audio")
    func siblingRecordsAndManifestsProtectSharedAudioAcrossDeletionAndRecovery() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T3SiblingAudio")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let talkA = try PracticeTestFixtures.seedPresentation(in: library, title: "Talk A")
        let talkB = try PracticeTestFixtures.seedPresentation(in: library, title: "Talk B")
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        let sharedPath = AttemptStore.opaqueRelativeAudioPath(for: UUID())
        let sharedURL = try store.resolvedAudioURL(for: sharedPath)
        try PracticeTestFixtures.writeSyntheticAACM4A(to: sharedURL, durationSeconds: 1.1)

        let attemptA = try store.finalizeAttempt(
            AttemptFinalizationInput(
                id: UUID(),
                snapshot: talkA.snapshot,
                practiceMode: .cueWords,
                startedAt: Date().addingTimeInterval(-3),
                relativeAudioPath: sharedPath,
                elapsedDuration: 1.1,
                revealCount: 0,
                markers: [],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil
            )
        )
        let siblingManifestID = UUID()
        store.writePendingSaveManifest(
            Task3ManifestTestHelper.makeManifest(
                attemptID: siblingManifestID,
                snapshot: talkB.snapshot,
                mode: .memory,
                relativeAudioPath: sharedPath,
                elapsedDuration: 1.1,
                revealCount: 1
            )
        )

        try store.deletePresentationAndAttempts(talkA.presentation)
        #expect(try store.attempt(withID: attemptA.id) == nil)
        #expect(FileManager.default.fileExists(atPath: sharedURL.path))

        let recoveredSummary = try store.recoverUnfinishedAttempts()
        #expect(recoveredSummary.recoveredPlayableCount == 1)
        let siblingAttempt = try #require(try store.attempt(withID: siblingManifestID))
        #expect(siblingAttempt.hasPlayableAudio)

        try verifyCorruptManifestBlocksDeletionUntilCleared(
            store: store,
            workspace: workspace,
            siblingAttempt: siblingAttempt,
            sharedPath: sharedPath,
            sharedURL: sharedURL
        )
    }
}

private extension Task3PersistenceAndReferenceTests {
    struct OrphanCleanupFixture {
        let orphanAudioID: UUID
        let orphanSilentID: UUID
        let orphanInProgressID: UUID
        let validID: UUID
        let orphanAudioURL: URL
    }

    func seedOrphanAndSurvivingPendingArtifacts(
        in context: ModelContext,
        workspace: PracticeTestWorkspace,
        deletedTalk: SeededSectionFixture,
        survivingTalk: SeededSectionFixture
    ) throws -> OrphanCleanupFixture {
        let store = AttemptStore(modelContext: context, storageRootURL: workspace.storageRoot)

        let orphanAudioID = UUID()
        let orphanAudioPath = AttemptStore.opaqueRelativeAudioPath(for: orphanAudioID)
        let orphanAudioURL = try store.resolvedAudioURL(for: orphanAudioPath)
        try PracticeTestFixtures.writeSyntheticAACM4A(to: orphanAudioURL, durationSeconds: 1.0)
        store.writePendingSaveManifest(
            Task3ManifestTestHelper.makeManifest(
                attemptID: orphanAudioID,
                snapshot: deletedTalk.snapshot,
                relativeAudioPath: orphanAudioPath
            )
        )

        let orphanSilentID = UUID()
        store.writePendingSaveManifest(
            Task3ManifestTestHelper.makeManifest(
                attemptID: orphanSilentID,
                snapshot: deletedTalk.snapshot,
                mode: .memory,
                isSilentRecall: true
            )
        )

        let orphanInProgress = try store.beginAttempt(
            snapshot: deletedTalk.snapshot,
            practiceMode: .fullScript,
            isSilentRecall: true
        )

        let validID = UUID()
        let validPath = AttemptStore.opaqueRelativeAudioPath(for: validID)
        let validURL = try store.resolvedAudioURL(for: validPath)
        try PracticeTestFixtures.writeSyntheticAACM4A(to: validURL, durationSeconds: 1.2)
        store.writePendingSaveManifest(
            Task3ManifestTestHelper.makeManifest(
                attemptID: validID,
                snapshot: survivingTalk.snapshot,
                relativeAudioPath: validPath
            )
        )

        return OrphanCleanupFixture(
            orphanAudioID: orphanAudioID,
            orphanSilentID: orphanSilentID,
            orphanInProgressID: orphanInProgress.id,
            validID: validID,
            orphanAudioURL: orphanAudioURL
        )
    }

    func verifyCorruptManifestBlocksDeletionUntilCleared(
        store: AttemptStore,
        workspace: PracticeTestWorkspace,
        siblingAttempt: AttemptRecord,
        sharedPath: String,
        sharedURL: URL
    ) throws {
        let corruptURL = workspace.storageRoot
            .appendingPathComponent(AttemptStore.pendingSavesSubdirectoryName)
            .appendingPathComponent("corrupt-manifest.json")
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: corruptURL)

        try store.deleteAttempt(siblingAttempt)
        #expect(FileManager.default.fileExists(atPath: sharedURL.path))

        try FileManager.default.removeItem(at: corruptURL)
        #expect(try store.removeAudioFileIfUnreferenced(relativePath: sharedPath))
        #expect(!FileManager.default.fileExists(atPath: sharedURL.path))
    }
}
