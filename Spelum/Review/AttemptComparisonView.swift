import SwiftData
import SwiftUI

struct AttemptComparisonView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let presentation: PresentationRecord
    let initialFirstID: UUID?
    let initialSecondID: UUID?
    let onOpenReview: (UUID) -> Void

    @Query(sort: \AttemptRecord.startedAt, order: .reverse)
    private var allAttempts: [AttemptRecord]

    @State private var firstAttemptID: UUID?
    @State private var secondAttemptID: UUID?
    @State private var activePlaybackAttemptID: UUID?
    @State private var player = TakeAudioPlayer()
    @State private var attemptPendingDelete: AttemptRecord?
    @State private var actionErrorMessage: String?

    private var presentationStore: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var attemptStore: AttemptStore {
        AttemptStore(modelContext: modelContext)
    }

    private var finalizedAttempts: [AttemptRecord] {
        allAttempts.filter { $0.presentationID == presentation.id && $0.status.isFinalized }
    }

    private var currentSectionRevisionIDs: Set<UUID> {
        Set(presentationStore.orderedSections(for: presentation).map(\.revisionID))
    }

    private var firstAttempt: AttemptRecord? {
        guard let firstAttemptID else { return nil }
        return finalizedAttempts.first { $0.id == firstAttemptID }
    }

    private var secondAttempt: AttemptRecord? {
        guard let secondAttemptID else { return nil }
        return finalizedAttempts.first { $0.id == secondAttemptID }
    }

    private var comparisonSummary: AttemptComparisonSummary? {
        guard let firstAttempt, let secondAttempt, firstAttempt.id != secondAttempt.id else {
            return nil
        }
        return AttemptComparisonEngine.buildSummary(
            first: ComparableAttemptDescriptor(record: firstAttempt),
            second: ComparableAttemptDescriptor(record: secondAttempt),
            currentTalkRevisionID: presentation.currentRevisionID,
            currentSectionRevisionIDs: currentSectionRevisionIDs
        )
    }

    var body: some View {
        Group {
            if finalizedAttempts.count < 2 {
                ContentUnavailableView(
                    "Need Two Saved Attempts",
                    systemImage: "arrow.left.arrow.right",
                    description: Text(
                        "Record at least two takes or full runs for this presentation to compare them side by side."
                    )
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let actionErrorMessage {
                            Label(actionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                        }

                        selectorCard

                        if let summary = comparisonSummary,
                           let earlierRecord = finalizedAttempts.first(where: { $0.id == summary.earlier.id }),
                           let laterRecord = finalizedAttempts.first(where: { $0.id == summary.later.id }) {
                            ComparisonScopeBanner(
                                summary: summary,
                                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                            )

                            ComparisonReplayDeckCard(
                                label: "Earlier",
                                attempt: earlierRecord,
                                descriptor: summary.earlier,
                                isOlderRevision: summary.earlierIsOlderRevision,
                                isActivePlayer: activePlaybackAttemptID == earlierRecord.id,
                                player: player,
                                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                                onTogglePlay: { togglePlayback(for: earlierRecord) },
                                onSeek: { time in seekPlayback(for: earlierRecord, to: time, autoPlay: false) },
                                onOpenReview: { onOpenReview(earlierRecord.id) },
                                onDeleteThis: { attemptPendingDelete = earlierRecord }
                            )

                            ComparisonReplayDeckCard(
                                label: "Later",
                                attempt: laterRecord,
                                descriptor: summary.later,
                                isOlderRevision: summary.laterIsOlderRevision,
                                isActivePlayer: activePlaybackAttemptID == laterRecord.id,
                                player: player,
                                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                                onTogglePlay: { togglePlayback(for: laterRecord) },
                                onSeek: { time in seekPlayback(for: laterRecord, to: time, autoPlay: false) },
                                onOpenReview: { onOpenReview(laterRecord.id) },
                                onDeleteThis: { attemptPendingDelete = laterRecord }
                            )

                            ComparisonMetricsCard(
                                summary: summary,
                                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                            )

                            if !summary.fullRunSectionRows.isEmpty {
                                ComparisonFullRunSectionsCard(
                                    rows: summary.fullRunSectionRows,
                                    earlierHasAudio: earlierRecord.hasPlayableAudio,
                                    laterHasAudio: laterRecord.hasPlayableAudio,
                                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                                    onPlayEarlierAt: { time in
                                        seekPlayback(for: earlierRecord, to: time, autoPlay: true)
                                    },
                                    onPlayLaterAt: { time in
                                        seekPlayback(for: laterRecord, to: time, autoPlay: true)
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Compare Attempts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            initializeSelectionIfNeeded()
        }
        .onChange(of: finalizedAttempts.map(\.id)) { _, _ in
            reconcileSelectionAfterListChange()
        }
        .onDisappear {
            player.stop()
            activePlaybackAttemptID = nil
        }
        .confirmationDialog(
            "Delete this attempt and keep the other?",
            isPresented: Binding(
                get: { attemptPendingDelete != nil },
                set: { if !$0 { attemptPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Selected Attempt", role: .destructive) {
                if let target = attemptPendingDelete {
                    attemptPendingDelete = nil
                    deleteComparedAttempt(target)
                }
            }
            Button("Cancel", role: .cancel) { attemptPendingDelete = nil }
        } message: {
            Text(
                "Only this recording will be deleted from your device. " +
                "The delivery you choose to keep remains intact."
            )
        }
    }

    private var selectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Selected Pair", systemImage: "arrow.left.arrow.right")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            attemptPickerRow(
                title: "Attempt A",
                selectedID: firstAttemptID,
                excludingID: secondAttemptID,
                identifier: "compareAttemptAPicker"
            ) { newID in
                stopPlaybackIfNeeded()
                firstAttemptID = newID
            }

            attemptPickerRow(
                title: "Attempt B",
                selectedID: secondAttemptID,
                excludingID: firstAttemptID,
                identifier: "compareAttemptBPicker"
            ) { newID in
                stopPlaybackIfNeeded()
                secondAttemptID = newID
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("comparisonSelectorCard")
    }

    private func attemptPickerRow(
        title: String,
        selectedID: UUID?,
        excludingID: UUID?,
        identifier: String,
        onSelect: @escaping (UUID) -> Void
    ) -> some View {
        let selectedRecord = selectedID.flatMap { id in finalizedAttempts.first { $0.id == id } }
        let options = finalizedAttempts.filter { $0.id != excludingID }
        return Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    Text(optionMenuLabel(for: option))
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedRecord.map(optionMenuLabel(for:)) ?? "Select attempt")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(title)
        .accessibilityValue(selectedRecord.map(optionMenuLabel(for:)) ?? "None selected")
        .accessibilityIdentifier(identifier)
    }

    private func optionMenuLabel(for attempt: AttemptRecord) -> String {
        let kind = attempt.isFullRun ? "Full Run" : "Section"
        let duration = RehearsalTimeFormatter.shortDurationString(for: attempt.displayDuration)
        let date = attempt.startedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(kind): \(attempt.displayTitle) · Rev \(attempt.talkRevisionNumber) · \(duration) · \(date)"
    }
}

private extension AttemptComparisonView {
    func initializeSelectionIfNeeded() {
        guard firstAttemptID == nil || secondAttemptID == nil else {
            reconcileSelectionAfterListChange()
            return
        }
        if let initialFirstID,
           let initialSecondID,
           initialFirstID != initialSecondID,
           finalizedAttempts.contains(where: { $0.id == initialFirstID }),
           finalizedAttempts.contains(where: { $0.id == initialSecondID }) {
            firstAttemptID = initialFirstID
            secondAttemptID = initialSecondID
            return
        }

        let descriptors = finalizedAttempts.map(ComparableAttemptDescriptor.init(record:))
        if let defaultPair = AttemptComparisonEngine.defaultComparablePair(
            from: descriptors,
            filter: .all,
            anchorAttemptID: initialFirstID,
            currentTalkRevisionID: presentation.currentRevisionID,
            currentSectionRevisionIDs: currentSectionRevisionIDs
        ) {
            firstAttemptID = defaultPair.earlierID
            secondAttemptID = defaultPair.laterID
            return
        }

        if let anchorID = initialFirstID,
           finalizedAttempts.contains(where: { $0.id == anchorID }),
           let fallbackSecond = finalizedAttempts.first(where: { $0.id != anchorID }) {
            firstAttemptID = anchorID
            secondAttemptID = fallbackSecond.id
            return
        }

        if finalizedAttempts.count >= 2 {
            firstAttemptID = finalizedAttempts[1].id
            secondAttemptID = finalizedAttempts[0].id
        }
    }

    func reconcileSelectionAfterListChange() {
        let validIDs = Set(finalizedAttempts.map(\.id))
        if let first = firstAttemptID, !validIDs.contains(first) {
            firstAttemptID = nil
        }
        if let second = secondAttemptID, !validIDs.contains(second) {
            secondAttemptID = nil
        }
        if firstAttemptID == nil || secondAttemptID == nil || firstAttemptID == secondAttemptID {
            let remainingAnchor = firstAttemptID ?? secondAttemptID
            let descriptors = finalizedAttempts.map(ComparableAttemptDescriptor.init(record:))
            if let pair = AttemptComparisonEngine.defaultComparablePair(
                from: descriptors,
                filter: .all,
                anchorAttemptID: remainingAnchor,
                currentTalkRevisionID: presentation.currentRevisionID,
                currentSectionRevisionIDs: currentSectionRevisionIDs
            ) {
                firstAttemptID = pair.earlierID
                secondAttemptID = pair.laterID
            } else if let remainingAnchor,
                      let fallbackPartner = finalizedAttempts.first(where: { $0.id != remainingAnchor }) {
                firstAttemptID = remainingAnchor
                secondAttemptID = fallbackPartner.id
            } else if finalizedAttempts.count >= 2 {
                firstAttemptID = finalizedAttempts[1].id
                secondAttemptID = finalizedAttempts[0].id
            }
        }
    }

    func togglePlayback(for attempt: AttemptRecord) {
        guard attempt.hasPlayableAudio, let url = attemptStore.resolvedAudioURL(for: attempt) else {
            return
        }
        if activePlaybackAttemptID == attempt.id && player.isLoaded {
            player.togglePlayPause()
            return
        }
        player.stop()
        activePlaybackAttemptID = attempt.id
        player.load(url: url)
        player.play()
    }

    func seekPlayback(for attempt: AttemptRecord, to time: TimeInterval, autoPlay: Bool) {
        guard attempt.hasPlayableAudio, let url = attemptStore.resolvedAudioURL(for: attempt) else {
            return
        }
        if activePlaybackAttemptID != attempt.id || !player.isLoaded {
            player.stop()
            activePlaybackAttemptID = attempt.id
            player.load(url: url)
        }
        player.seek(to: time, autoPlay: autoPlay)
    }

    func stopPlaybackIfNeeded() {
        player.stop()
        activePlaybackAttemptID = nil
    }

    func deleteComparedAttempt(_ target: AttemptRecord) {
        actionErrorMessage = nil
        if activePlaybackAttemptID == target.id {
            stopPlaybackIfNeeded()
        }
        do {
            try attemptStore.deleteAttempt(target)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}
