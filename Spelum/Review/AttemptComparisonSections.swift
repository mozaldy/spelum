import SwiftUI

struct ComparisonScopeBanner: View {
    let summary: AttemptComparisonSummary
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                summary.scope.title,
                systemImage: summary.scope.isDirectlyComparable
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(summary.scope.isDirectlyComparable ? Color.accentColor : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("comparisonScopeTitle")

            Text(summary.scope.detailMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let completionNote = summary.completionContextNote {
                Label(completionNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("comparisonCompletionNote")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comparisonScopeBanner")
    }
}

struct ComparisonReplayDeckCard: View {
    let label: String
    let attempt: AttemptRecord
    let descriptor: ComparableAttemptDescriptor
    let isOlderRevision: Bool
    let isActivePlayer: Bool
    let player: TakeAudioPlayer
    let isAccessibilitySize: Bool
    let onTogglePlay: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onOpenReview: () -> Void
    let onDeleteThis: () -> Void

    private var displayedTime: TimeInterval {
        isActivePlayer ? player.currentTime : 0
    }

    private var totalDuration: TimeInterval {
        if isActivePlayer && player.duration > 0 {
            return player.duration
        }
        return attempt.displayDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if isOlderRevision {
                Label("Revision \(attempt.talkRevisionNumber) (older)", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            if attempt.hasPlayableAudio {
                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { onSeek($0) }
                    ),
                    in: 0 ... max(totalDuration, 0.1)
                )
                .accessibilityLabel("\(label) playback position")
                .accessibilityValue(
                    "\(RehearsalTimeFormatter.accessibleDurationString(for: displayedTime)) " +
                    "of \(RehearsalTimeFormatter.accessibleDurationString(for: totalDuration))"
                )

                HStack {
                    Text(RehearsalTimeFormatter.clockString(for: displayedTime))
                    Spacer()
                    Text(RehearsalTimeFormatter.clockString(for: totalDuration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                Text(
                    attempt.isSilentRecall
                        ? "Silent recall — no audio recording."
                        : "No playable audio saved for this attempt."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                if attempt.hasPlayableAudio {
                    let isPlayingThis = isActivePlayer && player.isPlaying
                    Button(action: onTogglePlay) {
                        Label(
                            isPlayingThis ? "Pause \(label)" : "Play \(label)",
                            systemImage: isPlayingThis ? "pause.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("comparePlay_\(label.lowercased())")
                }

                Button(action: onOpenReview) {
                    Label("Open Review", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("compareOpenReview_\(label.lowercased())")
            }

            Button(role: .destructive, action: onDeleteThis) {
                Label("Delete \(label) & Keep Other", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("compareDelete_\(label.lowercased())")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("comparisonDeck_\(label.lowercased())")
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(label) · \(descriptor.title)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Label(attempt.status.displayName, systemImage: attempt.status.symbolName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(attempt.status == .ready ? .green : .orange)
            }
            Text(
                "\(attempt.startedAt.formatted(date: .abbreviated, time: .shortened)) · " +
                "\(attempt.practiceMode.displayName) · Rev \(attempt.talkRevisionNumber)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct ComparisonMetricsCard: View {
    let summary: AttemptComparisonSummary
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measured Facts & Optional Estimates")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            metricRow(
                title: "Duration (Measured)",
                earlierValue: RehearsalTimeFormatter.clockString(for: summary.earlier.displayDuration),
                laterValue: RehearsalTimeFormatter.clockString(for: summary.later.displayDuration),
                delta: summary.formattedDurationDelta
            )
            Divider()
            metricRow(
                title: "Cue Reveals (Measured)",
                earlierValue: "\(summary.earlier.revealCount)",
                laterValue: "\(summary.later.revealCount)",
                delta: summary.formattedRevealDelta
            )
            Divider()
            metricRow(
                title: "Practice Mode",
                earlierValue: summary.earlier.practiceMode.displayName,
                laterValue: summary.later.practiceMode.displayName,
                delta: nil
            )
            Divider()
            metricRow(
                title: "Manual Markers (Measured)",
                earlierValue: "\(summary.earlier.markerCount)",
                laterValue: "\(summary.later.markerCount)",
                delta: nil
            )

            if summary.earlier.estimatedWordsPerMinute != nil || summary.later.estimatedWordsPerMinute != nil {
                Divider()
                metricRow(
                    title: "Estimated Pace (Estimate)",
                    earlierValue: formattedWPM(summary.earlier.estimatedWordsPerMinute),
                    laterValue: formattedWPM(summary.later.estimatedWordsPerMinute),
                    delta: summary.estimatedWPMDelta.map { delta in
                        let sign = delta > 0 ? "+" : ""
                        return "\(sign)\(Int(delta.rounded())) WPM"
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("comparisonMetricsCard")
    }

    private func formattedWPM(_ wpm: Double?) -> String {
        guard let wpm else { return "Not analyzed" }
        return "\(Int(wpm.rounded())) WPM"
    }

    private func metricRow(
        title: String,
        earlierValue: String,
        laterValue: String,
        delta: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let delta {
                    Text(delta)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Earlier: \(earlierValue)")
                    Text("Later: \(laterValue)")
                }
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Earlier: \(earlierValue)")
                    Spacer()
                    Text("Later: \(laterValue)")
                }
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ComparisonFullRunSectionsCard: View {
    let rows: [FullRunSectionComparisonRow]
    let earlierHasAudio: Bool
    let laterHasAudio: Bool
    let isAccessibilitySize: Bool
    let onPlayEarlierAt: (TimeInterval) -> Void
    let onPlayLaterAt: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Section-by-Section Timing", systemImage: "timeline.selection")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Tap Play on any section to hear and compare the exact transition across both runs.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(rows) { row in
                sectionComparisonRow(row)
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("comparisonFullRunSectionsCard")
    }

    private func sectionComparisonRow(_ row: FullRunSectionComparisonRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.displayOrderIndex + 1). \(row.sectionTitle)")
                        .font(.subheadline.weight(.semibold))
                    Text(row.speakerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let delta = row.durationDelta {
                    Text(AttemptComparisonSummary.formatSignedSeconds(delta))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if row.speakerChanged {
                Text("Speaker changed between revisions")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                sectionJumpButton(
                    label: "Earlier",
                    transition: row.earlierTransition,
                    hasAudio: earlierHasAudio,
                    action: onPlayEarlierAt
                )
                sectionJumpButton(
                    label: "Later",
                    transition: row.laterTransition,
                    hasAudio: laterHasAudio,
                    action: onPlayLaterAt
                )
            }
        }
    }

    @ViewBuilder
    private func sectionJumpButton(
        label: String,
        transition: FullRunSectionTransition?,
        hasAudio: Bool,
        action: @escaping (TimeInterval) -> Void
    ) -> some View {
        if let transition {
            let durText = transition.duration.map { RehearsalTimeFormatter.clockString(for: $0) }
                ?? RehearsalTimeFormatter.clockString(for: transition.startTime)
            Button {
                if hasAudio {
                    action(transition.startTime)
                }
            } label: {
                Label("\(label): \(durText)", systemImage: hasAudio ? "play.fill" : "clock")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!hasAudio)
            .accessibilityLabel(
                "Play \(label) run at \(transition.sectionTitle), " +
                "\(RehearsalTimeFormatter.accessibleDurationString(for: transition.startTime))"
            )
        } else {
            Text("\(label): Not reached")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
