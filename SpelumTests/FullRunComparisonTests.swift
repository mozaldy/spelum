import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Attempt History, Comparison Defaults & Independent Replay")
@MainActor
struct FullRunComparisonTests {
    @Test("Comparison defaults to same revision and scope and flags mismatched scope, revision, or kind")
    func comparisonScopeAndDefaultPairSelection() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7Compare")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)

        let seeded = try seedComparisonAttempts(
            talk: talk,
            library: library,
            attemptStore: attemptStore,
            workspace: workspace
        )

        let allRecords = try attemptStore.fetchAttempts(forPresentationID: talk.presentation.id)
        let actualIDs: [UUID] = allRecords.map(\.id)
        let expectedIDs: [UUID] = [
            seeded.handoffRun.id,
            seeded.sectionTake2.id,
            seeded.run2.id,
            seeded.sectionTake1.id,
            seeded.run1.id
        ]
        #expect(actualIDs == expectedIDs)

        let descriptors = allRecords.map(ComparableAttemptDescriptor.init(record:))
        let currentSecRevIDs = Set(talk.sections.map(\.revisionID))

        try verifyFullRunComparison(
            seeded: seeded,
            descriptors: descriptors,
            talk: talk,
            currentSecRevIDs: currentSecRevIDs
        )
        try verifySectionAndMixedComparison(
            seeded: seeded,
            descriptors: descriptors,
            talk: talk,
            currentSecRevIDs: currentSecRevIDs
        )
    }

    @Test("Comparison flags older revisions explicitly and handles duplicate transitions safely")
    func olderRevisionComparisonAndDuplicateTransitionSafety() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7CompareOlder")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let rev1Snapshot = try #require(
            library.makeFullRunSnapshot(for: talk.presentation, talkRevision: talk.talkRevision, startKind: .entireTalk)
        )
        let pair = try seedTwoRunsOnSnapshot(rev1Snapshot, in: attemptStore, workspace: workspace)
        let newRev = try editRevealToCreateRevisionTwo(talk: talk, in: library)
        let rev2SecIDs = Set(library.orderedSections(in: newRev).map(\.revisionID))

        let summary = AttemptComparisonEngine.buildSummary(
            first: ComparableAttemptDescriptor(record: pair.0),
            second: ComparableAttemptDescriptor(record: pair.1),
            currentTalkRevisionID: newRev.id,
            currentSectionRevisionIDs: rev2SecIDs
        )
        #expect(summary.earlierIsOlderRevision)
        #expect(summary.laterIsOlderRevision)
        if case .sameFullRunRevisionAndScope(_, _, let isOlder) = summary.scope {
            #expect(isOlder)
        } else {
            Issue.record("Expected sameFullRunRevisionAndScope marked as older revision")
        }

        let duplicateRun = try saveRunWithDuplicateTransition(
            snapshot: rev1Snapshot,
            in: attemptStore,
            workspace: workspace
        )
        let safeSummary = AttemptComparisonEngine.buildSummary(
            first: ComparableAttemptDescriptor(record: duplicateRun),
            second: ComparableAttemptDescriptor(record: pair.1),
            currentTalkRevisionID: newRev.id,
            currentSectionRevisionIDs: rev2SecIDs
        )
        #expect(safeSummary.fullRunSectionRows.count == 4)
    }

    @Test("Independent replay switches between two compared runs and deleting one keeps the other playable")
    func independentReplayAndDeleteOneKeepOther() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "T7CompareReplay")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let talk = try FullRunTestFixtures.seedFourSectionTalk(in: library)
        let snapshot = try #require(
            library.makeFullRunSnapshot(for: talk.presentation, talkRevision: talk.talkRevision, startKind: .entireTalk)
        )
        let pair = try seedTwoRunsOnSnapshot(snapshot, in: attemptStore, workspace: workspace)
        let earlier = pair.0
        let later = pair.1

        let player = TakeAudioPlayer(
            audioSessionManager: TrackingAudioSessionManager(),
            playerVolume: 0.0
        )
        let earlierURL = try #require(attemptStore.resolvedAudioURL(for: earlier))
        let laterURL = try #require(attemptStore.resolvedAudioURL(for: later))
        let earlierReveal = try #require(earlier.fullRunPayload?.transitions.first { $0.purpose == .reveal })
        let laterReveal = try #require(later.fullRunPayload?.transitions.first { $0.purpose == .reveal })

        player.load(url: earlierURL)
        player.seek(to: earlierReveal.startTime, autoPlay: false)
        #expect(abs(player.currentTime - earlierReveal.startTime) < 0.2)

        player.stop()
        player.load(url: laterURL)
        player.seek(to: laterReveal.startTime, autoPlay: false)
        #expect(abs(player.currentTime - laterReveal.startTime) < 0.2)

        try TakeReview.performDeletion(attempt: earlier, attemptStore: attemptStore, player: player)
        #expect(try attemptStore.attempt(withID: earlier.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: earlierURL.path))

        player.load(url: laterURL)
        #expect(player.isLoaded)
        #expect(player.duration > 2.5)
        player.stop()
    }
}

