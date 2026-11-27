import SwiftUI

enum FullRunFullscreenPolicy {
    static func shouldAutoEnterFullscreen(
        previousPhase: RecordingSessionPhase?,
        currentPhase: RecordingSessionPhase
    ) -> Bool {
        guard isActivePhase(currentPhase) else { return false }
        guard let previousPhase else { return true }
        return !isActivePhase(previousPhase)
    }

    static func shouldAutoExitFullscreen(for phase: RecordingSessionPhase) -> Bool {
        switch phase {
        case .completed, .interrupted, .saveFailed, .error:
            true
        case .idle, .requestingPermission, .recording, .silentRecall, .finalizing:
            false
        }
    }

    private static func isActivePhase(_ phase: RecordingSessionPhase) -> Bool {
        switch phase {
        case .recording, .silentRecall:
            true
        default:
            false
        }
    }
}

struct FullRunGlowingBlueBackground: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let isActiveTake: Bool

    var body: some View {
        let isHighContrast = colorSchemeContrast == .increased
        let primaryGlowOpacity = isHighContrast ? 0.24 : (isActiveTake ? 0.46 : 0.38)
        let secondaryGlowOpacity = isHighContrast ? 0.16 : (isActiveTake ? 0.30 : 0.24)
        let accentGlowOpacity = isHighContrast ? 0.14 : 0.24

        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.07, blue: 0.20),
                    Color(red: 0.05, green: 0.16, blue: 0.44),
                    Color(red: 0.02, green: 0.09, blue: 0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.13, green: 0.48, blue: 1.00).opacity(primaryGlowOpacity),
                    Color(red: 0.08, green: 0.30, blue: 0.82).opacity(primaryGlowOpacity * 0.45),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 20,
                endRadius: 420
            )

            RadialGradient(
                colors: [
                    Color(red: 0.06, green: 0.62, blue: 0.98).opacity(secondaryGlowOpacity),
                    .clear
                ],
                center: UnitPoint(x: 0.85, y: 0.82),
                startRadius: 10,
                endRadius: 340
            )

            RadialGradient(
                colors: [
                    Color(red: 0.20, green: 0.34, blue: 0.94).opacity(accentGlowOpacity),
                    .clear
                ],
                center: UnitPoint(x: 0.12, y: 0.68),
                startRadius: 10,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct FullRunFullscreenStageView: View {
    let session: RecordingSession
    let snapshot: FullRunSnapshot
    let isAccessibilitySize: Bool
    let onExitFullscreen: () -> Void

    private var activeSection: FullRunSectionSnapshot? {
        session.currentFullRunSection ?? snapshot.sections.first
    }

    var body: some View {
        ZStack {
            FullRunGlowingBlueBackground(isActiveTake: session.isActiveTake)

            VStack(spacing: 0) {
                topStageBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                scriptScrollStage

                FullRunFullscreenControlsDock(
                    session: session,
                    isAccessibilitySize: isAccessibilitySize,
                    onExitFullscreen: onExitFullscreen
                )
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("fullRunFullscreenStageView")
    }

    @ViewBuilder
    private var topStageBar: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    statusPill
                    Spacer()
                    exitFullscreenButton
                }
                HStack(alignment: .firstTextBaseline) {
                    progressBadge
                    Spacer()
                    timerLabel
                }
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                statusPill
                progressBadge
                Spacer(minLength: 8)
                timerLabel
                exitFullscreenButton
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let info = statusInfo
        HStack(spacing: 6) {
            Image(systemName: info.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(info.tint)
            Text(info.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullRunFullscreenStatusPill")
    }

    private struct StageStatusBadge {
        let title: String
        let symbol: String
        let tint: Color
    }

    private var statusInfo: StageStatusBadge {
        switch session.phase {
        case .recording:
            StageStatusBadge(
                title: "Recording",
                symbol: "record.circle.fill",
                tint: Color(red: 1.0, green: 0.42, blue: 0.42)
            )
        case .silentRecall:
            StageStatusBadge(
                title: "Silent Run",
                symbol: "mic.slash.circle.fill",
                tint: Color(red: 0.56, green: 0.85, blue: 1.0)
            )
        case .requestingPermission:
            StageStatusBadge(title: "Checking Mic", symbol: "mic.fill", tint: .white.opacity(0.85))
        case .finalizing:
            StageStatusBadge(title: "Saving", symbol: "arrow.down.circle.fill", tint: .white.opacity(0.85))
        default:
            StageStatusBadge(
                title: "Ready",
                symbol: "waveform",
                tint: Color(red: 0.65, green: 0.88, blue: 1.0)
            )
        }
    }

    private var progressBadge: some View {
        let current = min(max(session.currentFullRunSectionIndex + 1, 1), max(snapshot.sections.count, 1))
        let slideCount = session.currentFullRunSlides.count
        let slideNum = min(max(session.currentFullRunSlideIndex + 1, 1), max(slideCount, 1))
        let labelText = slideCount > 1
            ? "Sec \(current)/\(snapshot.sections.count) · Slide \(slideNum)/\(slideCount)"
            : "\(current)/\(snapshot.sections.count)"
        let accessibleLabel = slideCount > 1
            ? "Section \(current) of \(snapshot.sections.count), Slide \(slideNum) of \(slideCount)"
            : "Section \(current) of \(snapshot.sections.count)"
        return Text(labelText)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.86))
            .accessibilityLabel(accessibleLabel)
            .accessibilityIdentifier("fullRunFullscreenProgressLabel")
    }

    private var timerLabel: some View {
        Text(RehearsalTimeFormatter.clockString(for: session.elapsedDuration))
            .font(.headline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .accessibilityLabel("Total run elapsed time")
            .accessibilityValue(
                RehearsalTimeFormatter.accessibleDurationString(for: session.elapsedDuration)
            )
            .accessibilityIdentifier("fullRunFullscreenTimerLabel")
    }

    private var exitFullscreenButton: some View {
        Button(action: onExitFullscreen) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .background(Color.white.opacity(0.16), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exit Fullscreen")
        .accessibilityHint("Returns to Full Run setup without stopping an active rehearsal.")
        .accessibilityIdentifier("fullRunExitFullscreenButton")
    }

    var fullscreenScriptContent: FullRunFullscreenScriptContent? {
        guard let section = activeSection else { return nil }
        let hasStepNav = session.currentFullRunSlides.count > 1 || snapshot.sections.count > 1
        return FullRunFullscreenScriptContent(
            section: section,
            slides: session.currentFullRunSlides,
            activeSlideIndex: session.currentFullRunSlideIndex,
            totalInRun: snapshot.sections.count,
            practiceMode: session.practiceMode,
            isScriptRevealed: session.isScriptRevealed,
            revealCount: session.revealCount,
            isActiveTake: session.isActiveTake,
            isAccessibilitySize: isAccessibilitySize,
            storageRootURL: session.attemptStore.storageRootURL,
            canGoPrevious: session.canRetreatFullRunStep,
            previousButtonLabel: session.hasPreviousSlideInCurrentSection
                ? "Previous Slide"
                : "Previous Section",
            onPrevious: hasStepNav ? { _ = session.retreatFullRunStep() } : nil,
            canGoNext: session.canAdvanceFullRunStep,
            nextButtonLabel: session.hasNextSlideInCurrentSection
                ? "Next Slide"
                : "Next Section",
            onNext: hasStepNav ? { _ = session.advanceFullRunStep() } : nil,
            onSelectSlideIndex: session.currentFullRunSlides.count > 1
                ? { session.selectFullRunSlide(index: $0) }
                : nil,
            onToggleReveal: { session.toggleReveal() }
        )
    }

    var visiblePromptState: RehearsalVisiblePromptState? {
        fullscreenScriptContent?.visiblePromptState
    }

    private var scriptScrollStage: some View {
        Group {
            if let content = fullscreenScriptContent {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
