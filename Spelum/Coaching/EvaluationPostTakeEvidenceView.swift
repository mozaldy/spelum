import SwiftUI

struct EvaluationPostTakeEvidenceView: View {
    let evidence: EvaluationPostTakeEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recorded Take Evidence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            takeSummaryRow
            markersBlock
            observationsBlock
            ambiguityBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("evaluationPostTakeEvidenceCard")
    }

    private var takeSummaryRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                "Analysis: \(evidence.analysisOutcomeLabel) · " +
                "Recognized words: \(evidence.recognizedWordCount)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let wpm = evidence.estimatedWordsPerMinute {
                let rounded = Int(wpm.rounded())
                let note = evidence.hasBlockingAmbiguity
                    ? "Est. Pace: \(rounded) WPM (accompanies timing ambiguity)"
                    : "Est. Pace: \(rounded) WPM"
                Text(note)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(evidence.hasBlockingAmbiguity ? .orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Est. Pace: Not reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var markersBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Manual Markers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if evidence.markers.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence.markers) { marker in
                    Text("• \(marker.formattedLine)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var observationsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timed Observations")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if evidence.observations.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence.observations) { obs in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("• \(obs.kindDisplayName) (\(obs.intervalDisplayText))")
                            .font(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let passage = obs.passageDisplayText {
                            Text(passage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var ambiguityBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ambiguity Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if evidence.ambiguityNotes.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence.ambiguityNotes) { note in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("• \(note.reason.neutralDisplayLabel)")
                            .font(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(note.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
