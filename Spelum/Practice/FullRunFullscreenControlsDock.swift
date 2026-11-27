import SwiftUI

struct FullRunFullscreenControlsDock: View {
    let session: RecordingSession
    let isAccessibilitySize: Bool
    let onExitFullscreen: () -> Void

    private let primaryActionTextColor = Color(red: 0.04, green: 0.14, blue: 0.38)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.isActiveTake {
                activeMetricsStrip
                activeRunButtons
            } else {
                idleControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(red: 0.02, green: 0.07, blue: 0.20)
                .opacity(0.80)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.20))
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
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.84))
            .accessibilityIdentifier("fullRunFullscreenMetricsStrip")
    }

    private var activeRunButtons: some View {
        let isSilent = session.phase == .silentRecall
        return VStack(spacing: 10) {
            if let nextSection = session.nextFullRunSection {
                Button {
                    _ = session.advanceFullRunSection()
                } label: {
                    VStack(spacing: 2) {
                        Label("Next Section: \(nextSection.title)", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                        Text(nextSection.speakerSummary)
                            .font(.caption.weight(.medium))
                            .opacity(0.85)
                    }
                    .foregroundStyle(primaryActionTextColor)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .padding(.horizontal, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Advance to \(nextSection.title), speaker \(nextSection.speaker)")
                .accessibilityHint("Records the current audio timestamp and moves to the next section.")
                .accessibilityIdentifier("fullRunFullscreenAdvanceButton")
            }

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                Button {
                    session.addManualMarker()
                } label: {
                    Label("Add Marker", systemImage: "flag.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Marker")
                .accessibilityValue(
                    session.markers.count == 1 ? "1 marker" : "\(session.markers.count) markers"
                )
                .accessibilityIdentifier("fullRunFullscreenAddMarkerButton")

                Button(role: .destructive) {
                    _ = session.isOnFinalFullRunSection
                        ? session.stopRecording()
                        : session.finishFullRunEarly()
                } label: {
                    Label(stopButtonTitle(isSilent: isSilent), systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            isSilent
                                ? Color(red: 0.14, green: 0.44, blue: 0.94)
                                : Color(red: 0.86, green: 0.22, blue: 0.24),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(stopButtonTitle(isSilent: isSilent))
                .accessibilityHint(
                    session.isOnFinalFullRunSection
                        ? "Finishes and saves the full run."
                        : "Stops early and saves all sections completed so far."
                )
                .accessibilityIdentifier("fullRunFullscreenStopButton")
            }
        }
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.microphoneDeniedNoticeVisible || session.permissionStatus == .denied {
                HStack(alignment: .center, spacing: 8) {
                    Label("Microphone off — use Silent Run or exit to open Settings.", systemImage: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Setup", action: onExitFullscreen)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.72, green: 0.90, blue: 1.0))
                }
            }

            Button {
                Task { await session.startRecording() }
            } label: {
                Label("Start Full Run", systemImage: "mic.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color(red: 0.86, green: 0.22, blue: 0.24), in: RoundedRectangle(cornerRadius: 14))
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
                Label("Silent Full Run (No Audio)", systemImage: "mic.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
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

    private func stopButtonTitle(isSilent: Bool) -> String {
        if session.isOnFinalFullRunSection {
            return isSilent ? "Finish Silent Run" : "Finish & Save"
        }
        return "Finish Early & Save"
    }
}
