import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Attempt Store")
@MainActor
struct AttemptStoreTests {
    @Test("Save, reopen, and delete attempt with opaque relative audio path and metadata")
    func saveReopenAndDeleteAttempt() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "AttemptSave")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        let startedAt = Date(timeIntervalSince1970: 1_764_000_000)
        let pending = try store.beginAttempt(
            snapshot: seeded.snapshot,
            practiceMode: .cueWords,
            isSilentRecall: false,
            startedAt: startedAt
        )
        let relativePath = try #require(pending.relativeAudioPath)
        #expect(!relativePath.hasPrefix("/"))
        #expect(!relativePath.contains(".."))
        #expect(!relativePath.localizedCaseInsensitiveContains("Keynote"))
        #expect(!relativePath.localizedCaseInsensitiveContains("Jordan"))
        #expect(!relativePath.localizedCaseInsensitiveContains("Spelum"))

        let audioURL = try store.resolvedAudioURL(for: relativePath)
        try PracticeTestFixtures.writeSyntheticAudio(to: audioURL, durationSeconds: 1.5)

        let marker1 = AttemptMarker(timestamp: 0.4, label: "Handoff beat")
        let marker2 = AttemptMarker(timestamp: 1.1, label: "Reveal line")
        let finalized = try store.finalizeAttempt(
            AttemptFinalizationInput(
                id: pending.id,
                snapshot: seeded.snapshot,
                practiceMode: .cueWords,
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(1.5),
                relativeAudioPath: relativePath,
                elapsedDuration: 1.5,
                revealCount: 2,
                markers: [marker2, marker1],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil
            )
        )
        #expect(finalized.status == .ready)
        #expect(finalized.playableDuration > 1.2)
        #expect(finalized.markers.map(\.label) == ["Handoff beat", "Reveal line"])

        try verifyReopenAndDelete(
            attemptID: pending.id,
            seeded: seeded,
            expectedRelativePath: relativePath,
            audioURL: audioURL,
            workspace: workspace
        )
    }

    @Test("Deleting one attempt preserves all other attempts and their audio files")
    func deletionNeverRemovesAnotherAttemptsAudio() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "AttemptDelete")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        let first = try PracticeTestFixtures.saveSyntheticTake(
            in: store,
            snapshot: seeded.snapshot,
            mode: .memory,
            durationSeconds: 1.0
        )
        let second = try PracticeTestFixtures.saveSyntheticTake(
            in: store,
            snapshot: seeded.snapshot,
            mode: .memory,
            durationSeconds: 1.4
        )
        #expect(first.audioURL != second.audioURL)

        try store.deleteAttempt(first.attempt)
        try store.deleteAttempt(id: first.attempt.id)

        #expect(!FileManager.default.fileExists(atPath: first.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: second.audioURL.path))
        let remaining = try store.fetchAttempts(forSectionID: seeded.section.sectionID, in: seeded.presentation.id)
        #expect(remaining.map(\.id) == [second.attempt.id])
    }

    @Test("Failed delete on read-only store rolls back and preserves audio file")
    func readOnlyDeletePreservesAudioAndRecord() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "AttemptReadOnly")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let saved = try PracticeTestFixtures.saveSyntheticTake(
            in: store,
            snapshot: seeded.snapshot,
            mode: .fullScript,
            durationSeconds: 0.9
        )

        let readOnly = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL, allowsSave: false)
        let readOnlyStore = AttemptStore(modelContext: readOnly.mainContext, storageRootURL: workspace.storageRoot)
        let fetched = try #require(try readOnlyStore.attempt(withID: saved.attempt.id))
        #expect(throws: Error.self) {
            try readOnlyStore.deleteAttempt(fetched)
        }
        #expect(FileManager.default.fileExists(atPath: saved.audioURL.path))

        let reopened = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let reopenedStore = AttemptStore(modelContext: reopened.mainContext, storageRootURL: workspace.storageRoot)
        #expect(try reopenedStore.attempt(withID: saved.attempt.id) != nil)
    }

    @Test("Relaunch deterministically recovers unfinished in-progress takes and pending save sidecars")
    func relaunchRecoveryHandlesPlayableCorruptAndSidecarSaves() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "AttemptRecovery")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: container.mainContext)
        )
        let store = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        let playablePending = try store.beginAttempt(
            snapshot: seeded.snapshot,
            practiceMode: .cueWords,
            isSilentRecall: false
        )
        let playableURL = try store.resolvedAudioURL(for: try #require(playablePending.relativeAudioPath))
        try PracticeTestFixtures.writeSyntheticAudio(to: playableURL, durationSeconds: 1.1)

        let corruptPending = try store.beginAttempt(
            snapshot: seeded.snapshot,
            practiceMode: .memory,
            isSilentRecall: false
        )
        let corruptURL = try store.resolvedAudioURL(for: try #require(corruptPending.relativeAudioPath))
        try Data().write(to: corruptURL)

        let sidecarID = UUID()
        let sidecarPath = AttemptStore.opaqueRelativeAudioPath(for: sidecarID)
        let sidecarURL = try store.resolvedAudioURL(for: sidecarPath)
        try PracticeTestFixtures.writeSyntheticAudio(to: sidecarURL, durationSeconds: 1.6)
        store.writePendingSaveManifest(
            PendingSaveManifest(
                attemptID: sidecarID,
                snapshot: seeded.snapshot,
                practiceMode: .memory,
                startedAt: Date().addingTimeInterval(-5),
                finishedAt: Date(),
                relativeAudioPath: sidecarPath,
                elapsedDuration: 1.6,
                revealCount: 3,
                markers: [AttemptMarker(timestamp: 0.7, label: "Cue")],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: "Storage save failed during stop."
            )
        )

        let targets = RecoveryTargets(
            playableID: playablePending.id,
            corruptID: corruptPending.id,
            sidecarID: sidecarID,
            playableURL: playableURL,
            corruptURL: corruptURL,
            sidecarURL: sidecarURL
        )
        try verifyRecoveredAttempts(targets: targets, workspace: workspace)
    }

    @Test("Older Task 2 library store migrates cleanly and preserves revisions alongside new attempts")
    func olderTask2LibraryMigratesCleanly() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "AttemptMigration")
        defer { workspace.cleanup() }

        let task2Schema = Schema([
            PresentationRecord.self,
            TalkRevisionRecord.self,
            TalkRevisionEntryRecord.self,
            SectionRevisionRecord.self
        ])
        let legacyConfig = ModelConfiguration(schema: task2Schema, url: workspace.storeURL)
        let legacyContainer = try ModelContainer(for: task2Schema, configurations: [legacyConfig])
        let seeded = try PracticeTestFixtures.seedPresentation(
            in: PresentationStore(modelContext: legacyContainer.mainContext)
        )
        let originalSnapshot = seeded.snapshot
        let originalText = seeded.section.text

        let upgradedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: upgradedContainer.mainContext)
        let attempts = AttemptStore(modelContext: upgradedContainer.mainContext, storageRootURL: workspace.storageRoot)

        let presentation = try #require(try library.presentation(withID: originalSnapshot.presentationID))
        let section = try #require(try library.sectionRevision(withID: originalSnapshot.sectionRevisionID))
        #expect(section.text == originalText)
        #expect(section.exactPhrase == "Today we unveil Spelum offline.")

        let attempt = try attempts.finalizeAttempt(
            AttemptFinalizationInput(
                id: UUID(),
                snapshot: originalSnapshot,
                practiceMode: .memory,
                startedAt: Date(),
                relativeAudioPath: nil,
                elapsedDuration: 4.5,
                revealCount: 1,
                markers: [AttemptMarker(timestamp: 2.0, label: "Pause")],
                isSilentRecall: true,
                interrupted: false,
                interruptionReason: nil
            )
        )

        var updatedDraft = SectionDraft(record: section)
        updatedDraft.text = "Jordan: Completely rewritten reveal script."
        let newerRev = try library.saveSectionEdit(
            in: presentation,
            sectionID: originalSnapshot.sectionID,
            draft: updatedDraft
        )
        #expect(newerRev.id != originalSnapshot.talkRevisionID)

        let pinnedSection = try #require(try library.sectionRevision(withID: attempt.sectionRevisionID))
        #expect(pinnedSection.text == originalText)
        let pinnedTalk = try #require(try library.talkRevision(withID: attempt.talkRevisionID))
        let pinnedHandoff = try #require(library.handoffContext(forSectionID: attempt.sectionID, in: pinnedTalk))
        #expect(pinnedHandoff.effectiveCueText == "Alex: Welcome to our rehearsal preview.")
    }

    @Test("Path traversal or absolute audio paths are rejected")
    func unsafeAudioPathsAreRejected() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "AttemptPathSafety")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)

        #expect(throws: AttemptStoreError.invalidRelativeAudioPath) {
            _ = try attemptStore.resolvedAudioURL(for: "/etc/passwd")
        }
        #expect(throws: AttemptStoreError.invalidRelativeAudioPath) {
            _ = try attemptStore.resolvedAudioURL(for: "../outside.m4a")
        }
        #expect(throws: AttemptStoreError.invalidRelativeAudioPath) {
            _ = try attemptStore.resolvedAudioURL(for: "")
        }
    }
}

