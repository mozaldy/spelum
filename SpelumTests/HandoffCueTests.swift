import Foundation
import SwiftData
import Testing
@testable import Spelum

@Suite("Handoff Cues")
@MainActor
struct HandoffCueTests {
    private struct TestStoreHarness {
        let container: ModelContainer
        let store: PresentationStore
    }

    private func makeInMemoryHarness() throws -> TestStoreHarness {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        return TestStoreHarness(
            container: container,
            store: PresentationStore(modelContext: container.mainContext)
        )
    }

    private struct TwoSpeakerFixture {
        let presentation: PresentationRecord
        let alexSectionID: UUID
        let jordanSectionID: UUID
    }

    private func makeTwoSpeakerPresentation(
        in store: PresentationStore
    ) throws -> TwoSpeakerFixture {
        let script = """
        Alex line one.
        Alex final line before handoff.

        Jordan reveal line one.
        Jordan closing line.
        """
        let presentation = try store.importScript(text: script, title: "Two-Speaker Handoff")
        let initialSection = try #require(store.orderedSections(for: presentation).first)
        let splitRange = try #require(initialSection.text.range(of: "Jordan reveal"))
        let split = try store.splitSection(
            in: presentation,
            sectionID: initialSection.sectionID,
            at: splitRange.lowerBound
        )

        _ = try store.saveSectionEdit(
            in: presentation,
            sectionID: split.firstSection.sectionID,
            draft: SectionDraft(
                title: "Alex Setup",
                text: split.firstSection.text,
                speaker: "Alex",
                speakerRole: .teammate,
                purpose: .story,
                cueWords: ["setup"],
                exactPhrase: nil,
                handoffCueOverride: nil
            )
        )
        _ = try store.saveSectionEdit(
            in: presentation,
            sectionID: split.secondSection.sectionID,
            draft: SectionDraft(
                title: "Jordan Reveal",
                text: split.secondSection.text,
                speaker: "Jordan",
                speakerRole: .presenter,
                purpose: .reveal,
                cueWords: ["reveal"],
                exactPhrase: nil,
                handoffCueOverride: nil
            )
        )
        return TwoSpeakerFixture(
            presentation: presentation,
            alexSectionID: split.firstSection.sectionID,
            jordanSectionID: split.secondSection.sectionID
        )
    }

    @Test("First section has no preceding line while changed speaker receives preceding final line")
    func firstSectionAndChangedSpeakerHandoff() throws {
        let harness = try makeInMemoryHarness()
        let store = harness.store
        let fixture = try makeTwoSpeakerPresentation(in: store)

        let firstHandoff = try #require(
            store.handoffContext(forSectionID: fixture.alexSectionID, in: fixture.presentation)
        )
        #expect(firstHandoff.isFirstSection)
        #expect(firstHandoff.precedingSectionID == nil)
        #expect(firstHandoff.derivedFinalLine == nil)
        #expect(firstHandoff.effectiveCueText == nil)
        #expect(!firstHandoff.isSpeakerChange)
        #expect(!firstHandoff.isSingleSpeakerTalk)

