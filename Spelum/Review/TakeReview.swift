import SwiftData
import SwiftUI

struct TakeReview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let attemptID: UUID
    let onRetry: (PracticeTarget) -> Void

    @State private var player = TakeAudioPlayer()
    @State private var analysisCoordinator: TakeAnalysisCoordinator
    @State private var showingDeleteConfirm = false
    @State private var actionErrorMessage: String?

    init(
        attemptID: UUID,
        transcriber: (any TakeTranscribing)? = nil,
        onRetry: @escaping (PracticeTarget) -> Void
    ) {
        self.attemptID = attemptID
        self.onRetry = onRetry
        self._analysisCoordinator = State(
            initialValue: TakeAnalysisCoordinator(transcriber: transcriber)
        )
    }

    private var presentationStore: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var attemptStore: AttemptStore {
        AttemptStore(modelContext: modelContext)
    }

    private var attempt: AttemptRecord? {
        try? attemptStore.attempt(withID: attemptID)
    }

    var body: some View {
        Group {
            if let attempt {
                reviewContent(for: attempt)
            } else {
                ContentUnavailableView(
                    "Take Not Found",
                    systemImage: "waveform.slash",
                    description: Text("This rehearsal take may have been deleted.")
                )
            }
        }
        .navigationTitle("Take Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if attempt != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete Take", systemImage: "trash")
                    }
                    .accessibilityLabel("Delete Take")
                    .accessibilityIdentifier("deleteTakeToolbarButton")
                }
            }
        }
        .confirmationDialog(
            "Delete this rehearsal take?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Take", role: .destructive) {
                deleteCurrentAttempt()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only this take and its local audio recording from this device.")
        }
        .onAppear {
            loadAudioIfAvailable()
            startOrLoadAnalysisIfAvailable()
        }
        .onDisappear {
            analysisCoordinator.handleViewDisappear()
            player.stop()
        }
    }

    private func reviewContent(for attempt: AttemptRecord) -> some View {
        let context = resolvedReviewDisplay(for: attempt)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let actionErrorMessage {
                    errorBanner(actionErrorMessage)
                }

                TakeReviewHeaderCard(
                    attempt: attempt,
                    presentationTitle: context.presentationTitle,
                    sectionTitle: context.sectionRevision?.title ?? attempt.sectionTitleSnapshot,
                    isOlderRevision: context.isOlderRevision,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )

                TakeReviewPlaybackCard(
                    attempt: attempt,
                    player: player,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )

                analysisCard(for: context.analysisContext, totalDuration: context.totalDuration)

                TakeReviewFactsAndMarkers(
                    attempt: attempt,
                    isAudioLoaded: player.isLoaded,
                    currentPlaybackTime: player.currentTime,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    onSeekMarker: { timestamp in player.seek(to: timestamp, autoPlay: true) },
                    onAddMarkerAtCurrentTime: { addManualMarker(label: nil) }
                )

                if let handoff = context.handoff {
                    PracticeHandoffCueCard(handoff: handoff)
                }

                if let sectionRevision = context.sectionRevision {
                    TakeReviewScriptCard(
                        section: sectionRevision,
                        revisionNumber: attempt.talkRevisionNumber
                    )
                }

                retryActionButton(for: attempt)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    static func performDeletion(
        attempt: AttemptRecord,
        attemptStore: AttemptStore,
        player: TakeAudioPlayer
    ) throws {
        player.pause()
        do {
            try attemptStore.deleteAttempt(attempt)
            player.stop()
        } catch {
            if !player.isLoaded,
               attempt.hasPlayableAudio,
               let url = attemptStore.resolvedAudioURL(for: attempt) {
                player.load(url: url)
            }
            throw error
        }
    }
}

private extension TakeReview {
    struct ReviewDisplayContext {
        let presentationTitle: String?
        let sectionRevision: SectionRevisionRecord?
        let handoff: HandoffContext?
        let isOlderRevision: Bool
        let totalDuration: TimeInterval
        let analysisContext: TakeAnalysisRequestContext
    }

    func resolvedReviewDisplay(for attempt: AttemptRecord) -> ReviewDisplayContext {
        let presentation = try? presentationStore.presentation(withID: attempt.presentationID)
        let talkRevision = try? presentationStore.talkRevision(withID: attempt.talkRevisionID)
        let sectionRevision = try? presentationStore.sectionRevision(withID: attempt.sectionRevisionID)
        let handoff = talkRevision.flatMap {
            presentationStore.handoffContext(forSectionID: attempt.sectionID, in: $0)
        }
        let isOlderRevision = presentation?.currentRevisionID != nil
            && presentation?.currentRevisionID != attempt.talkRevisionID
        let totalDuration = max(player.duration, attempt.playableDuration)
        let analysisContext = makeAnalysisContext(
            for: attempt,
            section: sectionRevision,
            handoff: handoff
        )
        return ReviewDisplayContext(
            presentationTitle: presentation?.title,
            sectionRevision: sectionRevision,
            handoff: handoff,
            isOlderRevision: isOlderRevision,
            totalDuration: totalDuration,
            analysisContext: analysisContext
        )
    }

