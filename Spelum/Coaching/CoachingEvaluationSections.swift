import SwiftUI

struct CoachingEvaluationResultsSections: View {
    let session: CoachingEvaluationSession

    var body: some View {
        let stats = session.summary()
        Section("Qualification Verdict") {
            Label(
                stats.decisionHeadline,
                systemImage: stats.isQualifiedForShipping ? "checkmark.seal.fill" : "shield.lefthalf.filled"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(stats.isQualifiedForShipping ? .green : .orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("evaluationDecisionHeadline")

            LabeledContent("Useful (On-Device vs Authored)") {
                Text(
                    "\(stats.modelUsefulCount)/\(stats.totalCases) vs " +
                    "\(stats.authoredUsefulCount)/\(stats.totalCases)"
                )
                .font(.footnote.monospacedDigit())
            }
            LabeledContent("Preference (Model / Authored / Tie / Neither)") {
                Text(
                    "\(stats.modelPreferredCount) / \(stats.authoredPreferredCount) / " +
                    "\(stats.tieCount) / \(stats.neitherCount)"
                )
                .font(.footnote.monospacedDigit())
            }
            LabeledContent("On-Device Safety Violations") {
                Text("\(stats.totalModelSafetyViolations)")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(stats.totalModelSafetyViolations == 0 ? .green : .red)
            }
            LabeledContent("Model Fallbacks to Authored") {
                Text("\(stats.modelFallbackCount)/\(stats.totalCases)")
                    .font(.footnote.monospacedDigit())
            }
        }

        Section("Latency & Repeated Variation") {
            LabeledContent("Cold Model Latency") {
                Text(Self.formatMS(stats.coldLatencyMilliseconds))
                    .font(.footnote.monospacedDigit())
            }
            LabeledContent("Warm Median Latency") {
                Text(Self.formatMS(stats.warmMedianLatencyMilliseconds))
                    .font(.footnote.monospacedDigit())
            }
            if let minMS = stats.warmMinLatencyMilliseconds,
               let maxMS = stats.warmMaxLatencyMilliseconds {
                LabeledContent("Warm Range") {
                    Text("\(Self.formatMS(minMS)) – \(Self.formatMS(maxMS))")
                        .font(.footnote.monospacedDigit())
                }
            }
            ForEach(session.repeatVariationResults) { repeatItem in
                VStack(alignment: .leading, spacing: 4) {
                    Text(repeatItem.caseTitle)
                        .font(.footnote.weight(.semibold))
                    let agreePct = Int((repeatItem.techniqueAgreementRate * 100).rounded())
                    let simPct = Int((repeatItem.meanTokenOverlapSimilarity * 100).rounded())
                    Text(
                        "\(repeatItem.trialCount) trials · \(repeatItem.uniqueActionCount) phrasing(s) · " +
                        "Technique agreement \(agreePct)% · Overlap \(simPct)% · Fallbacks \(repeatItem.fallbackCount)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
    }

    static func formatMS(_ value: Double?) -> String {
        guard let value else { return "N/A (model unavailable)" }
        return String(format: "%.0f ms", value)
    }
}

struct CoachingEvaluationCaseRow: View {
    let index: Int
    let entry: BlindedEvaluationEntry
    let isUnblinded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(index + 1). \(entry.title)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: entry.isRated ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(entry.isRated ? .green : .secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Case \(index + 1): \(entry.title), \(entry.category.displayName), " +
            "\(entry.isRated ? "rated" : "not yet rated")"
        )
    }

    private var rowSubtitle: String {
        var parts = [entry.category.displayName]
        if entry.expectsAbstention {
            parts.append("Abstention check")
        }
        if isUnblinded, let ms = entry.modelLatencyMilliseconds {
            parts.append(CoachingEvaluationResultsSections.formatMS(ms))
        }
        if isUnblinded, entry.modelFellBackToAuthored {
            parts.append("Fallback")
        }
        return parts.joined(separator: " · ")
    }
}