private extension AttemptStoreTests {
    struct RecoveryTargets {
        let playableID: UUID
        let corruptID: UUID
        let sidecarID: UUID
        let playableURL: URL
        let corruptURL: URL
        let sidecarURL: URL
    }

    func verifyReopenAndDelete(
        attemptID: UUID,
        seeded: SeededSectionFixture,
        expectedRelativePath: String,
        audioURL: URL,
        workspace: PracticeTestWorkspace
    ) throws {
        let reopenedContainer = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let reopenedAttempts = AttemptStore(
            modelContext: reopenedContainer.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let fetched = try #require(try reopenedAttempts.attempt(withID: attemptID))
        #expect(fetched.talkRevisionID == seeded.talkRevision.id)
        #expect(fetched.sectionID == seeded.section.sectionID)
        #expect(fetched.sectionRevisionID == seeded.section.revisionID)
        #expect(fetched.practiceMode == .cueWords)
        #expect(fetched.relativeAudioPath == expectedRelativePath)
        #expect(fetched.playableDuration > 1.2)
        #expect(fetched.revealCount == 2)
        #expect(fetched.markers.count == 2)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        try reopenedAttempts.deleteAttempt(fetched)
        #expect(try reopenedAttempts.attempt(withID: attemptID) == nil)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    }

    func verifyRecoveredAttempts(
        targets: RecoveryTargets,
        workspace: PracticeTestWorkspace
    ) throws {
        let reopened = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let store = AttemptStore(modelContext: reopened.mainContext, storageRootURL: workspace.storageRoot)
        let summary = try store.recoverUnfinishedAttempts()
        #expect(summary.recoveredPlayableCount == 2)
        #expect(summary.recoveredWithoutAudioCount == 1)

        let recoveredPlayable = try #require(try store.attempt(withID: targets.playableID))
        #expect(recoveredPlayable.status == .interrupted)
        #expect(recoveredPlayable.playableDuration > 0.9)
        #expect(FileManager.default.fileExists(atPath: targets.playableURL.path))

        let recoveredCorrupt = try #require(try store.attempt(withID: targets.corruptID))
        #expect(recoveredCorrupt.status == .interrupted)
        #expect(recoveredCorrupt.playableDuration == 0)
        #expect(recoveredCorrupt.relativeAudioPath == nil)
        #expect(!FileManager.default.fileExists(atPath: targets.corruptURL.path))

        let recoveredSidecar = try #require(try store.attempt(withID: targets.sidecarID))
        #expect(recoveredSidecar.status == .interrupted)
        #expect(recoveredSidecar.playableDuration > 1.3)
        #expect(recoveredSidecar.revealCount == 3)
        #expect(recoveredSidecar.markers.count == 1)
        #expect(FileManager.default.fileExists(atPath: targets.sidecarURL.path))

        let secondPass = try store.recoverUnfinishedAttempts()
        #expect(secondPass.totalRecoveredCount == 0)
    }
}
