import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Spelum

@Suite("Full Run Fullscreen Stage Mode & Accessibility")
@MainActor
struct FullRunFullscreenStageTests {
    private struct StageAppearance {
        let colorScheme: ColorScheme
        let dynamicTypeSize: DynamicTypeSize
        let contrast: ColorSchemeContrast
    }

    @Test("Fullscreen policy auto-enters when starting a run and auto-exits on completion or failure")
    func fullscreenTransitionPolicy() {
        #expect(FullRunFullscreenPolicy.shouldAutoEnterFullscreen(previousPhase: .idle, currentPhase: .recording))
        #expect(FullRunFullscreenPolicy.shouldAutoEnterFullscreen(previousPhase: .idle, currentPhase: .silentRecall))
        #expect(
            FullRunFullscreenPolicy.shouldAutoEnterFullscreen(
                previousPhase: .requestingPermission,
                currentPhase: .recording
            )
        )
        #expect(
            !FullRunFullscreenPolicy.shouldAutoEnterFullscreen(
                previousPhase: .recording,
                currentPhase: .recording
            )
        )
        #expect(
            !FullRunFullscreenPolicy.shouldAutoEnterFullscreen(
                previousPhase: .idle,
                currentPhase: .requestingPermission
            )
        )

        #expect(FullRunFullscreenPolicy.shouldAutoExitFullscreen(for: .completed(UUID())))
        #expect(
            FullRunFullscreenPolicy.shouldAutoExitFullscreen(
                for: .interrupted(attemptID: UUID(), hasPlayableAudio: true, reason: "Call")
            )
        )
        #expect(FullRunFullscreenPolicy.shouldAutoExitFullscreen(for: .error("Audio failed")))
        #expect(!FullRunFullscreenPolicy.shouldAutoExitFullscreen(for: .idle))
        #expect(!FullRunFullscreenPolicy.shouldAutoExitFullscreen(for: .recording))
        #expect(!FullRunFullscreenPolicy.shouldAutoExitFullscreen(for: .silentRecall))
        #expect(!FullRunFullscreenPolicy.shouldAutoExitFullscreen(for: .finalizing))
    }

    @Test("FullRunFullscreenStageView renders cleanly across appearances, contrast, modes, and active states")
    func fullscreenStageRendersAcrossAppearancesAndStates() throws {
        let workspace = try PracticeTestWorkspace.create(prefix: "FullRunFullscreenUI")
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

        let appearances = [
            StageAppearance(colorScheme: .light, dynamicTypeSize: .large, contrast: .standard),
            StageAppearance(colorScheme: .dark, dynamicTypeSize: .large, contrast: .standard),
            StageAppearance(colorScheme: .dark, dynamicTypeSize: .accessibility3, contrast: .standard),
            StageAppearance(colorScheme: .light, dynamicTypeSize: .accessibility5, contrast: .increased)
        ]

        for mode in PracticeMode.allCases {
            let session = FullRunTestFixtures.makeSession(
                attemptStore: attemptStore,
                snapshot: snapshot,
                initialMode: mode,
                recorder: SteppableFullRunRecorder()
            )
            for appearance in appearances {
                renderFullscreenStage(session: session, snapshot: snapshot, appearance: appearance)
            }

            session.startSilentRecall()
            session.addManualMarker(label: "Check pacing")
            if mode.supportsReveal {
                session.toggleReveal()
            }
            _ = session.advanceFullRunSection()

            for appearance in appearances {
                renderFullscreenStage(session: session, snapshot: snapshot, appearance: appearance)
            }
            _ = session.finishFullRunEarly()
        }
    }

    private func renderFullscreenStage(
        session: RecordingSession,
        snapshot: FullRunSnapshot,
        appearance: StageAppearance
    ) {
        let view = FullRunFullscreenStageView(
            session: session,
            snapshot: snapshot,
            isAccessibilitySize: appearance.dynamicTypeSize.isAccessibilitySize,
            onExitFullscreen: {}
        )
        .environment(\.colorScheme, appearance.colorScheme)
        .environment(\.dynamicTypeSize, appearance.dynamicTypeSize)
        .environment(\._colorSchemeContrast, appearance.contrast)

        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == 393)
        #expect(host.view.bounds.height == 852)
    }
}
