import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Shared Surface Concealment, Reveal Counting & Accessibility Rendering")
@MainActor
struct SlideRehearsalConcealmentTests {
    @Test("PracticePromptCard conceals spoken lines and directions in Cue Words and Memory until revealed")
    func practicePromptCardConcealmentAndReveal() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlidePracticeConceal")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let seeded = try AnnotatedSlideRehearsalTests.seedTwoSectionFiveSlideTalk(in: library, workspace: workspace)
        let sec1 = seeded.sections[0]
        let sec1Slides = RehearsalSlideResolver.resolveSlides(for: sec1)

        let secretSpeech = "Welcome to the Spelum rehearsal showcase."
        let secretDirection = "Pause and make eye contact"
        let cueWord = "Roadmap Hook"
        let exactPhrase = "Set the stage"

        for mode in [PracticeMode.cueWords, PracticeMode.memory] {
            let hidden = makePracticeCard(
                section: sec1,
                slides: sec1Slides,
                mode: mode,
                revealed: false,
                rootURL: workspace.storageRoot
            )
            assertRenders(hidden)
            let hiddenState = hidden.visiblePromptState
            let hiddenStrings = hiddenState.renderedAccessibilityStrings
            #expect(!hiddenState.showsAnnotatedScript)
            #expect(!hiddenStrings.contains { $0.contains(secretSpeech) })
            #expect(!hiddenStrings.contains { $0.contains(secretDirection) })
            if mode == .memory {
                #expect(hiddenState.shouldConcealSlideTitle)
                #expect(hiddenState.visibleSlideTitle == nil)
                #expect(!hiddenStrings.contains { $0.contains(cueWord) })
                #expect(!hiddenStrings.contains { $0.contains(exactPhrase) })
                #expect(hiddenStrings.contains("Script Hidden for Recall"))
            } else {
                #expect(!hiddenState.shouldConcealSlideTitle)
                #expect(hiddenStrings.contains { $0.contains(cueWord) })
                #expect(hiddenStrings.contains { $0.contains(exactPhrase) })
            }

            let revealed = makePracticeCard(
                section: sec1,
                slides: sec1Slides,
                mode: mode,
                revealed: true,
                rootURL: workspace.storageRoot
            )
            assertRenders(revealed)
            let revealedState = revealed.visiblePromptState
            let revealedStrings = revealedState.renderedAccessibilityStrings
            #expect(revealedState.showsAnnotatedScript)
            #expect(revealedStrings.contains { $0.contains(secretSpeech) })
            #expect(revealedStrings.contains { $0.contains("(short pause)") && $0.contains("(rising pitch)") })
            #expect(revealedStrings.contains { $0.contains("Direction:") && $0.contains(secretDirection) })
        }
    }

    @Test("FullRunStageCard and FullRunFullscreenStageView enforce concealment and count reveals")
    func fullRunSurfacesConcealmentAndRevealCount() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlideFullRunConceal")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let attemptStore = AttemptStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let seeded = try AnnotatedSlideRehearsalTests.seedTwoSectionFiveSlideTalk(in: library, workspace: workspace)

        let secretSpeech = "Welcome to the Spelum rehearsal showcase."
        let secretDirection = "Pause and make eye contact"
        let cueWord = "Roadmap Hook"

        for mode in [PracticeMode.cueWords, PracticeMode.memory] {
            let session = FullRunTestFixtures.makeSession(
                attemptStore: attemptStore,
                snapshot: seeded.snapshot,
                initialMode: mode,
                recorder: SteppableFullRunRecorder()
            )
            session.startSilentRecall()
            #expect(session.revealCount == 0)

            let stageCard = FullRunStageCard(
                section: seeded.snapshot.sections[0],
                slides: session.currentFullRunSlides,
                activeSlideIndex: 0,
                totalInRun: seeded.snapshot.sections.count,
                practiceMode: mode,
                isScriptRevealed: session.isScriptRevealed,
                revealCount: session.revealCount,
                isActiveTake: session.isActiveTake,
                isAccessibilitySize: false,
                storageRootURL: workspace.storageRoot,
                onToggleReveal: { session.toggleReveal() }
            )
            assertRenders(stageCard)
            let stageStrings = stageCard.visiblePromptState.renderedAccessibilityStrings
            #expect(!stageStrings.contains { $0.contains(secretSpeech) })
            #expect(!stageStrings.contains { $0.contains(secretDirection) })
            if mode == .cueWords {
                #expect(stageStrings.contains { $0.contains(cueWord) })
            } else {
                #expect(!stageStrings.contains { $0.contains(cueWord) })
                #expect(stageCard.visiblePromptState.visibleSlideTitle == nil)
            }

            let fullscreen = FullRunFullscreenStageView(
                session: session,
                snapshot: seeded.snapshot,
                isAccessibilitySize: false,
                onExitFullscreen: {}
            )
            assertRenders(fullscreen)
            let hiddenFullscreen = try #require(fullscreen.visiblePromptState).renderedAccessibilityStrings
            #expect(!hiddenFullscreen.contains { $0.contains(secretSpeech) })
            #expect(!hiddenFullscreen.contains { $0.contains(secretDirection) })

            session.toggleReveal()
            #expect(session.revealCount == 1)
            assertRenders(fullscreen)
            let revealedFullscreen = try #require(fullscreen.visiblePromptState).renderedAccessibilityStrings
            #expect(revealedFullscreen.contains { $0.contains(secretSpeech) })
            #expect(revealedFullscreen.contains { $0.contains("Direction:") && $0.contains(secretDirection) })
            _ = session.finishFullRunEarly()
        }
    }

    @Test("Import preview, review cards, and rehearsal surfaces render in Light, Dark, and Accessibility sizes")
    func lightDarkAndAccessibilityDynamicTypeSmoke() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "SlideA11yRender")
        defer { workspace.cleanup() }

        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext, storageRootURL: workspace.storageRoot)
        let seeded = try AnnotatedSlideRehearsalTests.seedTwoSectionFiveSlideTalk(in: library, workspace: workspace)
        let sec1 = seeded.sections[0]
        let sec1Slides = RehearsalSlideResolver.resolveSlides(for: sec1)
        let plan = SlidePairingPlan.build(
            scriptText: AnnotatedSlideRehearsalTests.syntheticRehearsalScript,
            pdfPageCount: 5,
            pdfAspectRatios: Array(repeating: 16.0 / 9.0, count: 5)
        )

        let configs: [(ColorScheme, DynamicTypeSize)] = [
            (.light, .large),
            (.dark, .large),
            (.light, .accessibility3),
            (.dark, .accessibility5)
        ]

        let staged = InspectedPDFDeck(
            stagedURL: seeded.deckURL,
            displayFileName: "synthetic-deck.pdf",
            pageCount: 5,
            pageAspectRatios: Array(repeating: 16.0 / 9.0, count: 5)
        )

        for (scheme, size) in configs {
            assertRenders(
                FullRunReviewScriptCard(snapshot: seeded.snapshot, storageRootURL: workspace.storageRoot)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
            )
            assertRenders(
                TakeReviewScriptCard(section: sec1, revisionNumber: 1, storageRootURL: workspace.storageRoot)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
            )
            assertRenders(
                List {
                    ImportPairingPreviewSection(
                        plan: plan,
                        stagedPDF: staged,
                        onReplacePDF: {},
                        onRemovePDF: {}
                    )
                }
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
            )
            assertRenders(
                makePracticeCard(
                    section: sec1,
                    slides: sec1Slides,
                    mode: .fullScript,
                    revealed: false,
                    rootURL: workspace.storageRoot,
                    isAccessibilitySize: size.isAccessibilitySize
                )
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
            )
        }
    }
}

private extension SlideRehearsalConcealmentTests {
    func makePracticeCard(
        section: SectionRevisionRecord,
        slides: [ResolvedRehearsalSlide],
        mode: PracticeMode,
        revealed: Bool,
        rootURL: URL,
        isAccessibilitySize: Bool = false
    ) -> PracticePromptCard {
        PracticePromptCard(
            section: section,
            slides: slides,
            activeSlideIndex: 0,
            sectionPositionLabel: "Section 1 of 2",
            practiceMode: mode,
            isScriptRevealed: revealed,
            revealCount: revealed ? 1 : 0,
            isActiveTake: true,
            isAccessibilitySize: isAccessibilitySize,
            storageRootURL: rootURL,
            onSelectSlideIndex: { _ in },
            onToggleReveal: {}
        )
    }

    func assertRenders<V: View>(_ view: V) {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == 393)
        #expect(host.view.bounds.height == 852)
    }
}