        let secondHandoff = try #require(
            store.handoffContext(forSectionID: fixture.jordanSectionID, in: fixture.presentation)
        )
        #expect(!secondHandoff.isFirstSection)
        #expect(secondHandoff.isSpeakerChange)
        #expect(!secondHandoff.isSingleSpeakerTalk)
        #expect(secondHandoff.precedingSectionID == fixture.alexSectionID)
        #expect(secondHandoff.precedingSpeaker == "Alex")
        #expect(secondHandoff.precedingSpeakerRole == .teammate)
        #expect(secondHandoff.derivedFinalLine == "Alex final line before handoff.")
        #expect(secondHandoff.effectiveCueText == "Alex final line before handoff.")
        #expect(!secondHandoff.isCustomCue)
    }

    @Test("Reordering sections updates handoff cues and supports editable overrides")
    func reorderedSectionsAndEditableHandoffOverride() throws {
        let harness = try makeInMemoryHarness()
        let store = harness.store
        let fixture = try makeTwoSpeakerPresentation(in: store)

        let reorderedRev = try store.reorderSections(
            in: fixture.presentation,
            orderedSectionIDs: [fixture.jordanSectionID, fixture.alexSectionID]
        )

        let newFirst = try #require(
            store.handoffContext(forSectionID: fixture.jordanSectionID, in: reorderedRev)
        )
        #expect(newFirst.isFirstSection)
        #expect(newFirst.derivedFinalLine == nil)

        let newSecond = try #require(
            store.handoffContext(forSectionID: fixture.alexSectionID, in: reorderedRev)
        )
        #expect(!newSecond.isFirstSection)
        #expect(newSecond.isSpeakerChange)
        #expect(newSecond.precedingSectionID == fixture.jordanSectionID)
        #expect(newSecond.precedingSpeaker == "Jordan")
        #expect(newSecond.precedingSpeakerRole == .presenter)
        #expect(newSecond.derivedFinalLine == "Jordan closing line.")
        #expect(newSecond.effectiveCueText == "Jordan closing line.")

        let alexRecord = try #require(store.orderedSections(for: fixture.presentation).last)
        var customDraft = SectionDraft(record: alexRecord)
        customDraft.handoffCueOverride = "Wait for Jordan’s nod after closing line."
        _ = try store.saveSectionEdit(
            in: fixture.presentation,
            sectionID: alexRecord.sectionID,
            draft: customDraft
        )
        let editedHandoff = try #require(
            store.handoffContext(forSectionID: alexRecord.sectionID, in: fixture.presentation)
        )
        #expect(editedHandoff.isCustomCue)
        #expect(editedHandoff.derivedFinalLine == "Jordan closing line.")
        #expect(editedHandoff.effectiveCueText == "Wait for Jordan’s nod after closing line.")
    }

    @Test("Single-speaker talk shows preceding line without claiming a speaker change")
    func singleSpeakerTalkHandoff() throws {
        let harness = try makeInMemoryHarness()
        let store = harness.store
        let script = "Opening story line.\nHere is why it matters.\n\nNow let’s walk through the demo."
        let presentation = try store.importScript(text: script, title: "Solo Talk")
        let initial = try #require(store.orderedSections(for: presentation).first)
        let splitRange = try #require(initial.text.range(of: "Now let’s"))
        let split = try store.splitSection(in: presentation, sectionID: initial.sectionID, at: splitRange.lowerBound)

        for section in [split.firstSection, split.secondSection] {
            var draft = SectionDraft(record: section)
            draft.speaker = "Morgan"
            draft.speakerRole = .presenter
            _ = try store.saveSectionEdit(in: presentation, sectionID: section.sectionID, draft: draft)
        }

        let handoff = try #require(
            store.handoffContext(forSectionID: split.secondSection.sectionID, in: presentation)
        )
        #expect(!handoff.isFirstSection)
        #expect(!handoff.isSpeakerChange)
        #expect(handoff.isSingleSpeakerTalk)
        #expect(handoff.precedingSpeaker == "Morgan")
        #expect(handoff.precedingSpeakerRole == .presenter)
        #expect(handoff.derivedFinalLine == "Here is why it matters.")
        #expect(handoff.effectiveCueText == "Here is why it matters.")
    }

    @Test("Line split options, live handoff propagation, reset, rename, and delete keep immutable history")
    func lineSplitPropagationResetRenameAndDelete() throws {
        let harness = try makeInMemoryHarness()
        let store = harness.store
        let script = "Line A1\r\nLine A2 “quoted” ✨\r\n\r\nLine B1\r\nLine B2 🚀"
        let presentation = try store.importScript(text: script, title: "Original Title")
        let initialSection = try #require(store.orderedSections(for: presentation).first)

        let splitOptions = PresentationStore.lineSplitOptions(in: script)
        let splitAtB = try #require(splitOptions.first { $0.afterPreview.contains("Line B1") })
        let split = try store.splitSection(
            in: presentation,
            sectionID: initialSection.sectionID,
            at: splitAtB.splitIndex
        )
        #expect(split.firstSection.text + split.secondSection.text == script)

        var firstDraft = SectionDraft(record: split.firstSection)
        firstDraft.text = "Line A1\nUpdated closing cue ✨"
        _ = try store.saveSectionEdit(in: presentation, sectionID: split.firstSection.sectionID, draft: firstDraft)
        #expect(
            store.handoffContext(forSectionID: split.secondSection.sectionID, in: presentation)?.derivedFinalLine
                == "Updated closing cue ✨"
        )

        var secondDraft = SectionDraft(record: split.secondSection)
        secondDraft.handoffCueOverride = "Custom nod cue"
        _ = try store.saveSectionEdit(in: presentation, sectionID: split.secondSection.sectionID, draft: secondDraft)
        secondDraft.handoffCueOverride = nil
        _ = try store.saveSectionEdit(in: presentation, sectionID: split.secondSection.sectionID, draft: secondDraft)
        let resetHandoff = try #require(
            store.handoffContext(forSectionID: split.secondSection.sectionID, in: presentation)
        )
        #expect(!resetHandoff.isCustomCue)
        #expect(resetHandoff.effectiveCueText == "Updated closing cue ✨")

        let beforeRenameRevID = try #require(presentation.currentRevisionID)
        let renamedRev = try store.renamePresentation(presentation, to: "Updated Title")
        #expect(renamedRev.title == "Updated Title")
        #expect(try store.talkRevision(withID: beforeRenameRevID)?.title == "Original Title")

        let afterDeleteRev = try store.deleteSection(in: presentation, sectionID: split.secondSection.sectionID)
        #expect(store.orderedSections(in: afterDeleteRev).count == 1)
        let beforeDeleteRev = try #require(try store.talkRevision(withID: renamedRev.id))
        #expect(store.orderedSections(in: beforeDeleteRev).count == 2)

        #expect(PresentationStore.lineSplitOptions(in: "").isEmpty)
        #expect(PresentationStore.lineSplitOptions(in: "Single line only").isEmpty)
    }
}
