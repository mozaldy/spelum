import SwiftUI

struct TakeReviewAnalysisResultContent: View {
    let result: TimingAnalysisResult
    let isAudioLoaded: Bool
    let currentPlaybackTime: TimeInterval
    let totalDuration: TimeInterval
    let isAccessibilitySize: Bool
    let showReanalyzeAction: Bool
    let onSeekObservation: (TimingObservation) -> Void
    let onAddManualMarker: (String) -> Void
    let onReanalyze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            paceSummaryRow

            if !result.observations.isEmpty {
                Divider()
                observationsSection
            }

            if !result.ambiguousNotes.isEmpty {
                Divider()
                ambiguousNotesSection
            }

            if showReanalyzeAction {
                Divider()
                reanalyzeFooter
            }
        }
    }

    private var paceSummaryRow: some View {
        let summary = paceSummaryTexts()
        return VStack(alignment: .leading, spacing: 4) {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated Pace")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(summary.value)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
            } else {
                LabeledContent("Estimated Pace", value: summary.value)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            }
            Text(summary.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estimated Pace")
        .accessibilityValue(summary.accessibleValue)
        .accessibilityIdentifier("estimatedPaceSummary")
    }

    private var observationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timestamped Evidence (Estimates)")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(result.observations) { observation in
                TakeReviewObservationRow(
                    observation: observation,
                    isAudioLoaded: isAudioLoaded,
                    totalDuration: totalDuration,
                    isAccessibilitySize: isAccessibilitySize,
                    onSeek: { onSeekObservation(observation) }
                )
                if observation.id != result.observations.last?.id {
                    Divider()
                }
            }
        }
    }

    private var ambiguousNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Uncertain Alignment & Context")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(result.ambiguousNotes) { note in
                TakeReviewAmbiguousNoteRow(
                    note: note,
                    isAudioLoaded: isAudioLoaded,
                    currentPlaybackTime: currentPlaybackTime,
                    onAddManualMarker: { onAddManualMarker(note.suggestedMarkerLabel) }
                )
            }
        }
    }

    private var reanalyzeFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-device \(result.localeIdentifier) · Analysis v\(result.analysisVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("analysisVersionLabel")

            Button(action: onReanalyze) {
                Label("Reanalyze Take", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(
                "Re-runs on-device English transcription and replaces current observations without adding a take."
            )
            .accessibilityIdentifier("reanalyzeTakeButton")
        }
    }

    private struct PaceSummaryText {
        let value: String
        let caption: String
        let accessibleValue: String
    }

    private func paceSummaryTexts() -> PaceSummaryText {
        if let wpm = result.estimatedWordsPerMinute {
            let roundedWPM = Int(wpm.rounded())
            let audioClock = RehearsalTimeFormatter.clockString(for: result.elapsedAudioDuration)
            let wordLabel = result.recognizedWordCount == 1 ? "word" : "words"
            let accessibleDuration = RehearsalTimeFormatter.accessibleDurationString(
                for: result.elapsedAudioDuration
            )
            return PaceSummaryText(
                value: "\(roundedWPM) est. WPM",
                caption: "\(result.recognizedWordCount) recognized \(wordLabel) ÷ \(audioClock) audio (estimate)",
                accessibleValue: "\(roundedWPM) estimated words per minute from " +
                    "\(result.recognizedWordCount) recognized \(wordLabel) over \(accessibleDuration)"
            )
        }
        let reason = "Omitted because finalized non-overlapping word timing was unavailable."
        return PaceSummaryText(value: "Not Estimated", caption: reason, accessibleValue: "Not estimated. \(reason)")
    }
}

private struct TakeReviewObservationRow: View {
    let observation: TimingObservation
    let isAudioLoaded: Bool
    let totalDuration: TimeInterval
    let isAccessibilitySize: Bool
    let onSeek: () -> Void

    var body: some View {
        let startClock = RehearsalTimeFormatter.clockString(for: observation.startTime)
        let endClock = RehearsalTimeFormatter.clockString(for: observation.endTime)
        let seekTime = observation.seekTarget(maxDuration: totalDuration)
        let seekClock = RehearsalTimeFormatter.clockString(for: seekTime)
        let seekAccessible = RehearsalTimeFormatter.accessibleDurationString(for: seekTime)

        Button {
            if isAudioLoaded { onSeek() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                headerRow(startClock: startClock, endClock: endClock)

                Text(observation.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(observation.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isAudioLoaded {
                    Label("Play from \(seekClock) (with lead-in)", systemImage: "play.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!isAudioLoaded)
        .accessibilityLabel(
            "\(observation.title), \(observation.detail), estimated at " +
            "\(RehearsalTimeFormatter.accessibleDurationString(for: observation.startTime))"
        )
        .accessibilityHint(
            isAudioLoaded
                ? "Seeks playback with a small lead-in to \(seekAccessible) and plays."
                : "Audio is not loaded."
        )
        .accessibilityIdentifier("timingObservation_\(observation.id.uuidString)")
    }

    @ViewBuilder
    private func headerRow(startClock: String, endClock: String) -> some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Label(observation.kind.badgeLabel, systemImage: observation.kind.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("\(startClock) – \(endClock)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Label(observation.kind.badgeLabel, systemImage: observation.kind.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Text("\(startClock) – \(endClock)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TakeReviewAmbiguousNoteRow: View {
    let note: AmbiguousEvidenceNote
    let isAudioLoaded: Bool
    let currentPlaybackTime: TimeInterval
    let onAddManualMarker: () -> Void

    var body: some View {
        let currentClock = RehearsalTimeFormatter.clockString(for: currentPlaybackTime)
        let currentAccessible = RehearsalTimeFormatter.accessibleDurationString(for: currentPlaybackTime)

        VStack(alignment: .leading, spacing: 8) {
            Label(note.title, systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(note.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if note.offersManualMarking && isAudioLoaded {
                Button(action: onAddManualMarker) {
                    Label("Mark Current Moment (\(currentClock))", systemImage: "flag.badge.ellipsis")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Mark current playback moment at \(currentAccessible)")
                .accessibilityHint("Saves a manual marker so you can jump back to this spot during review.")
                .accessibilityIdentifier("markUncertainMomentButton_\(note.reason.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ambiguousEvidenceNote_\(note.reason.rawValue)")
    }
}
