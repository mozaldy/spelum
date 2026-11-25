import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Task 2 Review Regressions")
@MainActor
struct Task2ReviewRegressionTests {
    fileprivate struct ThreeSpeakerTalk {
        let presentation: PresentationRecord
        let alexID: UUID
        let jordanID: UUID
        let samID: UUID
        let customRevision: TalkRevisionRecord
    }

    fileprivate struct SpeakerSpec {
        let title: String
        let speaker: String
        let role: SpeakerRole
        let purpose: SectionPurpose
        let handoffOverride: String?
    }

    @Test("Predecessor-dependent custom handoff is not misattributed after reorder or move to opening")
    func customHandoffNotMisattributedAfterReorder() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let store = PresentationStore(modelContext: container.mainContext)
        let talk = try makeThreeSpeakerTalk(in: store)

        // Reorder to [Alex, Sam, Jordan] — Jordan now follows Sam, not Alex
        _ = try store.reorderSections(
            in: talk.presentation,
            orderedSectionIDs: [talk.alexID, talk.samID, talk.jordanID]
        )
        let afterSam = try #require(store.handoffContext(forSectionID: talk.jordanID, in: talk.presentation))
        #expect(afterSam.precedingSpeaker == "Sam")
        #expect(!afterSam.isCustomCue)
        #expect(afterSam.effectiveCueText == "Sam wrap-up line.")

        // Historical revision before reorder still preserves Alex -> Jordan custom handoff
        let historical = try #require(store.handoffContext(forSectionID: talk.jordanID, in: talk.customRevision))
        #expect(historical.precedingSpeaker == "Alex")
        #expect(historical.isCustomCue)
        #expect(historical.effectiveCueText == "Wait for Alex’s nod before revealing.")

        // Opening cue on Alex must not be attributed to Sam when Sam moves ahead of Alex
        let alexRecord = try #require(store.orderedSections(for: talk.presentation).first)
        var alexOpeningDraft = SectionDraft(record: alexRecord)
        alexOpeningDraft.handoffCueOverride = "Breathe and make eye contact."
        _ = try store.saveSectionEdit(in: talk.presentation, sectionID: talk.alexID, draft: alexOpeningDraft)
        #expect(store.handoffContext(forSectionID: talk.alexID, in: talk.presentation)?.isCustomCue == true)

