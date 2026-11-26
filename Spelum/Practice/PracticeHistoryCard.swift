import SwiftUI

struct PracticeHistoryCard: View {
    let attempts: [AttemptRecord]
    let currentSectionRevisionID: UUID?
    let errorMessage: String?
    let isAccessibilitySize: Bool
    let onOpenReview: (UUID) -> Void
    let onRequestDelete: (AttemptRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved Takes (\(attempts.count))", systemImage: "clock")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if attempts.isEmpty {
                Text("Completed, interrupted, and silent takes for this section appear here for replay and retry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(attempts, id: \.id) { attempt in
                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            onOpenReview(attempt.id)
                        } label: {
                            PracticeHistoryRow(
                                attempt: attempt,
                                isCurrentSectionRevision: attempt.sectionRevisionID == currentSectionRevisionID,
                                isAccessibilitySize: isAccessibilitySize
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("historyAttemptRow_\(attempt.id.uuidString)")

                        Button(role: .destructive) {
                            onRequestDelete(attempt)
                        } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            "Delete take from \(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .accessibilityIdentifier("deleteHistoryAttemptButton_\(attempt.id.uuidString)")
                    }
                    if attempt.id != attempts.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("sectionHistoryCard")
    }
}
