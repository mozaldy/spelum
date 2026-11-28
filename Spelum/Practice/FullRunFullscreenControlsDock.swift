import SwiftUI

struct FullRunFullscreenControlsDock: View {
    let session: RecordingSession
    let sectionTitle: String
    let slides: [ResolvedRehearsalSlide]
    let activeSlideIndex: Int
    let hasStepNav: Bool
    let hasSlideArtwork: Bool
    let showsSlidePreview: Bool
    let shouldConcealSlideTitle: Bool
    let isAccessibilitySize: Bool
    let onToggleSlidePreview: () -> Void
    let onSelectSlideIndex: ((Int) -> Void)?
    let onExitFullscreen: () -> Void

    let primaryActionTextColor = Color(red: 0.04, green: 0.14, blue: 0.38)

    var clampedSlideIndex: Int {
        guard !slides.isEmpty else { return 0 }
        return min(max(activeSlideIndex, 0), slides.count - 1)
    }

    private var hasNextStep: Bool {
        session.nextSlideInCurrentSection != nil || session.nextFullRunSection != nil
    }

    private var shouldShowMetricsStrip: Bool {
        session.isActiveTake
            && (session.currentFullRunSectionIndex > 0 || !session.markers.isEmpty || session.revealCount > 0)
    }

    var previousButtonLabel: String {
        session.hasPreviousSlideInCurrentSection ? "Previous Slide" : "Previous Section"
    }

    var nextButtonLabel: String {
        session.hasNextSlideInCurrentSection ? "Next Slide" : "Next Section"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shouldShowMetricsStrip {
                activeMetricsStrip
            }

            if session.isActiveTake {
                activePrimaryRow
            } else {
                idlePrimaryControls
            }

            utilityControlBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(red: 0.02, green: 0.07, blue: 0.20)
                .opacity(0.86)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(height: 1)
        }
        .accessibilityIdentifier("fullRunFullscreenControlsDock")
    }

    private var activeMetricsStrip: some View {
        let sectionClock = RehearsalTimeFormatter.clockString(for: session.currentSectionElapsedDuration)
        var items = ["Section \(sectionClock)"]
        if session.markers.count == 1 {
            items.append("1 marker")
        } else if session.markers.count > 1 {
            items.append("\(session.markers.count) markers")
        }
        if session.revealCount == 1 {
            items.append("1 reveal")
        } else if session.revealCount > 1 {
            items.append("\(session.revealCount) reveals")
        }
        return Text(items.joined(separator: " · "))
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.76))
            .accessibilityIdentifier("fullRunFullscreenMetricsStrip")
    }

    private var activePrimaryRow: some View {
        HStack(spacing: 8) {
            if hasStepNav {
                previousStepIconButton(height: 46)
            }

            if let nextSlide = session.nextSlideInCurrentSection {
                let nextLabel = shouldConcealSlideTitle
                    ? "Next: \(nextSlide.positionLabel)"
                    : "Next: \(nextSlide.slideTitle)"
                let nextA11y = shouldConcealSlideTitle
                    ? "Advance to \(nextSlide.positionLabel)"
                    : "Advance to \(nextSlide.slideTitle), \(nextSlide.positionLabel)"
                Button {
                    _ = session.advanceFullRunStep()
                } label: {
                    HStack(spacing: 6) {
                        Text(nextLabel)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(primaryActionTextColor)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.horizontal, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(nextA11y)
                .accessibilityHint("Moves to the next slide within the current section while recording continues.")
                .accessibilityIdentifier("fullRunFullscreenAdvanceButton")
            } else if let nextSection = session.nextFullRunSection {
                Button {
                    _ = session.advanceFullRunStep()
                } label: {
                    HStack(spacing: 6) {
                        Text("Next Section: \(nextSection.title)")
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(primaryActionTextColor)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.horizontal, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Advance to \(nextSection.title), speaker \(nextSection.speaker)")
                .accessibilityHint("Records the current audio timestamp and moves to the next section.")
                .accessibilityIdentifier("fullRunFullscreenAdvanceButton")
            } else {
                stopButton(fullWidth: true)
            }
        }
    }

    private var idlePrimaryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.microphoneDeniedNoticeVisible || session.permissionStatus == .denied {
                HStack(alignment: .center, spacing: 8) {
                    Label("Mic off — use Silent Run or Setup.", systemImage: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Setup", action: onExitFullscreen)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.72, green: 0.90, blue: 1.0))
                }
            }

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                Button {
                    Task { await session.startRecording() }
                } label: {
                    Label("Start Full Run", systemImage: "mic.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .padding(.horizontal, 10)
                        .background(Color(red: 0.86, green: 0.22, blue: 0.24), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!session.canStartNewTake)
                .opacity(session.canStartNewTake ? 1 : 0.5)
                .accessibilityLabel("Start Full Run")
                .accessibilityHint("Starts one continuous offline recording for this talk.")
                .accessibilityIdentifier("fullRunFullscreenStartButton")

                Button {
                    session.startSilentRecall()
                } label: {
                    Label("Silent Run", systemImage: "mic.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .padding(.horizontal, 10)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.26), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!session.canStartNewTake)
                .opacity(session.canStartNewTake ? 1 : 0.5)
                .accessibilityLabel("Start Silent Full Run")
                .accessibilityHint("Rehearses section transitions with timer and reveals without recording audio.")
                .accessibilityIdentifier("fullRunFullscreenStartSilentButton")
            }
        }
    }

    @ViewBuilder
    private var utilityControlBar: some View {
        if isAccessibilitySize {
            accessibilityUtilityStack
        } else {
            HStack(spacing: 6) {
                exitFullscreenButton(labeled: false)

                if !session.isActiveTake && hasStepNav {
                    previousStepIconButton(height: 44)
                    nextStepIconButton
                }

                if let onSelectSlideIndex, slides.count > 1 {
                    slidesMenuButton(onSelect: onSelectSlideIndex, labeled: false)
                }

                if hasSlideArtwork {
                    slidePreviewToggleButton(labeled: false)
                }

                if session.practiceMode.supportsReveal {
                    revealButton(labeled: false)
                }

                Spacer(minLength: 4)

                if session.isActiveTake {
                    markerButton(labeled: false)
                    if hasNextStep {
                        stopButton(fullWidth: false)
                    }
                }
            }
        }
    }

    private var accessibilityUtilityStack: some View {
        VStack(spacing: 8) {
            if !session.isActiveTake && hasStepNav {
                HStack(spacing: 8) {
                    previousStepIconButton(height: 44)
                    nextStepIconButton
                }
            }

            if session.practiceMode.supportsReveal {
                revealButton(labeled: true)
            }

            if let onSelectSlideIndex, slides.count > 1 {
                slidesMenuButton(onSelect: onSelectSlideIndex, labeled: true)
            }

            if hasSlideArtwork {
                slidePreviewToggleButton(labeled: true)
            }

            if session.isActiveTake {
                markerButton(labeled: true)
                if hasNextStep {
                    stopButton(fullWidth: true)
                }
            }

            exitFullscreenButton(labeled: true)
        }
    }
}