        _ = try store.reorderSections(
            in: talk.presentation,
            orderedSectionIDs: [talk.samID, talk.alexID, talk.jordanID]
        )
        let alexAfterSam = try #require(store.handoffContext(forSectionID: talk.alexID, in: talk.presentation))
        #expect(!alexAfterSam.isCustomCue)
        #expect(alexAfterSam.effectiveCueText == "Sam wrap-up line.")
    }

    @Test("Splitting predecessor rebinds follower handoff to tail half; deleting predecessor clears it")
    func customHandoffAcrossSplitAndDelete() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let store = PresentationStore(modelContext: container.mainContext)
        let talk = try makeThreeSpeakerTalk(in: store)

        // Split Alex into [Alex1, Alex2] before Jordan — Jordan's custom cue rebinds to Alex2
        let alexRecord = try #require(store.orderedSections(for: talk.presentation).first)
        let splitIndex = try #require(alexRecord.text.range(of: "Alex closing")).lowerBound
        let alexSplit = try store.splitSection(in: talk.presentation, sectionID: talk.alexID, at: splitIndex)

        let jordanAfterSplit = try #require(store.handoffContext(forSectionID: talk.jordanID, in: talk.presentation))
        #expect(jordanAfterSplit.precedingSectionID == alexSplit.secondSection.sectionID)
        #expect(jordanAfterSplit.isCustomCue)
        #expect(jordanAfterSplit.effectiveCueText == "Wait for Alex’s nod before revealing.")

        // Moving Alex1 immediately before Jordan invalidates the Alex2 -> Jordan custom cue
        _ = try store.reorderSections(
            in: talk.presentation,
            orderedSectionIDs: [
                alexSplit.secondSection.sectionID,
                alexSplit.firstSection.sectionID,
                talk.jordanID,
                talk.samID
            ]
        )
        let jordanAfterAlex1 = try #require(store.handoffContext(forSectionID: talk.jordanID, in: talk.presentation))
        #expect(!jordanAfterAlex1.isCustomCue)
        #expect(jordanAfterAlex1.effectiveCueText == "Alex line one.")

        // Deleting predecessor clears custom cue while earlier revision remains immutable
        let talk2 = try makeThreeSpeakerTalk(in: store)
        _ = try store.deleteSection(in: talk2.presentation, sectionID: talk2.alexID)
        let jordanNowFirst = try #require(store.handoffContext(forSectionID: talk2.jordanID, in: talk2.presentation))
        #expect(jordanNowFirst.isFirstSection)
        #expect(!jordanNowFirst.isCustomCue)
        #expect(jordanNowFirst.effectiveCueText == nil)
        #expect(store.handoffContext(forSectionID: talk2.jordanID, in: talk2.customRevision)?.isCustomCue == true)
    }

    @Test("Legacy custom handoff records without transition metadata work and resist reorder misattribution")
    func legacyCustomHandoffRecordsResolveOriginAndResistMisattribution() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let store = PresentationStore(modelContext: container.mainContext)
        let talk = try makeThreeSpeakerTalk(in: store)

        let currentRev = try #require(store.currentTalkRevision(for: talk.presentation))
        let jordanRecord = try #require(
            store.orderedSections(in: currentRev).first { $0.sectionID == talk.jordanID }
        )
        jordanRecord.handoffCueSourceSectionID = nil
        jordanRecord.handoffCueIsOpening = nil
        try store.modelContext.save()

        let legacyActive = try #require(store.handoffContext(forSectionID: talk.jordanID, in: currentRev))
        #expect(legacyActive.isCustomCue)
        #expect(legacyActive.effectiveCueText == "Wait for Alex’s nod before revealing.")

        _ = try store.reorderSections(
            in: talk.presentation,
            orderedSectionIDs: [talk.alexID, talk.samID, talk.jordanID]
        )
        let afterReorder = try #require(store.handoffContext(forSectionID: talk.jordanID, in: talk.presentation))
        #expect(!afterReorder.isCustomCue)
        #expect(afterReorder.effectiveCueText == "Sam wrap-up line.")
        #expect(store.handoffContext(forSectionID: talk.jordanID, in: currentRev)?.isCustomCue == true)
    }

    @Test("Splitting inside a marked exact phrase is protected and supports before, after, and explicit clear")
    func splitInsideExactPhraseProtectionAndChoices() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let store = PresentationStore(modelContext: container.mainContext)

        let text = "Intro line.\nToday we introduce Spelum live.\nClosing line."
        let presentation = try store.importScript(text: text, title: "Exact Phrase Guard")
        let section = try #require(store.orderedSections(for: presentation).first)
        var draft = SectionDraft(record: section)
        draft.exactPhrase = "Today we introduce Spelum live."
        _ = try store.saveSectionEdit(in: presentation, sectionID: section.sectionID, draft: draft)

        let beforeRevCount = presentation.talkRevisions.count
        let insideIdx = try #require(text.range(of: "Spelum")).lowerBound

        #expect(throws: SectionEditError.splitCrossesExactPhrase) {
            try store.splitSection(in: presentation, sectionID: section.sectionID, at: insideIdx)
        }
        #expect(presentation.talkRevisions.count == beforeRevCount)

        let conflict = try #require(
            PresentationStore.exactPhraseSplitConflict(in: text, exactPhrase: draft.exactPhrase, at: insideIdx)
        )
        let beforePhraseIdx = try #require(conflict.beforePhraseSplitIndex)
        let afterPhraseIdx = try #require(conflict.afterPhraseSplitIndex)

        let keptOnSecond = try store.splitSection(in: presentation, sectionID: section.sectionID, at: beforePhraseIdx)
        #expect(keptOnSecond.firstSection.exactPhrase == nil)
        #expect(keptOnSecond.secondSection.exactPhrase == "Today we introduce Spelum live.")

        let talkAfter = try store.importScript(text: text, title: "Keep First")
        let secAfter = try #require(store.orderedSections(for: talkAfter).first)
        _ = try store.saveSectionEdit(in: talkAfter, sectionID: secAfter.sectionID, draft: draft)
        let keptOnFirst = try store.splitSection(in: talkAfter, sectionID: secAfter.sectionID, at: afterPhraseIdx)
        #expect(keptOnFirst.firstSection.exactPhrase == "Today we introduce Spelum live.")
        #expect(keptOnFirst.secondSection.exactPhrase == nil)

        let talkClear = try store.importScript(text: text, title: "Clear Choice")
        let secClear = try #require(store.orderedSections(for: talkClear).first)
        _ = try store.saveSectionEdit(in: talkClear, sectionID: secClear.sectionID, draft: draft)
        let cleared = try store.splitSection(
            in: talkClear,
            sectionID: secClear.sectionID,
            at: insideIdx,
            exactPhrasePolicy: .clearExactPhrase
        )
        #expect(cleared.firstSection.exactPhrase == nil)
        #expect(cleared.secondSection.exactPhrase == nil)
    }

    @Test("Splitting preserves all cue words and places second-half cue words on the second section")
    func splitPlacesCueWordsIntelligibly() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let store = PresentationStore(modelContext: container.mainContext)

        let text = "Open with calm story.\n\nReveal Spelum live demo."
        let presentation = try store.importScript(text: text, title: "Cue Placement")
        let section = try #require(store.orderedSections(for: presentation).first)
        var draft = SectionDraft(record: section)
        draft.cueWords = ["calm story", "breathe", "live demo"]
        _ = try store.saveSectionEdit(in: presentation, sectionID: section.sectionID, draft: draft)

        let splitRange = try #require(text.range(of: "Reveal Spelum"))
        let split = try store.splitSection(
            in: presentation,
            sectionID: section.sectionID,
            at: splitRange.lowerBound
        )

        #expect(split.firstSection.cueWords == ["calm story", "breathe"])
        #expect(split.secondSection.cueWords == ["live demo"])
    }

    @Test("Stable cue-word editing and deletion while focused never crashes or corrupts rows")
    func stableCueWordEditingAndDeletionWhileFocused() {
        let first = EditableCueWord(text: "open strong")
        let second = EditableCueWord(text: "pause before reveal")
        let third = EditableCueWord(text: "demo flow")
        var items = [first, second, third]
        var focusedID: UUID? = second.id

        CueWordListHelper.remove(id: first.id, from: &items, focusedID: &focusedID)
        #expect(focusedID == second.id)
        #expect(items.map(\.id) == [second.id, third.id])

        CueWordListHelper.updateText("hold two beats", for: second.id, in: &items)
        #expect(items[0].text == "hold two beats")
        #expect(items[1].text == "demo flow")

        CueWordListHelper.remove(id: second.id, from: &items, focusedID: &focusedID)
        #expect(focusedID == nil)
        CueWordListHelper.updateText("stale callback", for: second.id, in: &items)
        #expect(items.map(\.text) == ["demo flow"])

        CueWordListHelper.remove(at: IndexSet(integer: 99), from: &items, focusedID: &focusedID)
        #expect(CueWordListHelper.cleanedCueWords(from: items, pendingNewWord: "  final smile ") == [
            "demo flow",
            "final smile"
        ])
    }
}

