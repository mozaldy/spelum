import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Task 6 Recall Concealment Regressions")
@MainActor
struct PracticeRecallConcealmentTests {
    @Test("Memory mode conceals script-anchored cues and reveals when script is revealed")
    func memoryModeConcealsScriptAndUnlocksOnReveal() throws {
        let scriptCue = makeCue(
            exactPhrase: "Secret opening sentence for recall.",
            fromHandoff: false,
            editedAction: nil
        )
        let hiddenMemory = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .memory,
            isScriptRevealed: false,
            sectionExactPhrase: "Secret opening sentence for recall.",
            handoffCueText: "Passing it over to Alex.",
            cue: scriptCue
        )
        #expect(hiddenMemory.state == .concealEntireCue)
        #expect(!hiddenMemory.showsCueBody)
        #expect(!hiddenMemory.showsQuotedPassage)
        #expect(!hiddenMemory.showsProvenanceDisclosure)
        #expect(!hiddenMemory.allowsEditing)
        #expect(!hiddenMemory.allowsCustomActions)
        #expect(hiddenMemory.showsRevealAction)

        let revealedMemory = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .memory,
            isScriptRevealed: true,
            sectionExactPhrase: "Secret opening sentence for recall.",
            handoffCueText: "Passing it over to Alex.",
            cue: scriptCue
        )
        #expect(revealedMemory.state == .visible)
        #expect(revealedMemory.allowsEditing)
        #expect(revealedMemory.showsProvenanceDisclosure)
        #expect(revealedMemory.allowsCustomActions)
    }

    @Test("Memory mode allows verified unedited handoff cue but conceals spoofed or edited handoff cues")
    func memoryModeIntentionalHandoffAndEditedGuards() throws {
        let handoffCue = makeCue(
            exactPhrase: "Passing it over to Alex.",
            fromHandoff: true,
            editedAction: nil
        )
        let allowedHandoff = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .memory,
            isScriptRevealed: false,
            sectionExactPhrase: "Secret opening sentence for recall.",
            handoffCueText: "Passing it over to Alex.",
            cue: handoffCue
        )
        #expect(allowedHandoff.state == .visible)
        #expect(allowedHandoff.showsQuotedPassage)
        #expect(!allowedHandoff.allowsEditing)

        let spoofedHandoff = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .memory,
            isScriptRevealed: false,
            sectionExactPhrase: "Secret opening sentence for recall.",
            handoffCueText: "Different incoming line.",
            cue: handoffCue
        )
        #expect(spoofedHandoff.state == .concealEntireCue)

        let editedHandoff = makeCue(
            exactPhrase: "Passing it over to Alex.",
            fromHandoff: true,
            editedAction: "Say Secret opening sentence for recall clearly."
        )
        let concealedEdited = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .memory,
            isScriptRevealed: false,
            sectionExactPhrase: "Secret opening sentence for recall.",
            handoffCueText: "Passing it over to Alex.",
            cue: editedHandoff
        )
        #expect(concealedEdited.state == .concealEntireCue)
        #expect(!concealedEdited.showsCueBody)
    }

    @Test("Cue Words mode conceals hidden body quotes and edited cues while preserving marked exact phrase")
    func cueWordsModeConcealmentMatrix() throws {
        let bodyFallbackCue = makeCue(
            exactPhrase: "Hidden opening sentence from body.",
            fromHandoff: false,
            editedAction: nil
        )
        let concealedWithoutMarked = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .cueWords,
            isScriptRevealed: false,
            sectionExactPhrase: nil,
            handoffCueText: nil,
            cue: bodyFallbackCue
        )
        #expect(concealedWithoutMarked.state == .concealScriptPassage)
        #expect(concealedWithoutMarked.showsCueBody)
        #expect(!concealedWithoutMarked.showsQuotedPassage)
        #expect(!concealedWithoutMarked.showsProvenanceDisclosure)
        #expect(!concealedWithoutMarked.allowsEditing)
        #expect(!concealedWithoutMarked.allowsCustomActions)
        #expect(concealedWithoutMarked.showsRevealAction)

        let concealedDifferentBodyLine = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .cueWords,
            isScriptRevealed: false,
            sectionExactPhrase: "Marked headline phrase.",
            handoffCueText: nil,
            cue: bodyFallbackCue
        )
        #expect(concealedDifferentBodyLine.state == .concealScriptPassage)

        let markedPhraseCue = makeCue(
            exactPhrase: "Marked headline phrase.",
            fromHandoff: false,
            editedAction: nil
        )
        let visibleMarked = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .cueWords,
            isScriptRevealed: false,
            sectionExactPhrase: "Marked headline phrase.",
            handoffCueText: nil,
            cue: markedPhraseCue
        )
        #expect(visibleMarked.state == .visible)
        #expect(visibleMarked.showsQuotedPassage)
        #expect(visibleMarked.allowsEditing)

        let editedInCueWords = makeCue(
            exactPhrase: "Marked headline phrase.",
            fromHandoff: false,
            editedAction: "Remember hidden body line."
        )
        let concealedEdited = PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: .cueWords,
            isScriptRevealed: false,
            sectionExactPhrase: "Marked headline phrase.",
            handoffCueText: nil,
            cue: editedInCueWords
        )
        #expect(concealedEdited.state == .concealEntireCue)
        #expect(!concealedEdited.showsCueBody)
    }

    @Test("Revealing from concealed coach updates RecordingSession revealCount during active take")
    func revealFromConcealedCoachIncrementsSessionRevealCount() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Reveal Count Check")
        let workspace = try PracticeTestWorkspace.create(prefix: "RecallCount")
        defer { workspace.cleanup() }
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let snapshot = AttemptSnapshotReference(
            presentationID: seeded.presentation.id,
            talkRevisionID: seeded.talkRevision.id,
            talkRevisionNumber: seeded.talkRevision.revisionNumber,
            sectionID: seeded.section.sectionID,
            sectionRevisionID: seeded.section.revisionID,
            sectionTitle: seeded.section.title
        )
        let session = RecordingSession(
            attemptStore: attemptStore,
            snapshot: snapshot,
            initialMode: .memory
        )

        session.selectPracticeMode(.memory)
        session.startSilentRecall()
        #expect(session.isActiveTake)
        #expect(!session.isScriptRevealed)
        #expect(session.revealCount == 0)

        let cue = makeCue(exactPhrase: seeded.section.exactPhrase, fromHandoff: false, editedAction: nil)
        #expect(
            PracticeCoachingConcealmentPolicy.evaluate(
                practiceMode: session.practiceMode,
                isScriptRevealed: session.isScriptRevealed,
                sectionExactPhrase: seeded.section.exactPhrase,
                handoffCueText: nil,
                cue: cue
            ).state == .concealEntireCue
        )

        session.activateReveal()
        #expect(session.isScriptRevealed)
        #expect(session.revealCount == 1)
        #expect(
            PracticeCoachingConcealmentPolicy.evaluate(
                practiceMode: session.practiceMode,
                isScriptRevealed: session.isScriptRevealed,
                sectionExactPhrase: seeded.section.exactPhrase,
                handoffCueText: nil,
                cue: cue
            ).state == .visible
        )

        session.hideScript()
        #expect(!session.isScriptRevealed)
        #expect(
            PracticeCoachingConcealmentPolicy.evaluate(
                practiceMode: session.practiceMode,
                isScriptRevealed: session.isScriptRevealed,
                sectionExactPhrase: seeded.section.exactPhrase,
                handoffCueText: nil,
                cue: cue
            ).state == .concealEntireCue
        )
    }

    @Test("Rendered PracticeCoachingCard omits hidden script text in Memory mode when unrevealed")
    func renderedPracticeCoachingCardOmitsHiddenScriptInMemoryMode() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "Memory Render Check")
        seeded.section.text = "Secret opening sentence for recall. Second hidden line."
        seeded.section.exactPhrase = "Secret opening sentence for recall."
        let request = SectionCoachService.makePreparationRequest(
            section: seeded.section,
            talkRevisionID: seeded.talkRevision.id,
            handoff: nil
        )
        let coordinator = PreparationCoachCoordinator(
            coachService: SectionCoachService(modelProvider: StubCoachingModelProvider(availabilityState: .available)),
            coachingStore: coachingStore
        )
        coordinator.load(request: request)

        let hiddenCard = PracticeCoachingCard(
            coordinator: coordinator,
            practiceMode: .memory,
            isScriptRevealed: false,
            sectionExactPhrase: seeded.section.exactPhrase,
            handoffCueText: nil,
            isActiveTake: true,
            isAccessibilitySize: false,
            onRevealScript: {}
        )
        let hiddenStrings = AccessibilityTreeSnapshot.collectStrings(from: hiddenCard)
        #expect(!hiddenStrings.contains { $0.contains("Secret opening sentence for recall.") })
    }

    private func makeCue(
        exactPhrase: String?,
        fromHandoff: Bool,
        editedAction: String?
    ) -> CoachingSuggestion {
        CoachingSuggestion(
            task: .preparation,
            origin: .authoredBaseline,
            isAbstention: false,
            techniqueID: "reveal.problem-to-short-line",
            techniqueTitle: "Problem Contrast Into Short Line",
            sourceWork: "2007 Keynote",
            sourceTimestamp: "04:10",
            sourcePassageSummary: "Short pause before payoff.",
            exactPhrase: exactPhrase,
            exactPhraseFromHandoff: fromHandoff,
            action: "Pause cleanly before your key line.",
            rationale: "Selected for Product Reveal.",
            promptVersion: SectionCoachService.preparationPromptVersion,
            sectionRevisionID: UUID(),
            userEditedAction: editedAction
        )
    }
}