private extension FullRunComparisonTests {
    struct SeededComparisonSet {
        let run1: AttemptRecord
        let run2: AttemptRecord
        let handoffRun: AttemptRecord
        let sectionTake1: AttemptRecord
        let sectionTake2: AttemptRecord
    }

    func seedTwoRunsOnSnapshot(
        _ snapshot: FullRunSnapshot,
        in attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws -> (AttemptRecord, AttemptRecord) {
        let first = try FullRunTestFixtures.saveSyntheticFullRun(
            SyntheticFullRunSpec(
                snapshot: snapshot,
                startedAt: Date(timeIntervalSince1970: 100),
                duration: 3.2,
                revealCount: 2,
                transitionTimes: [0, 0.9, 1.8, 2.5]
            ),
            in: attemptStore,
            workspace: workspace
        )
        let second = try FullRunTestFixtures.saveSyntheticFullRun(
            SyntheticFullRunSpec(
                snapshot: snapshot,
                startedAt: Date(timeIntervalSince1970: 200),
                duration: 2.8,
                revealCount: 0,
                transitionTimes: [0, 0.6, 1.5, 2.2]
            ),
            in: attemptStore,
            workspace: workspace
        )
        return (first, second)
    }

    func editRevealToCreateRevisionTwo(
        talk: FullRunTestFixtures.FourSectionTalk,
        in library: PresentationStore
    ) throws -> TalkRevisionRecord {
        try library.saveSectionEdit(
            in: talk.presentation,
            sectionID: talk.sections[1].sectionID,
            draft: SectionDraft(
                title: "Updated Reveal",
                text: "Updated reveal wording for Revision 2.",
                speaker: "Jordan",
                speakerRole: .presenter,
                purpose: .reveal,
                cueWords: ["updated"],
                exactPhrase: nil,
                handoffCueOverride: nil
            )
        )
    }

    func seedComparisonAttempts(
        talk: FullRunTestFixtures.FourSectionTalk,
        library: PresentationStore,
        attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws -> SeededComparisonSet {
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
        let pair = try seedTwoRunsOnSnapshot(entireSnapshot, in: attemptStore, workspace: workspace)
        let handoffRun = try FullRunTestFixtures.saveSyntheticFullRun(
            SyntheticFullRunSpec(
                snapshot: handoffSnapshot,
                startedAt: Date(timeIntervalSince1970: 300),
                duration: 2.1,
                revealCount: 1,
                transitionTimes: [0, 0.7, 1.4]
            ),
            in: attemptStore,
            workspace: workspace
        )
        let revealSection = talk.sections[1]
        let sectionTake1 = try FullRunTestFixtures.saveSyntheticSectionTake(
            SyntheticSectionTakeSpec(
                presentation: talk.presentation,
                talkRevision: talk.talkRevision,
                section: revealSection,
                startedAt: Date(timeIntervalSince1970: 150),
                duration: 1.8,
                revealCount: 1
            ),
            in: attemptStore,
            workspace: workspace
        )
        let sectionTake2 = try FullRunTestFixtures.saveSyntheticSectionTake(
            SyntheticSectionTakeSpec(
                presentation: talk.presentation,
                talkRevision: talk.talkRevision,
                section: revealSection,
                startedAt: Date(timeIntervalSince1970: 250),
                duration: 1.5,
                revealCount: 0
            ),
            in: attemptStore,
            workspace: workspace
        )
        return SeededComparisonSet(
            run1: pair.0,
            run2: pair.1,
            handoffRun: handoffRun,
            sectionTake1: sectionTake1,
            sectionTake2: sectionTake2
        )
    }

    func verifyFullRunComparison(
        seeded: SeededComparisonSet,
        descriptors: [ComparableAttemptDescriptor],
        talk: FullRunTestFixtures.FourSectionTalk,
        currentSecRevIDs: Set<UUID>
    ) throws {
        let defaultFullRun = try #require(
            AttemptComparisonEngine.defaultComparablePair(
                from: descriptors,
                filter: .fullRuns,
                currentTalkRevisionID: talk.talkRevision.id,
                currentSectionRevisionIDs: currentSecRevIDs
            )
        )
        #expect(defaultFullRun.earlierID == seeded.run1.id)
        #expect(defaultFullRun.laterID == seeded.run2.id)
        #expect(defaultFullRun.scope.isDirectlyComparable)

        let fullRunSummary = AttemptComparisonEngine.buildSummary(
            first: ComparableAttemptDescriptor(record: seeded.run2),
            second: ComparableAttemptDescriptor(record: seeded.run1),
            currentTalkRevisionID: talk.talkRevision.id,
            currentSectionRevisionIDs: currentSecRevIDs
        )
        #expect(fullRunSummary.earlier.id == seeded.run1.id)
        #expect(fullRunSummary.later.id == seeded.run2.id)
        #expect(fullRunSummary.revealDelta == -2)
        #expect(fullRunSummary.durationDelta < 0)
        #expect(fullRunSummary.fullRunSectionRows.count == 4)

        let differentScope = AttemptComparisonEngine.buildSummary(
            first: ComparableAttemptDescriptor(record: seeded.run2),
            second: ComparableAttemptDescriptor(record: seeded.handoffRun),
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
    }

    func verifySectionAndMixedComparison(
        seeded: SeededComparisonSet,
        descriptors: [ComparableAttemptDescriptor],
        talk: FullRunTestFixtures.FourSectionTalk,
        currentSecRevIDs: Set<UUID>
    ) throws {
        let defaultSection = try #require(
            AttemptComparisonEngine.defaultComparablePair(
                from: descriptors,
                filter: .sectionTakes,
                currentTalkRevisionID: talk.talkRevision.id,
                currentSectionRevisionIDs: currentSecRevIDs
            )
        )
        #expect(defaultSection.earlierID == seeded.sectionTake1.id)
        #expect(defaultSection.laterID == seeded.sectionTake2.id)
        #expect(defaultSection.scope.isDirectlyComparable)

        let mixed = AttemptComparisonEngine.buildSummary(
            first: ComparableAttemptDescriptor(record: seeded.sectionTake1),
            second: ComparableAttemptDescriptor(record: seeded.run1),
            currentTalkRevisionID: talk.talkRevision.id,
            currentSectionRevisionIDs: currentSecRevIDs
        )
        #expect(mixed.scope == .mixedAttemptKinds)
        #expect(!mixed.scope.isDirectlyComparable)
    }

    func saveRunWithDuplicateTransition(
        snapshot: FullRunSnapshot,
        in attemptStore: AttemptStore,
        workspace: PracticeTestWorkspace
    ) throws -> AttemptRecord {
        let attemptID = UUID()
        let relPath = AttemptStore.opaqueRelativeAudioPath(for: attemptID)
        try FullRunTestFixtures.writeContinuousQuietAAC(
            to: workspace.storageRoot.appendingPathComponent(relPath),
            durationSeconds: 2.0
        )
        let firstSection = snapshot.sections[0]
        let dupTransition = FullRunSectionTransition(
            runIndex: 0,
            talkSectionIndex: 0,
            sectionID: firstSection.sectionID,
            sectionRevisionID: firstSection.sectionRevisionID,
            sectionTitle: firstSection.title,
            speaker: firstSection.speaker,
            speakerRole: firstSection.speakerRole,
            purpose: firstSection.purpose,
            startTime: 0,
            endTime: 1.0
        )
        let payload = FullRunAttemptPayload(
            snapshot: snapshot,
            transitions: [dupTransition, dupTransition],
            completionKind: .finishedEarly,
            reachedSectionCount: 1
        )
        return try attemptStore.finalizeAttempt(
            AttemptFinalizationInput(
                id: attemptID,
                snapshot: snapshot.makeAttemptSnapshotReference(),
                practiceMode: .cueWords,
                startedAt: Date(timeIntervalSince1970: 50),
                finishedAt: Date(timeIntervalSince1970: 52),
                relativeAudioPath: relPath,
                elapsedDuration: 2.0,
                revealCount: 0,
                markers: [],
                isSilentRecall: false,
                interrupted: false,
                interruptionReason: nil,
                attemptKind: .fullRun,
                fullRunPayload: payload
            )
        )
    }
}
