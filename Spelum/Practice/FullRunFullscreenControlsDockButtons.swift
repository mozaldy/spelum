import SwiftUI

private struct FullRunDockUtilityLabel: View {
    let title: String
    let systemImage: String
    let labeled: Bool
    let foreground: Color
    let fill: Color
    let strokeOpacity: Double

    init(
        title: String,
        systemImage: String,
        labeled: Bool,
        foreground: Color = .white,
        fill: Color = Color.white.opacity(0.14),
        strokeOpacity: Double = 0.24
    ) {
        self.title = title
        self.systemImage = systemImage
        self.labeled = labeled
        self.foreground = foreground
        self.fill = fill
        self.strokeOpacity = strokeOpacity
    }

    var body: some View {
        Group {
            if labeled {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 12)
            } else {
                Image(systemName: systemImage)
                    .frame(width: 44, height: 44)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(foreground)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 1))
    }
}

private struct FullRunDockMarkerLabel: View {
    let labeled: Bool
    let markerCount: Int
    let badgeTextColor: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FullRunDockUtilityLabel(
                title: "Add Marker",
                systemImage: "flag.fill",
                labeled: labeled,
                fill: Color.white.opacity(0.16),
                strokeOpacity: 0.26
            )
            if !labeled && markerCount > 0 {
                Text("\(markerCount)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(badgeTextColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white, in: Capsule())
                    .offset(x: 4, y: -4)
            }
        }
    }
}

extension FullRunFullscreenControlsDock {
    func exitFullscreenButton(labeled: Bool) -> some View {
        Button(action: onExitFullscreen) {
            FullRunDockUtilityLabel(
                title: "Exit Fullscreen",
                systemImage: "arrow.down.right.and.arrow.up.left",
                labeled: labeled
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exit Fullscreen")
        .accessibilityHint("Returns to Full Run setup without stopping an active rehearsal.")
        .accessibilityIdentifier("fullRunExitFullscreenButton")
    }

    func previousStepIconButton(height: CGFloat) -> some View {
        Button {
            _ = session.retreatFullRunStep()
        } label: {
            Image(systemName: "chevron.left")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(session.canRetreatFullRunStep ? .white : .white.opacity(0.35))
                .frame(width: 44, height: height)
                .background(
                    Color.white.opacity(session.canRetreatFullRunStep ? 0.16 : 0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!session.canRetreatFullRunStep)
        .accessibilityLabel(previousButtonLabel)
        .accessibilityIdentifier("rehearsalPreviousSlideButton")
    }

    var nextStepIconButton: some View {
        Button {
            _ = session.advanceFullRunStep()
        } label: {
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(session.canAdvanceFullRunStep ? .white : .white.opacity(0.35))
                .frame(width: 44, height: 44)
                .background(
                    Color.white.opacity(session.canAdvanceFullRunStep ? 0.16 : 0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!session.canAdvanceFullRunStep)
        .accessibilityLabel(nextButtonLabel)
        .accessibilityIdentifier("rehearsalNextSlideButton")
    }

    func slidesMenuButton(onSelect: @escaping (Int) -> Void, labeled: Bool) -> some View {
        Menu {
            ForEach(slides) { item in
                Button {
                    onSelect(item.slideIndex)
                } label: {
                    let label = shouldConcealSlideTitle
                        ? item.positionLabel
                        : "\(item.slideIndex + 1). \(item.slideTitle)"
                    if item.slideIndex == clampedSlideIndex {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            FullRunDockUtilityLabel(title: "Slides", systemImage: "rectangle.stack", labeled: labeled)
        }
        .accessibilityLabel("Jump to slide in \(sectionTitle)")
        .accessibilityIdentifier("rehearsalSlidePickerMenu")
    }

    func slidePreviewToggleButton(labeled: Bool) -> some View {
        let symbol = showsSlidePreview ? "photo.fill" : "photo"
        let title = showsSlidePreview ? "Hide Slide Preview" : "Show Slide Preview"
        let tint: Color = showsSlidePreview
            ? Color(red: 0.72, green: 0.90, blue: 1.0)
            : .white.opacity(0.8)
        let fill = showsSlidePreview ? Color.white.opacity(0.20) : Color.white.opacity(0.12)
        return Button(action: onToggleSlidePreview) {
            FullRunDockUtilityLabel(
                title: title,
                systemImage: symbol,
                labeled: labeled,
                foreground: labeled ? .white : tint,
                fill: fill
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("fullRunToggleSlidePreviewButton")
    }

    func revealButton(labeled: Bool) -> some View {
        let isRevealed = session.isScriptRevealed
        let symbol = isRevealed ? "eye.slash.fill" : "eye.fill"
        let title = isRevealed ? "Hide Script" : "Reveal Script"
        let tint = isRevealed ? Color(red: 0.62, green: 0.88, blue: 1.0) : .white
        let activeFill = Color(red: 0.14, green: 0.44, blue: 0.94).opacity(0.35)
        let fill = isRevealed ? activeFill : Color.white.opacity(0.16)
        return Button {
            session.toggleReveal()
        } label: {
            FullRunDockUtilityLabel(
                title: title,
                systemImage: symbol,
                labeled: labeled,
                foreground: tint,
                fill: fill,
                strokeOpacity: 0.28
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(session.revealCount == 1 ? "1 reveal" : "\(session.revealCount) reveals")
        .accessibilityHint(
            isRevealed
                ? "Hides the full script again."
                : "Shows the script and counts one reveal during an active take."
        )
        .accessibilityIdentifier("fullRunFullscreenRevealButton")
    }

    func markerButton(labeled: Bool) -> some View {
        Button {
            session.addManualMarker()
        } label: {
            FullRunDockMarkerLabel(
                labeled: labeled,
                markerCount: session.markers.count,
                badgeTextColor: primaryActionTextColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Marker")
        .accessibilityValue(
            session.markers.count == 1 ? "1 marker" : "\(session.markers.count) markers"
        )
        .accessibilityIdentifier("fullRunFullscreenAddMarkerButton")
    }

    func stopButton(fullWidth: Bool) -> some View {
        let isSilent = session.phase == .silentRecall
        let fullTitle = stopButtonTitle(isSilent: isSilent)
        let compactTitle = session.isOnFinalFullRunSection ? "Finish" : "Stop"
        return Button(role: .destructive) {
            _ = session.isOnFinalFullRunSection
                ? session.stopRecording()
                : session.finishFullRunEarly()
        } label: {
            Label(fullWidth ? fullTitle : compactTitle, systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 46 : 44)
                .padding(.horizontal, 12)
                .background(
                    isSilent
                        ? Color(red: 0.14, green: 0.44, blue: 0.94)
                        : Color(red: 0.86, green: 0.22, blue: 0.24),
                    in: RoundedRectangle(cornerRadius: fullWidth ? 12 : 10)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fullTitle)
        .accessibilityHint(
            session.isOnFinalFullRunSection
                ? "Finishes and saves the full run."
                : "Stops early and saves all sections completed so far."
        )
        .accessibilityIdentifier("fullRunFullscreenStopButton")
    }

    func stopButtonTitle(isSilent: Bool) -> String {
        if session.isOnFinalFullRunSection {
            return isSilent ? "Finish Silent Run" : "Finish & Save"
        }
        return "Finish Early & Save"
    }
}
