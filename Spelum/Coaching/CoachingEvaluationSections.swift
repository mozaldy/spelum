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

            LabeledContent("Useful (Non-Fallback Model vs Authored)") {
                Text(
                    "\(stats.modelUsefulCount)/\(stats.totalCases) vs " +
                    "\(stats.authoredUsefulCount)/\(stats.totalCases)"
                )
                .font(.footnote.monospacedDigit())
            }
            LabeledContent("Preference (Model / Authored / Fallback / Tie / Neither)") {
                Text(
                    "\(stats.modelPreferredCount) / \(stats.authoredPreferredCount) / " +
                    "\(stats.fallbackPreferredCount) / \(stats.tieCount) / \(stats.neitherCount)"
                )
                .font(.footnote.monospacedDigit())
            }
            LabeledContent("On-Device Safety Violations") {
                Text("\(stats.totalModelSafetyViolations)")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(stats.totalModelSafetyViolations == 0 ? .green : .red)
            }
            LabeledContent("Abstention vs Fixture Tags (Diagnostic)") {
                Text(
                    "\(stats.modelAbstentionCorrectCount)/\(stats.expectedAbstentionCount) " +
                    "(missed \(stats.modelMissedAbstentionCount), false \(stats.modelFalseAbstentionCount))"
                )
                .font(.footnote.monospacedDigit())
            }
            LabeledContent("Model Fallbacks to Authored") {
                Text("\(stats.modelFallbackCount)/\(stats.totalCases) (val \(stats.modelValidationFailureCount))")
                    .font(.footnote.monospacedDigit())
            }
        }

        Section("Latency & Repeated Variation") {
            LabeledContent("First Request After Launch") {
                Text(Self.formatCold(stats.coldLatencyMilliseconds, status: stats.coldLatencyStatus))
                    .font(.footnote.monospacedDigit())
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Subsequent Requests (Median)") {
                Text(Self.formatMS(stats.warmMedianLatencyMilliseconds))
                    .font(.footnote.monospacedDigit())
            }
            if let minMS = stats.warmMinLatencyMilliseconds,
               let maxMS = stats.warmMaxLatencyMilliseconds {
                LabeledContent("Subsequent Requests (Range)") {
                    Text("\(Self.formatMS(minMS)) – \(Self.formatMS(maxMS))")
                        .font(.footnote.monospacedDigit())
                }
            }
            ForEach(session.repeatVariationResults) { repeatItem in
                VStack(alignment: .leading, spacing: 4) {
                    Text(repeatItem.caseTitle)
                        .font(.footnote.weight(.semibold))
                    Text(Self.formatRepeatLine(repeatItem))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
    }

    static func formatCold(_ value: Double?, status: ColdLatencyMeasurementStatus) -> String {
        if let value, status == .verifiedColdLaunch {
            return String(format: "%.0f ms", value)
        }
        return status.displayLabel
    }

    static func formatMS(_ value: Double?) -> String {
        guard let value else { return "N/A (no successful model calls)" }
        return String(format: "%.0f ms", value)
    }

    static func formatRepeatLine(_ item: RepeatVariationResult) -> String {
        let base = "\(item.successfulTrialCount)/\(item.trialCount) model trials · " +
            "\(item.uniqueActionCount) phrasing(s) · Fallbacks \(item.fallbackCount)"
        guard let agree = item.techniqueAgreementRate,
              let sim = item.meanTokenOverlapSimilarity else {
            return "\(base) · Stability N/A (< 2 model trials)"
        }
        let agreePct = Int((agree * 100).rounded())
        let simPct = Int((sim * 100).rounded())
        return "\(base) · Agreement \(agreePct)% · Overlap \(simPct)%"
    }
}

struct CoachingEvaluationCaseRow: View {
    let index: Int
    let entry: BlindedEvaluationEntry
    let isUnblinded: Bool

    private var displayedTitle: String {
        entry.displayTitle(at: index, isUnblinded: isUnblinded)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayedTitle)
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
            "\(displayedTitle), \(entry.category.displayName), " +
            "\(entry.isRated ? "rated" : "not yet rated")"
        )
    }

    private var rowSubtitle: String {
        var parts = [entry.category.displayName]
        if isUnblinded, entry.expectsAbstention {
            parts.append("Abstention check")
        }
        if isUnblinded, let ms = entry.modelLatencyMilliseconds {
            parts.append(CoachingEvaluationResultsSections.formatMS(ms))
        }
        if isUnblinded, entry.isModelFallback {
            parts.append("Fallback")
        }
        return parts.joined(separator: " · ")
    }
}

struct CoachingEvaluationEnvironmentSection: View {
    let environment: CoachingDeviceEnvironment
    let modelAvailability: CoachingModelAvailability

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shipped Defaults: Authored Baseline")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "Both pre-practice and post-take stay on authored cues until physical-device " +
                    "blinded results reach 16/20 useful, 0 safety issues, 0 fallbacks, and clear preference."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            LabeledContent("Device") {
                Text(
                    environment.isSimulator
                        ? "Simulator (\(environment.osDescription))"
                        : "\(environment.deviceModel) · \(environment.osDescription)"
                )
                .font(.footnote)
                .foregroundStyle(environment.isSimulator ? .orange : .primary)
            }

            LabeledContent("On-Device Model") {
                Text(modelAvailability.shortStatusLabel)
                    .font(.footnote)
                    .foregroundStyle(modelAvailability.isAvailable ? .green : .secondary)
            }

            if !modelAvailability.isAvailable {
                Label(
                    "On-device model is unavailable here. Runs record authored fallbacks only " +
                    "and cannot qualify on-device generation.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("evaluationUnavailableBanner")
            }
        } header: {
            Text("Internal Blinded Comparison")
        }
    }
}
