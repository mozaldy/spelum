import SwiftUI

struct AttemptHistoryRowContent: View {
    let attempt: AttemptRecord
    let isOlderRevision: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            metricsBlock

            if let progressSummary = fullRunProgressSummary {
                Text(progressSummary)
                    .font(.caption)
                    .foregroundStyle(attempt.fullRunPayload?.finishedEarly == true ? .orange : .secondary)
            }

            if let wpm = completedEstimatedWPM {
                Label("\(Int(wpm.rounded())) WPM (est.)", systemImage: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isOlderRevision {
                Label(
                    "Revision \(attempt.talkRevisionNumber) (older)",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("olderRevisionHistoryBadge")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens saved review and playback.")
    }

    @ViewBuilder
    private var headerRow: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                kindAndTitle
                statusBadge
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                kindAndTitle
                Spacer()
                statusBadge
            }
        }
    }

    private var kindAndTitle: some View {
        HStack(spacing: 6) {
            Image(systemName: attempt.attemptKind.symbolName)
                .font(.caption)
                .foregroundStyle(.tint)
            Text(attempt.displayTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBadge: some View {
        Label(attempt.status.displayName, systemImage: attempt.status.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch attempt.status {
        case .ready: .green
        case .interrupted: .orange
        case .silentCompleted: .blue
        case .inProgress: .secondary
        }
    }

    @ViewBuilder
    private var metricsBlock: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(durationLabel)
                Text(attempt.practiceMode.displayName)
                Text(revealSummary)
                if !attempt.markers.isEmpty {
                    Text(markerSummary)
                }
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
            Text(compactSummary)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var durationLabel: String {
        if attempt.hasPlayableAudio {
            return RehearsalTimeFormatter.clockString(for: attempt.playableDuration)
        }
        if attempt.isSilentRecall {
            return "\(RehearsalTimeFormatter.clockString(for: attempt.elapsedDuration)) silent"
        }
        return "No audio"
    }

    private var revealSummary: String {
        attempt.revealCount == 1 ? "1 reveal" : "\(attempt.revealCount) reveals"
    }

    private var markerSummary: String {
        attempt.markers.count == 1 ? "1 marker" : "\(attempt.markers.count) markers"
    }

    private var compactSummary: String {
        var parts = [
            attempt.attemptKind.shortLabel,
            durationLabel,
            attempt.practiceMode.displayName,
            revealSummary
        ]
        if !attempt.markers.isEmpty {
            parts.append(markerSummary)
        }
        return parts.joined(separator: " · ")
    }

    private var fullRunProgressSummary: String? {
        attempt.fullRunPayload?.progressSummary(status: attempt.status)
    }

    private var completedEstimatedWPM: Double? {
        guard let analysis = attempt.timingAnalysis, analysis.outcome == .completed else {
            return nil
        }
        return analysis.estimatedWordsPerMinute
    }
}
