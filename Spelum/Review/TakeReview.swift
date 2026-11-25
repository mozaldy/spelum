import SwiftData
import SwiftUI

struct TakeReview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let attemptID: UUID
    let onRetry: (PracticeTarget) -> Void

    @State private var player = TakeAudioPlayer()
    @State private var showingDeleteConfirm = false
    @State private var deleteErrorMessage: String?

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
        .onAppear { loadAudioIfAvailable() }
        .onDisappear { player.stop() }
    }

    private func reviewContent(for attempt: AttemptRecord) -> some View {
        let presentation = try? presentationStore.presentation(withID: attempt.presentationID)
        let talkRevision = try? presentationStore.talkRevision(withID: attempt.talkRevisionID)
        let sectionRevision = try? presentationStore.sectionRevision(withID: attempt.sectionRevisionID)
        let handoff = talkRevision.flatMap {
            presentationStore.handoffContext(forSectionID: attempt.sectionID, in: $0)
        }
        let isOlderRevision = presentation?.currentRevisionID != nil
            && presentation?.currentRevisionID != attempt.talkRevisionID

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let deleteErrorMessage {
                    Label(deleteErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                TakeReviewHeaderCard(
                    attempt: attempt,
                    presentationTitle: presentation?.title,
                    sectionTitle: sectionRevision?.title ?? attempt.sectionTitleSnapshot,
                    isOlderRevision: isOlderRevision,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )

                TakeReviewPlaybackCard(
                    attempt: attempt,
                    player: player,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )

                TakeReviewFactsAndMarkers(
                    attempt: attempt,
                    isAudioLoaded: player.isLoaded,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    onSeekMarker: { timestamp in
                        player.seek(to: timestamp, autoPlay: true)
                    }
                )

                if let handoff {
                    PracticeHandoffCueCard(handoff: handoff)
                }

                if let sectionRevision {
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

    private func retryActionButton(for attempt: AttemptRecord) -> some View {
        Button {
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

    private func loadAudioIfAvailable() {
        guard let attempt,
              attempt.hasPlayableAudio,
              let url = attemptStore.resolvedAudioURL(for: attempt) else {
            return
        }
        player.load(url: url)
    }

    private func deleteCurrentAttempt() {
        guard let attempt else { return }
        deleteErrorMessage = nil
        player.stop()
        do {
            try attemptStore.deleteAttempt(attempt)
            dismiss()
        } catch {
            deleteErrorMessage = error.localizedDescription
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