    func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    func analysisCard(
        for analysisContext: TakeAnalysisRequestContext,
        totalDuration: TimeInterval
    ) -> some View {
        TakeReviewAnalysisCard(
            phase: analysisCoordinator.phase,
            isAudioLoaded: player.isLoaded,
            currentPlaybackTime: player.currentTime,
            totalDuration: totalDuration,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            onSeekObservation: { observation in
                let target = observation.seekTarget(maxDuration: totalDuration)
                player.seek(to: target, autoPlay: true)
            },
            onAddManualMarker: { suggestedLabel in
                addManualMarker(label: suggestedLabel)
            },
            onInstallAssets: { localeID in
                analysisCoordinator.installAssetsAndAnalyze(
                    localeIdentifier: localeID,
                    context: analysisContext,
                    attemptStore: attemptStore
                )
            },
            onReanalyze: {
                analysisCoordinator.reanalyze(
                    context: analysisContext,
                    attemptStore: attemptStore
                )
            },
            onDecline: {
                analysisCoordinator.decline(
                    context: analysisContext,
                    attemptStore: attemptStore
                )
            },
            onCancel: {
                analysisCoordinator.cancelActiveOperation()
            }
        )
    }

    func retryActionButton(for attempt: AttemptRecord) -> some View {
        Button {
            analysisCoordinator.handleViewDisappear()
            player.stop()
            let target = PracticeTarget(
                presentationID: attempt.presentationID,
                sectionID: attempt.sectionID,
                talkRevisionID: attempt.talkRevisionID,
                sectionRevisionID: attempt.sectionRevisionID,
                initialMode: attempt.practiceMode,
                hasUnsavedEditorDraft: false,
                retryToken: UUID()
            )
            onRetry(target)
        } label: {
            Label("Retry Section (\(attempt.practiceMode.displayName))", systemImage: "arrow.counterclockwise")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Retry Section in \(attempt.practiceMode.displayName) mode")
        .accessibilityHint("Starts a fresh rehearsal attempt on the same section revision and practice mode.")
        .accessibilityIdentifier("retrySectionFromReviewButton")
    }

    func loadAudioIfAvailable() {
        guard let attempt,
              attempt.hasPlayableAudio,
              let url = attemptStore.resolvedAudioURL(for: attempt) else {
            return
        }
        player.load(url: url)
    }

    func startOrLoadAnalysisIfAvailable() {
        guard let attempt else { return }
        let display = resolvedReviewDisplay(for: attempt)
        analysisCoordinator.loadOrAnalyzeIfReady(context: display.analysisContext, attemptStore: attemptStore)
    }

    func makeAnalysisContext(
        for attempt: AttemptRecord,
        section: SectionRevisionRecord?,
        handoff: HandoffContext?
    ) -> TakeAnalysisRequestContext {
        let isMultiSpeakerOrHandoff = (handoff?.isSpeakerChange == true)
            || (handoff?.isSingleSpeakerTalk == false)
        return TakeAnalysisRequestContext(
            attemptID: attempt.id,
            talkRevisionID: attempt.talkRevisionID,
            sectionRevisionID: attempt.sectionRevisionID,
            relativeAudioPath: attempt.relativeAudioPath,
            audioURL: attemptStore.resolvedAudioURL(for: attempt),
            elapsedAudioDuration: attempt.playableDuration > 0 ? attempt.playableDuration : player.duration,
            hasPlayableAudio: attempt.hasPlayableAudio,
            isSilentRecall: attempt.isSilentRecall,
            scriptText: section?.text ?? "",
            exactPhrase: section?.exactPhrase,
            cueWords: section?.cueWords ?? [],
            hasMultipleSpeakersOrHandoff: isMultiSpeakerOrHandoff
        )
    }

    func addManualMarker(label: String?) {
        actionErrorMessage = nil
        do {
            _ = try attemptStore.addManualMarker(
                toAttemptID: attemptID,
                timestamp: player.currentTime,
                label: label
            )
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func deleteCurrentAttempt() {
        guard let attempt else { return }
        actionErrorMessage = nil
        analysisCoordinator.invalidateForDeletion()
        do {
            try Self.performDeletion(
                attempt: attempt,
                attemptStore: attemptStore,
                player: player
            )
            dismiss()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}

struct TakeReviewScriptCard: View {
    let section: SectionRevisionRecord
    let revisionNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Snapshotted Script (Revision \(revisionNumber))", systemImage: "doc.text")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let exactPhrase = section.exactPhrase,
               !exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Exact Phrase", systemImage: "quote.opening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(exactPhrase)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }

            Text(section.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reviewSnapshottedScriptText")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
