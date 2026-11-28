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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let session: RecordingSession
    let snapshot: FullRunSnapshot
    let isAccessibilitySize: Bool
    let onExitFullscreen: () -> Void

    @State private var showsSlidePreview = true

    private var activeSection: FullRunSectionSnapshot? {
        session.currentFullRunSection ?? snapshot.sections.first
    }

    private var usesStageScroll: Bool {
        isAccessibilitySize || verticalSizeClass == .compact
    }

    private var hasStepNav: Bool {
        session.currentFullRunSlides.count > 1 || snapshot.sections.count > 1
    }

    private var activeSlideHasArtwork: Bool {
        guard let slide = session.currentFullRunSlide else { return false }
        return slide.resolvedDeckURL(storageRootURL: session.attemptStore.storageRootURL) != nil
            && slide.pdfPageIndex != nil
    }

    var body: some View {
        ZStack {
            FullRunGlowingBlueBackground(isActiveTake: session.isActiveTake)

            VStack(spacing: 0) {
                topStatusBar
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                if usesStageScroll {
                    scrollableStage
                } else {
                    scriptScrollStage
                    controlsDock
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("fullRunFullscreenStageView")
    }

    @ViewBuilder
    private var topStatusBar: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    statusPill
                    Spacer(minLength: 8)
                    timerLabel
                }
                progressBadge
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                statusPill
                progressBadge
                Spacer(minLength: 8)
                timerLabel
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let info = statusInfo
        HStack(spacing: 5) {
            Circle()
                .fill(info.tint)
                .frame(width: 7, height: 7)
            Text(info.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullRunFullscreenStatusPill")
    }

    private struct StageStatusBadge {
        let title: String
        let tint: Color
    }

    private var statusInfo: StageStatusBadge {
        switch session.phase {
        case .recording:
            StageStatusBadge(title: "Recording", tint: Color(red: 1.0, green: 0.42, blue: 0.42))
        case .silentRecall:
            StageStatusBadge(title: "Silent Run", tint: Color(red: 0.56, green: 0.85, blue: 1.0))
        case .requestingPermission:
            StageStatusBadge(title: "Checking Mic", tint: .white.opacity(0.85))
        case .finalizing:
            StageStatusBadge(title: "Saving", tint: .white.opacity(0.85))
        default:
            StageStatusBadge(title: "Ready", tint: Color(red: 0.65, green: 0.88, blue: 1.0))
        }
    }

    private var progressBadge: some View {
        let current = min(max(session.currentFullRunSectionIndex + 1, 1), max(snapshot.sections.count, 1))
        let slideCount = session.currentFullRunSlides.count
        let slideNum = min(max(session.currentFullRunSlideIndex + 1, 1), max(slideCount, 1))
        let labelText = slideCount > 1
            ? "Sec \(current)/\(snapshot.sections.count) · \(slideNum)/\(slideCount)"
            : "Sec \(current)/\(snapshot.sections.count)"
        let accessibleLabel = slideCount > 1
            ? "Section \(current) of \(snapshot.sections.count), Slide \(slideNum) of \(slideCount)"
            : "Section \(current) of \(snapshot.sections.count)"
        return Text(labelText)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.76))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityLabel(accessibleLabel)
            .accessibilityIdentifier("fullRunFullscreenProgressLabel")
    }

    private var timerLabel: some View {
        Text(RehearsalTimeFormatter.clockString(for: session.elapsedDuration))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .accessibilityLabel("Total run elapsed time")
            .accessibilityValue(
                RehearsalTimeFormatter.accessibleDurationString(for: session.elapsedDuration)
            )
            .accessibilityIdentifier("fullRunFullscreenTimerLabel")
    }

    var fullscreenScriptContent: FullRunFullscreenScriptContent? {
        guard let section = activeSection else { return nil }
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
            usesStageScroll: usesStageScroll,
            showsSlidePreview: showsSlidePreview,
            storageRootURL: session.attemptStore.storageRootURL,
            onToggleReveal: { session.toggleReveal() }
        )
    }

    var visiblePromptState: RehearsalVisiblePromptState? {
        fullscreenScriptContent?.visiblePromptState
    }

    private var scrollableStage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    scriptScrollStage
                        .id("fullscreenScriptStart")
                    controlsDock
                }
            }
            .onChange(of: session.currentFullRunSlide?.id) { _, _ in
                proxy.scrollTo("fullscreenScriptStart", anchor: .top)
            }
        }
    }

    private var controlsDock: some View {
        let shouldConcealSlideTitle = visiblePromptState?.shouldConcealSlideTitle ?? false
        return FullRunFullscreenControlsDock(
            session: session,
            sectionTitle: activeSection?.title ?? "",
            slides: session.currentFullRunSlides,
            activeSlideIndex: session.currentFullRunSlideIndex,
            hasStepNav: hasStepNav,
            hasSlideArtwork: activeSlideHasArtwork,
            showsSlidePreview: showsSlidePreview,
            shouldConcealSlideTitle: shouldConcealSlideTitle,
            isAccessibilitySize: isAccessibilitySize,
            onToggleSlidePreview: { showsSlidePreview.toggle() },
            onSelectSlideIndex: session.currentFullRunSlides.count > 1
                ? { session.selectFullRunSlide(index: $0) }
                : nil,
            onExitFullscreen: onExitFullscreen
        )
    }

    private var scriptScrollStage: some View {
        Group {
            if let content = fullscreenScriptContent {
                content
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