private extension Task2ReviewRegressionTests {
    func makeThreeSpeakerTalk(in store: PresentationStore) throws -> ThreeSpeakerTalk {
        let script = "Alex line one.\nAlex closing line.\n\nJordan reveal line.\n\nSam wrap-up line."
        let presentation = try store.importScript(text: script, title: "Three Speakers")
        let initial = try #require(store.orderedSections(for: presentation).first)
        let jordanRange = try #require(initial.text.range(of: "Jordan reveal"))
        let split1 = try store.splitSection(
            in: presentation,
            sectionID: initial.sectionID,
            at: jordanRange.lowerBound
        )
        let samRange = try #require(split1.secondSection.text.range(of: "Sam wrap-up"))
        let split2 = try store.splitSection(
            in: presentation,
            sectionID: split1.secondSection.sectionID,
            at: samRange.lowerBound
        )

        try applySpeaker(
            SpeakerSpec(title: "Alex Intro", speaker: "Alex", role: .teammate, purpose: .story, handoffOverride: nil),
            to: split1.firstSection,
            in: presentation,
            store: store
        )
        let customRev = try applySpeaker(
            SpeakerSpec(
                title: "Jordan Reveal",
                speaker: "Jordan",
                role: .presenter,
                purpose: .reveal,
                handoffOverride: "Wait for Alex’s nod before revealing."
            ),
            to: split2.firstSection,
            in: presentation,
            store: store
        )
        try applySpeaker(
            SpeakerSpec(title: "Sam Close", speaker: "Sam", role: .teammate, purpose: .closing, handoffOverride: nil),
            to: split2.secondSection,
            in: presentation,
            store: store
        )
        return ThreeSpeakerTalk(
            presentation: presentation,
            alexID: split1.firstSection.sectionID,
            jordanID: split2.firstSection.sectionID,
            samID: split2.secondSection.sectionID,
            customRevision: customRev
        )
    }

    @discardableResult
    func applySpeaker(
        _ spec: SpeakerSpec,
        to section: SectionRevisionRecord,
        in presentation: PresentationRecord,
        store: PresentationStore
    ) throws -> TalkRevisionRecord {
        let draft = SectionDraft(
            title: spec.title,
            text: section.text,
            speaker: spec.speaker,
            speakerRole: spec.role,
            purpose: spec.purpose,
            cueWords: [],
            exactPhrase: nil,
            handoffCueOverride: spec.handoffOverride
        )
        return try store.saveSectionEdit(in: presentation, sectionID: section.sectionID, draft: draft)
    }
}
