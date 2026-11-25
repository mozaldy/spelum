import SwiftUI

struct TakeReviewHeaderCard: View {
    let attempt: AttemptRecord
    let presentationTitle: String?
    let sectionTitle: String
    let isOlderRevision: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sectionTitle)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    statusBadge
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(sectionTitle)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    statusBadge
                }
            }

            if let presentationTitle {
                Text("\(presentationTitle) · Revision \(attempt.talkRevisionNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Revision \(attempt.talkRevisionNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isOlderRevision {
                Label(
                    "Recorded on earlier Revision \(attempt.talkRevisionNumber)",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("olderRevisionReviewBadge")
            }

            if let reason = attempt.interruptionReason, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reviewInterruptionReason")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusBadge: some View {
        Label(attempt.status.displayName, systemImage: attempt.status.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("reviewStatusBadge")
    }

    private var statusColor: Color {
        switch attempt.status {
        case .ready: .green
        case .interrupted: .orange
        case .silentCompleted: .blue
        case .inProgress: .secondary
        }
    }
}

struct TakeReviewPlaybackCard: View {
    let attempt: AttemptRecord
    let player: TakeAudioPlayer
    let isAccessibilitySize: Bool

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        if attempt.hasPlayableAudio {
            audioPlayerCard
        } else if attempt.isSilentRecall {
            silentRecallCard
        } else {
            missingAudioCard
        }
    }

    private var audioPlayerCard: some View {
        let totalDuration = max(player.duration, attempt.playableDuration)
        let displayedTime = isScrubbing ? scrubTime : player.currentTime

        return VStack(alignment: .leading, spacing: 12) {
            Label("Playback", systemImage: "waveform")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let errorMessage = player.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { newValue in
                            scrubTime = newValue
                            if !isScrubbing {
                                player.seek(to: newValue)
                            }
                        }
                    ),
                    in: 0 ... max(totalDuration, 0.1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            player.seek(to: scrubTime)
                        }
                    }
                )
                .accessibilityLabel("Playback position")
                .accessibilityValue(
                    "\(RehearsalTimeFormatter.accessibleDurationString(for: displayedTime)) " +
                    "of \(RehearsalTimeFormatter.accessibleDurationString(for: totalDuration))"
                )
                .accessibilityIdentifier("playbackScrubSlider")

                HStack {
                    Text(RehearsalTimeFormatter.clockString(for: displayedTime))
                    Spacer()
                    Text(RehearsalTimeFormatter.clockString(for: totalDuration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

                transportControls(totalDuration: totalDuration)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("audioPlaybackCard")
    }

    @ViewBuilder
    private func transportControls(totalDuration: TimeInterval) -> some View {
        if isAccessibilitySize {
            VStack(spacing: 10) {
                playPauseButton(totalDuration: totalDuration)
                skipButton(delta: -5, title: "Back 5 Seconds", symbol: "gobackward.5", id: "skipBackwardButton")
                skipButton(delta: 5, title: "Forward 5 Seconds", symbol: "goforward.5", id: "skipForwardButton")
            }
        } else {
            HStack(spacing: 12) {
                iconSkipButton(
                    delta: -5,
                    label: "Skip back 5 seconds",
                    symbol: "gobackward.5",
                    id: "skipBackwardButton"
                )
                playPauseButton(totalDuration: totalDuration)
                iconSkipButton(
                    delta: 5,
                    label: "Skip forward 5 seconds",
                    symbol: "goforward.5",
                    id: "skipForwardButton"
                )
            }
        }
    }

    private func playPauseButton(totalDuration: TimeInterval) -> some View {
        let playLabel = player.isPlaying ? "Pause Take" : "Play Take"
        let playSymbol = player.isPlaying ? "pause.fill" : "play.fill"
        return Button {
            player.togglePlayPause()
        } label: {
            Label(playLabel, systemImage: playSymbol)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!player.isLoaded)
        .accessibilityLabel(playLabel)
        .accessibilityValue(
            "\(RehearsalTimeFormatter.accessibleDurationString(for: player.currentTime)) " +
            "of \(RehearsalTimeFormatter.accessibleDurationString(for: totalDuration))"
        )
        .accessibilityIdentifier("playPauseTakeButton")
    }

    private func skipButton(delta: TimeInterval, title: String, symbol: String, id: String) -> some View {
        Button {
            player.skip(by: delta)
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!player.isLoaded)
        .accessibilityIdentifier(id)
    }

    private func iconSkipButton(delta: TimeInterval, label: String, symbol: String, id: String) -> some View {
        Button {
            player.skip(by: delta)
        } label: {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(minWidth: 48, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .disabled(!player.isLoaded)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var silentRecallCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Silent Recall Take", systemImage: "mic.slash.circle.fill")
                .font(.headline)
                .foregroundStyle(.blue)
            Text(
                "This take was rehearsed without audio recording. " +
                "Elapsed recall time, script reveals, and manual markers were saved below."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("silentRecallReviewCard")
    }

    private var missingAudioCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No Playable Audio", systemImage: "waveform.slash")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("This take ended before playable audio could be saved. Tap Retry Section below to record again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct TakeReviewFactsAndMarkers: View {
    let attempt: AttemptRecord
    let isAudioLoaded: Bool
    let currentPlaybackTime: TimeInterval
    let isAccessibilitySize: Bool
    let onSeekMarker: (TimeInterval) -> Void
    let onAddMarkerAtCurrentTime: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            factsCard
            if !attempt.markers.isEmpty || isAudioLoaded {
                markersCard
            }
        }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recorded Facts (Measured)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            factRow(
                title: attempt.hasPlayableAudio ? "Playable Duration" : "Elapsed Time",
                value: RehearsalTimeFormatter.clockString(for: attempt.displayDuration)
            )
            Divider()
            factRow(title: "Practice Mode", value: attempt.practiceMode.displayName)
            Divider()
            factRow(
                title: "Script Reveals",
                value: attempt.revealCount == 1 ? "1 reveal" : "\(attempt.revealCount) reveals"
            )
            Divider()
            factRow(
                title: "Manual Markers",
                value: attempt.markers.count == 1 ? "1 marker" : "\(attempt.markers.count) markers"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("recordedFactsCard")
    }

    @ViewBuilder
    private func factRow(title: String, value: String) -> some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } else {
            LabeledContent(title, value: value)
                .monospacedDigit()
        }
    }

    private var markersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Manual Markers (\(attempt.markers.count))", systemImage: "flag.fill")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if attempt.markers.isEmpty {
                Text("Place a manual marker while listening to return directly to any moment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(attempt.markers) { marker in
                    Button {
                        if isAudioLoaded { onSeekMarker(marker.timestamp) }
                    } label: {
                        HStack {
                            Text(marker.label).font(.body).foregroundStyle(.primary)
                            Spacer()
                            Text(RehearsalTimeFormatter.clockString(for: marker.timestamp))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(isAudioLoaded ? Color.accentColor : Color.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAudioLoaded)
                    .accessibilityLabel(
                        "\(marker.label), at \(RehearsalTimeFormatter.accessibleDurationString(for: marker.timestamp))"
                    )
                    .accessibilityHint(
                        isAudioLoaded ? "Seeks playback to this marked moment." : "Recorded marker timestamp."
                    )
                    .accessibilityIdentifier("reviewMarker_\(marker.id.uuidString)")

                    if marker.id != attempt.markers.last?.id { Divider() }
                }
            }

            if isAudioLoaded {
                if !attempt.markers.isEmpty { Divider() }
                Button(action: onAddMarkerAtCurrentTime) {
                    Label(
                        "Add Marker at \(RehearsalTimeFormatter.clockString(for: currentPlaybackTime))",
                        systemImage: "flag.badge.ellipsis"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                    "Add manual marker at \(RehearsalTimeFormatter.accessibleDurationString(for: currentPlaybackTime))"
                )
                .accessibilityHint("Saves a measured manual marker at the current playback position.")
                .accessibilityIdentifier("addManualMarkerInReviewButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("reviewMarkersCard")
    }
}
