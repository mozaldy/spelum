import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Task 6 Coaching UI Light/Dark and Dynamic Type Accessibility Rendering")
@MainActor
struct CoachingUIAccessibilityTests {
    @Test("PracticeCoachingCard renders cleanly across Light, Dark, and Accessibility Dynamic Type")
    func practiceCoachingCardRendersAcrossAppearancesAndDynamicType() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let library = PresentationStore(modelContext: container.mainContext)
        let coachingStore = CoachingStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library, title: "A11y Prep")
        let request = SectionCoachService.makePreparationRequest(
            section: seeded.section,
            talkRevisionID: seeded.talkRevision.id,
            handoff: nil
        )

        let activeCoordinator = PreparationCoachCoordinator(
            coachService: SectionCoachService(modelProvider: StubCoachingModelProvider(availabilityState: .available)),
            coachingStore: coachingStore
        )
        activeCoordinator.load(request: request)

        let dismissedCoordinator = PreparationCoachCoordinator(
            coachService: SectionCoachService(modelProvider: StubCoachingModelProvider(availabilityState: .available)),
            coachingStore: coachingStore
        )
        dismissedCoordinator.load(request: request)
        try dismissedCoordinator.dismissCurrentCue()

        let coordinators = [activeCoordinator, dismissedCoordinator]
        for coordinator in coordinators {
            for (scheme, typeSize) in Self.displayConfigurations {
                for mode in [PracticeMode.fullScript, PracticeMode.memory, PracticeMode.cueWords] {
                    let view = PracticeCoachingCard(
                        coordinator: coordinator,
                        practiceMode: mode,
                        isScriptRevealed: false,
                        sectionExactPhrase: seeded.section.exactPhrase,
                        handoffCueText: nil,
                        isActiveTake: false,
                        isAccessibilitySize: typeSize.isAccessibilitySize,
                        onRevealScript: {}
                    )
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize)
                    assertRendersNonZero(view)
                }
            }
        }
    }

    @Test("TakeReviewCoachingCard and CoachingEditCueSheet render across Light, Dark, and Accessibility sizes")
    func reviewCoachingCardAndEditSheetRenderCleanly() throws {
        let container = try PresentationStore.makeModelContainer(inMemory: true)
        let coachingStore = CoachingStore(modelContext: container.mainContext)

        let gapRequest = CoachingTestFixtures.makeSamplePostTakeRequest(withObservation: true)
        let silentRequest = PostTakeCoachingRequest(
            attemptID: UUID(),
            talkRevisionID: UUID(),
            sectionRevisionID: UUID(),
            sectionTitle: "Silent Section",
            scriptText: "Today we unveil Spelum offline.",
            exactPhrase: "Today we unveil Spelum offline.",
            cueWords: ["unveil"],
            purpose: .reveal,
            handoffCueText: nil,
            isSpeakerChangeHandoff: false,
            knownSpeakerNames: [],
            attemptStatus: .silentCompleted,
            practiceMode: .cueWords,
            playableDuration: 0,
            revealCount: 0,
            markers: [],
            timingAnalysis: nil,
            candidateTechniques: TechniqueLibrary.candidateTechniques(for: .reveal, hasHandoff: false),
            promptVersion: SectionCoachService.postTakePromptVersion
        )

        for request in [gapRequest, silentRequest] {
            let coordinator = PostTakeCoachCoordinator(coachingStore: coachingStore)
            coordinator.load(request: request)
            for (scheme, typeSize) in Self.displayConfigurations {
                let card = TakeReviewCoachingCard(
                    coordinator: coordinator,
                    observations: request.timingAnalysis?.observations ?? [],
                    isAudioLoaded: request.playableDuration > 0,
                    isAccessibilitySize: typeSize.isAccessibilitySize,
                    onSeekObservation: { _ in },
                    onRequestOnDevice: {}
                )
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
                assertRendersNonZero(card)
            }
        }

        for (scheme, typeSize) in Self.displayConfigurations {
            let sheet = CoachingEditCueSheet(
                title: "Edit Pre-Practice Cue",
                originalAction: "Pause one clear beat before the headline.",
                initialText: "Pause one clear beat before the headline.",
                onSave: { _ in }
            )
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            assertRendersNonZero(sheet)
        }
    }

    @Test("CoachingEvaluationView and CoachingEvaluationCaseSheet render across Light, Dark, and Accessibility sizes")
    func evaluationViewsRenderAcrossAppearancesAndDynamicType() async throws {
        let dataset = try CoachingEvaluationDataset.loadBundled()
        let runner = CoachingEvaluationRunner(
            coachService: SectionCoachService(
                modelProvider: StubCoachingModelProvider(availabilityState: .unavailable(.deviceNotEligible))
            ),
            repeatTrialsPerCase: 2
        )
        let session = await runner.runSuite(
            task: .preparation,
            dataset: dataset,
            environment: CoachingDeviceEnvironment.current(),
            randomSeed: 42
        )
        let firstEntry = try #require(session.entries.first)

        for (scheme, typeSize) in Self.displayConfigurations {
            let evalView = CoachingEvaluationView()
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
            assertRendersNonZero(evalView)

            for unblinded in [false, true] {
                let sheet = CoachingEvaluationCaseSheet(
                    entry: firstEntry,
                    caseIndex: 0,
                    totalCases: session.entries.count,
                    isUnblinded: unblinded,
                    hasNextCase: true,
                    onSave: { _, _ in }
                )
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
                assertRendersNonZero(sheet)
            }
        }
    }

    private static let displayConfigurations: [(ColorScheme, DynamicTypeSize)] = [
        (.light, .large),
        (.dark, .large),
        (.light, .accessibility3),
        (.dark, .accessibility5)
    ]

    private func assertRendersNonZero<V: View>(_ view: V) {
        let hosting = UIHostingController(rootView: view)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        let fitted = hosting.sizeThatFits(in: CGSize(width: 393, height: 2400))
        #expect(fitted.width > 0)
        #expect(fitted.height > 0)
    }
}
