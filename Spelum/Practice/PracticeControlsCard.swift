import SwiftUI
import UIKit

struct PracticeMicrophoneDeniedCard: View {
    let canStartNewTake: Bool
    let isAccessibilitySize: Bool
    let onStartSilentRecall: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Microphone Access Is Off", systemImage: "mic.slash.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(
                "You can still rehearse offline using Silent Recall with the timer, " +
                "reveal counter, and manual markers — or enable Microphone in Settings."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                Button(action: onStartSilentRecall) {
                    Label("Start Silent Recall", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartNewTake)
                .accessibilityIdentifier("startSilentRecallFromDeniedButton")

                Button(action: onOpenSettings) {
                    Label("Open Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("openSettingsForMicButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("microphoneDeniedCard")
    }
}

struct PracticeRecoveryBanner: View {
    let phase: RecordingSessionPhase
    let isAccessibilitySize: Bool
    let onOpenReview: (UUID) -> Void
    let onRetrySection: () -> Void
    let onRetryFailedSave: () -> Void
    let onDiscardFailedSave: () -> Void
    let onStartSilentRecall: () -> Void

    var body: some View {
        switch phase {
        case .interrupted(let attemptID, let hasPlayableAudio, let reason):
            interruptedCard(attemptID: attemptID, hasPlayableAudio: hasPlayableAudio, reason: reason)
        case .saveFailed(let recovery):
            saveFailedCard(recovery: recovery)
        case .error(let message):
            errorCard(message: message)
        default:
            EmptyView()
        }
    }

    private func interruptedCard(
        attemptID: UUID,
        hasPlayableAudio: Bool,
        reason: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                hasPlayableAudio ? "Partial Take Preserved" : "Take Interrupted",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(.orange)

            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                Button {
                    onOpenReview(attemptID)
                } label: {
                    Label(
                        hasPlayableAudio ? "Review Partial Take" : "View Take Details",
                        systemImage: "waveform"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reviewInterruptedTakeButton")

                Button(action: onRetrySection) {
                    Label("Retry Section", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("retryAfterInterruptButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("interruptedRecoveryCard")
    }

    private func saveFailedCard(recovery: PendingSaveRecovery) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Save Needs Retry", systemImage: "externaldrive.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(
                recovery.hasPlayableAudio
                    ? "Your audio recording (\(RehearsalTimeFormatter.clockString(for: recovery.playableDuration))) " +
                        "is safely preserved on device, but saving its metadata failed: \(recovery.errorMessage)"
                    : "Saving this take failed: \(recovery.errorMessage)"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                Button(action: onRetryFailedSave) {
                    Label("Retry Save", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("retryFailedSaveButton")

                Button(role: .destructive, action: onDiscardFailedSave) {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("discardFailedSaveButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("saveFailedRecoveryCard")
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recording Issue", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onStartSilentRecall) {
                Label("Rehearse with Silent Recall", systemImage: "mic.slash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("recordingErrorCard")
    }
}

struct PracticeCaptureControlsCard: View {
    let session: RecordingSession
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader
            if session.isActiveTake {
                activeTakeButtons
            } else {
                idleTakeButtons
            }
            if !session.markers.isEmpty {
                markersSummary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    phaseLabel
                    elapsedTimerText
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    phaseLabel
                    Spacer()
                    elapsedTimerText
                }
            }
            Text("All recordings stay offline on this iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var elapsedTimerText: some View {
        Text(RehearsalTimeFormatter.clockString(for: session.elapsedDuration))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .accessibilityLabel("Elapsed time")
            .accessibilityValue(
                RehearsalTimeFormatter.accessibleDurationString(for: session.elapsedDuration)
            )
            .accessibilityIdentifier("practiceTimerLabel")
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch session.phase {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
        case .silentRecall:
            Label("Silent Recall", systemImage: "mic.slash.circle.fill")
                .font(.headline)
                .foregroundStyle(.blue)
        case .requestingPermission:
            Label("Checking Microphone…", systemImage: "mic")
                .font(.headline)
                .foregroundStyle(.secondary)
        case .finalizing:
            Label("Saving Take…", systemImage: "arrow.down.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
        default:
            Label("Ready to Rehearse", systemImage: "waveform")
                .font(.headline)
        }
    }

    private var activeTakeButtons: some View {
        let isSilent = session.phase == .silentRecall
        return AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
            Button {
                session.addManualMarker()
            } label: {
                Label("Add Marker", systemImage: "flag.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Add Marker")
            .accessibilityValue(
                session.markers.count == 1 ? "1 marker" : "\(session.markers.count) markers"
            )
            .accessibilityHint("Marks the current elapsed time for review.")
            .accessibilityIdentifier("addMarkerButton")

            Button(role: .destructive) {
                _ = session.stopRecording()
            } label: {
                Label(
                    isSilent ? "Finish Silent Recall" : "Stop & Save",
                    systemImage: "stop.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(isSilent ? .blue : .red)
            .accessibilityLabel(isSilent ? "Finish Silent Recall" : "Stop Recording")
            .accessibilityHint("Stops and saves this rehearsal take.")
            .accessibilityIdentifier("stopRecordingButton")
        }
    }

    private var idleTakeButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await session.startRecording() }
            } label: {
                Label("Record Take", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!session.canStartNewTake)
            .accessibilityLabel("Record Take")
            .accessibilityHint("Starts offline audio recording for this section.")
            .accessibilityIdentifier("recordTakeButton")

            Button {
                session.startSilentRecall()
            } label: {
                Label("Practice Without Audio (Silent Recall)", systemImage: "mic.slash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!session.canStartNewTake)
            .accessibilityLabel("Start Silent Recall")
            .accessibilityHint("Rehearses with timer, reveals, and markers without microphone recording.")
            .accessibilityIdentifier("silentRecallButton")
        }
    }

    private var markersSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Marked Moments (\(session.markers.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(session.markers) { marker in
                Text("• \(marker.label) — \(RehearsalTimeFormatter.clockString(for: marker.timestamp))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("activeMarkersSummary")
    }
}

struct AdaptiveActionStack<Content: View>: View {
    let isAccessibilitySize: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isAccessibilitySize {
            VStack(spacing: 10, content: content)
        } else {
            HStack(spacing: 10, content: content)
        }
    }
}
