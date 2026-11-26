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

struct PresentationRehearsalSection: View {
    let sectionCount: Int
    let handoffStartSection: SectionRevisionRecord?
    let attemptCount: Int
    let onStartFullRun: (FullRunStartKind, UUID?) -> Void
    let onOpenHistory: () -> Void

    var body: some View {
        Section {
            Button {
                onStartFullRun(.entireTalk, nil)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Run Rehearsal")
                            .font(.headline)
                        Text(
                            sectionCount == 1
                                ? "One continuous recording for this section."
                                : "One continuous recording across all \(sectionCount) sections."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "play.circle.fill")
                }
            }
            .disabled(sectionCount == 0)
            .accessibilityIdentifier("startFullRunButton")
            .accessibilityHint("Starts a continuous offline full run of the talk.")

            if let handoffStartSection {
                Button {
                    onStartFullRun(.fromHandoff, handoffStartSection.sectionID)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start from Presenter Handoff")
                                .font(.subheadline.weight(.semibold))
                            Text("Begins at \(handoffStartSection.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.turn.up.right.circle")
                    }
                }
                .accessibilityIdentifier("startFromHandoffButton")
                .accessibilityHint("Starts a continuous full run from your presenter handoff section.")
            }

            Button {
                onOpenHistory()
            } label: {
                HStack {
                    Label("Attempt History & Compare", systemImage: "chart.line.uptrend.xyaxis")
                    Spacer()
                    if attemptCount > 0 {
                        Text("\(attemptCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("openAttemptHistoryButton")
            .accessibilityHint("Review past full runs and section takes chronologically and compare two recordings.")
        } header: {
            Text("Rehearsal & Progress")
        } footer: {
            Text("Full runs snapshot section order and speakers at start so later edits never alter saved recordings.")
        }
    }
}

struct PresentationRecentTakesSection: View {
    let attempts: [AttemptRecord]
    let currentTalkRevisionID: UUID?
    let currentSectionRevisionIDs: Set<UUID>
    let isAccessibilitySize: Bool
    let onOpenReview: (UUID) -> Void
    let onOpenHistory: () -> Void

    init(
        attempts: [AttemptRecord],
        currentTalkRevisionID: UUID? = nil,
        currentSectionRevisionIDs: Set<UUID>,
        isAccessibilitySize: Bool,
        onOpenReview: @escaping (UUID) -> Void,
        onOpenHistory: @escaping () -> Void = {}
    ) {
        self.attempts = attempts
        self.currentTalkRevisionID = currentTalkRevisionID
        self.currentSectionRevisionIDs = currentSectionRevisionIDs
        self.isAccessibilitySize = isAccessibilitySize
        self.onOpenReview = onOpenReview
        self.onOpenHistory = onOpenHistory
    }

    var body: some View {
        Section {
            ForEach(attempts.prefix(5), id: \.id) { attempt in
                let isOlder = ComparableAttemptDescriptor(record: attempt).isOlderRevision(
                    currentTalkRevisionID: currentTalkRevisionID,
                    currentSectionRevisionIDs: currentSectionRevisionIDs
                )
                Button {
                    onOpenReview(attempt.id)
                } label: {
                    AttemptHistoryRowContent(
                        attempt: attempt,
                        isOlderRevision: isOlder,
                        isAccessibilitySize: isAccessibilitySize
                    )
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("recentTakeRow_\(attempt.id.uuidString)")
            }

            Button {
                onOpenHistory()
            } label: {
                Label(
                    attempts.count > 1 ? "View All History & Compare" : "View Attempt History",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .accessibilityIdentifier("viewAllHistoryButton")
        } header: {
            Text("Recent Rehearsals")
        } footer: {
            Text("Tap any saved full run or section take to replay, inspect recorded facts, or compare progress.")
        }
    }
}

struct PresentationLibraryRow: View {
    let presentation: PresentationRecord
    let sectionCount: Int
    let revisionNumber: Int
    let speakerCount: Int
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title)
                .font(.headline)

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sectionsLabel)
                    Text(speakersLabel)
                    Text("Revision \(revisionNumber)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text("\(sectionsLabel) · \(speakersLabel) · Rev \(revisionNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Updated \(presentation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens ordered sections and handoff preparation.")
    }

    private var sectionsLabel: String {
        sectionCount == 1 ? "1 section" : "\(sectionCount) sections"
    }

    private var speakersLabel: String {
        speakerCount <= 1 ? "1 speaker" : "\(speakerCount) speakers"
    }
}
