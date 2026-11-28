import SwiftUI

struct FullRunReviewHeaderCard: View {
    let attempt: AttemptRecord
    let payload: FullRunAttemptPayload
    let presentationTitle: String?
    let isOlderRevision: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.snapshot.scopeTitle)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    statusBadge
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(payload.snapshot.scopeTitle)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    statusBadge
                }
            }

            let resolvedTitle = presentationTitle ?? payload.snapshot.presentationTitle
            Text("\(resolvedTitle) · Revision \(attempt.talkRevisionNumber)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(
                payload.progressSummary(status: attempt.status),
                systemImage: "list.number"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(payload.finishedEarly ? .orange : .secondary)
            .accessibilityIdentifier("fullRunCompletionBadge")

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
        .accessibilityIdentifier("fullRunReviewHeaderCard")
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

struct FullRunReviewTimelineCard: View {
    let payload: FullRunAttemptPayload
    let isAudioLoaded: Bool
    let currentPlaybackTime: TimeInterval
    let isAccessibilitySize: Bool
    let onSeekTransition: (FullRunSectionTransition) -> Void

    private var activeTransitionID: UUID? {
        guard isAudioLoaded else { return nil }
        return payload.activeTransition(at: currentPlaybackTime)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Section Timeline (\(payload.transitions.count) of \(payload.totalPlannedSections))",
                systemImage: "timeline.selection"
            )
            .font(.headline)
            .accessibilityAddTraits(.isHeader)

            Text(
                isAudioLoaded
                    ? "Tap any section to jump directly to its measured start time in the recording."
                    : "Measured section timestamps recorded in this run."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(payload.transitions) { transition in
                let isActive = transition.id == activeTransitionID
                Button {
                    if isAudioLoaded {
                        onSeekTransition(transition)
                    }
                } label: {
                    transitionRow(transition: transition, isActive: isActive)
                }
                .buttonStyle(.plain)
                .disabled(!isAudioLoaded)
                .accessibilityLabel(accessibleTransitionLabel(transition))
                .accessibilityHint(
                    isAudioLoaded
                        ? "Seeks playback to this section in the full run recording."
                        : "Measured section timestamp."
                )
                .accessibilityIdentifier("fullRunTransition_\(transition.runIndex)")

                if transition.id != payload.transitions.last?.id {
                    Divider()
                }
            }

            if !payload.unreachedSections.isEmpty {
                Divider()
                unreachedSectionList(payload.unreachedSections)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("fullRunReviewTimelineCard")
    }

    private func transitionRow(
        transition: FullRunSectionTransition,
        isActive: Bool
    ) -> some View {
        let startClock = RehearsalTimeFormatter.clockString(for: transition.startTime)
        let durationClock = transition.duration.map { RehearsalTimeFormatter.clockString(for: $0) }
        return VStack(alignment: .leading, spacing: 4) {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(transition.talkSectionIndex + 1). \(transition.sectionTitle)")
                        .font(.body.weight(isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    Text(transition.speakerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(durationClock.map { "Starts \(startClock) · Duration \($0)" } ?? "Starts \(startClock)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(isAudioLoaded ? Color.accentColor : Color.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(transition.talkSectionIndex + 1). \(transition.sectionTitle)")
                            .font(.body.weight(isActive ? .semibold : .medium))
                            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                        HStack(spacing: 8) {
                            Label(transition.speakerSummary, systemImage: transition.speakerRole.symbolName)
                            Label(transition.purpose.displayName, systemImage: transition.purpose.symbolName)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(startClock)
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isAudioLoaded ? Color.accentColor : Color.secondary)
                        if let durationClock {
                            Text(durationClock)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isActive ? 8 : 0)
        .background(
            isActive ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .frame(minHeight: 44, alignment: .leading)
    }

    private func unreachedSectionList(_ sections: [FullRunSectionSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not Reached in This Run")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sections) { section in
                Text("• \(section.talkSectionIndex + 1). \(section.title) (\(section.speaker))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("fullRunUnreachedSectionsList")
    }

    private func accessibleTransitionLabel(_ transition: FullRunSectionTransition) -> String {
        let startSpeech = RehearsalTimeFormatter.accessibleDurationString(for: transition.startTime)
        if let duration = transition.duration {
            let durSpeech = RehearsalTimeFormatter.accessibleDurationString(for: duration)
            return "\(transition.sectionTitle), \(transition.speaker), starts at \(startSpeech), duration \(durSpeech)"
        }
        return "\(transition.sectionTitle), \(transition.speaker), starts at \(startSpeech)"
    }
}

struct FullRunReviewScriptCard: View {
    let snapshot: FullRunSnapshot
    let storageRootURL: URL

    init(
        snapshot: FullRunSnapshot,
        storageRootURL: URL = SlideDeckStorage.defaultStorageRootURL()
    ) {
        self.snapshot = snapshot
        self.storageRootURL = storageRootURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Snapshotted Talk & Speaker Order (Revision \(snapshot.talkRevisionNumber))",
                systemImage: "doc.text"
            )
            .font(.headline)
            .accessibilityAddTraits(.isHeader)

            Text(
                "Preserved from Revision \(snapshot.talkRevisionNumber) at the start of this run. " +
                "Later script edits and reorders do not change this snapshot."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(snapshot.sections) { section in
                let slides = RehearsalSlideResolver.resolveSlides(for: section)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        if slides.contains(where: \.hasSlideArtwork) || slides.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(slides) { slide in
                                        VStack(alignment: .leading, spacing: 4) {
                                            if let pdfURL = slide.resolvedDeckURL(storageRootURL: storageRootURL),
                                               let pageIndex = slide.pdfPageIndex {
                                                SlideThumbnailView(
                                                    pdfURL: pdfURL,
                                                    pageIndex: pageIndex,
                                                    aspectRatio: slide.aspectRatio,
                                                    targetWidth: 104
                                                )
                                            }
                                            Text(slide.slideTitle)
                                                .font(.caption.weight(.medium))
                                                .lineLimit(1)
                                                .frame(maxWidth: 104, alignment: .leading)
                                        }
                                    }
                                }
                            }
                        }
                        if let handoff = section.handoffCueText, !handoff.isEmpty {
                            Text("Handoff cue: “\(handoff)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let exactPhrase = section.exactPhrase, !exactPhrase.isEmpty {
                            Label("Exact Phrase: \(exactPhrase)", systemImage: "quote.opening")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(section.text)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fullRunSnapshotScript_\(section.runIndex)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(section.talkSectionIndex + 1). \(section.title)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(section.speakerSummary) · \(section.purpose.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("fullRunSnapshotDisclosure_\(section.runIndex)")

                if section.id != snapshot.sections.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("fullRunReviewScriptCard")
    }
}
