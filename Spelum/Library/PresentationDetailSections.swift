import SwiftUI

struct SectionRowView: View {
    let index: Int
    let section: SectionRevisionRecord
    let handoff: HandoffContext?
    let savedTakeCount: Int
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerLayout

            let snippet = PresentationStore.displaySnippet(for: section.text)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(isAccessibilitySize ? 4 : 2)
            }

            if let handoff, !handoff.isFirstSection, let cue = handoff.effectiveCueText {
                handoffPreview(cue: cue, context: handoff)
            }

            if let exactPhrase = section.exactPhrase,
               !exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Exact phrase marked", systemImage: "quote.opening")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }

            if savedTakeCount > 0 {
                Label(
                    savedTakeCount == 1 ? "1 saved take" : "\(savedTakeCount) saved takes",
                    systemImage: "waveform"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens section editor, handoff preparation, and offline practice.")
    }

    @ViewBuilder
    private var headerLayout: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(index + 1). \(section.title)")
                    .font(.headline)
                metadataLabels
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1). \(section.title)")
                        .font(.headline)
                    Spacer()
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Label(speakerSummary, systemImage: section.speakerRole.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var speakerSummary: String {
        let trimmedSpeaker = section.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSpeaker.isEmpty ||
            trimmedSpeaker.caseInsensitiveCompare(section.speakerRole.displayName) == .orderedSame {
            return section.speakerRole.displayName
        }
        return "\(trimmedSpeaker) · \(section.speakerRole.displayName)"
    }

    private var metadataLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(speakerSummary, systemImage: section.speakerRole.symbolName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handoffPreview(cue: String, context: HandoffContext) -> some View {
        let prefix: String
        if context.isSpeakerChange, let speaker = context.precedingSpeaker {
            prefix = "Handoff from \(speaker): "
        } else {
            prefix = "Previous line: "
        }
        return Text("\(prefix)“\(cue)”")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(isAccessibilitySize ? 3 : 1)
    }
}

struct PresentationRecentTakesSection: View {
    let attempts: [AttemptRecord]
    let currentSectionRevisionIDs: Set<UUID>
    let isAccessibilitySize: Bool
    let onOpenReview: (UUID) -> Void

    var body: some View {
        Section {
            ForEach(attempts.prefix(5), id: \.id) { attempt in
                Button {
                    onOpenReview(attempt.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attempt.sectionTitleSnapshot)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        PracticeHistoryRow(
                            attempt: attempt,
                            isCurrentSectionRevision: currentSectionRevisionIDs.contains(attempt.sectionRevisionID),
                            isAccessibilitySize: isAccessibilitySize
                        )
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("recentTakeRow_\(attempt.id.uuidString)")
            }
        } header: {
            Text("Recent Takes")
        } footer: {
            Text("Tap any saved take to replay, inspect recorded facts, or retry that exact revision.")
        }
    }
}