@MainActor
private enum AccessibilityTreeSnapshot {
    static func collectStrings<V: View>(from view: V) -> [String] {
        let host = UIHostingController(rootView: view)
        let window = makeWindow()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        var collected: [String] = []
        var visited = Set<ObjectIdentifier>()
        visit(host.view, collected: &collected, visited: &visited)
        window.isHidden = true
        return collected
    }

    private static func makeWindow() -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            return window
        }
        return UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    }

    private static func visit(_ object: AnyObject, collected: inout [String], visited: inout Set<ObjectIdentifier>) {
        let id = ObjectIdentifier(object)
        guard !visited.contains(id) else { return }
        visited.insert(id)

        if let nsObj = object as? NSObject {
            appendAccessibilityText(from: nsObj, into: &collected)
            let count = nsObj.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = nsObj.accessibilityElement(at: index) as AnyObject? {
                        visit(child, collected: &collected, visited: &visited)
                    }
                }
            }
        }
        if let view = object as? UIView {
            if let label = view as? UILabel, let text = label.text { collected.append(text) }
            for subview in view.subviews {
                visit(subview, collected: &collected, visited: &visited)
            }
        }
    }

    private static func appendAccessibilityText(from object: NSObject, into collected: inout [String]) {
        if let label = object.accessibilityLabel, !label.isEmpty { collected.append(label) }
        if let value = object.accessibilityValue, !value.isEmpty { collected.append(value) }
        if let hint = object.accessibilityHint, !hint.isEmpty { collected.append(hint) }
    }
}
