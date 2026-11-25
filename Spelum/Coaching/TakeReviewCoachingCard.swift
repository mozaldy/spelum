import SwiftUI

struct TakeReviewCoachingCard: View {
    let coordinator: PostTakeCoachCoordinator
    let observations: [TimingObservation]
    let isAudioLoaded: Bool
    let isAccessibilitySize: Bool
    let onSeekObservation: (TimingObservation) -> Void
    let onRequestOnDevice: () -> Void

    @State private var showingEditSheet = false
    @State private var actionErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if let actionErrorMessage {
                Label(actionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Generating on-device review cue…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("reviewCoachGeneratingIndicator")
            } else if let cue = coordinator.currentCue {
                if cue.isDismissed {
                    dismissedView
                } else {
                    activeCueContent(cue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("takeReviewCoachingCard")
        .sheet(isPresented: $showingEditSheet) {
            if let cue = coordinator.currentCue {
                CoachingEditCueSheet(
                    title: "Edit Post-Take Cue",
                    originalAction: cue.action,
                    initialText: cue.displayedAction,
                    onSave: { newText in
                        saveEditedCue(newText)
                    }
                )
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Post-Take Coach (Optional)", systemImage: "sparkles.rectangle.stack")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Grounded in this take’s facts and validated observations. Listen back to decide what fits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dismissedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Post-take cue dismissed for this take.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reviewCoachDismissedLabel")

            Button {
                restoreCue()
            } label: {
                Label("Restore Cue", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("restoreReviewCueButton")
        }
    }

    private func activeCueContent(_ cue: CoachingSuggestion) -> some View {
        let linkedObservation = cue.observationID.flatMap { obsID in
            observations.first { $0.id == obsID }
        }

        return VStack(alignment: .leading, spacing: 10) {
            CoachingOriginBadgesView(cue: cue, isAccessibilitySize: isAccessibilitySize)

            if let techniqueTitle = cue.techniqueTitle {
                Text(techniqueTitle)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reviewCoachTechniqueTitle")
            }

            if let phrase = cue.exactPhrase, !phrase.isEmpty {
                CoachingQuotedPassageBox(phrase: phrase, fromHandoff: cue.exactPhraseFromHandoff)
            }

            Text(cue.displayedAction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reviewCoachActionText")

            Text(cue.rationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let linkedObservation {
                linkedObservationButton(linkedObservation)
            }

            if let note = coordinator.statusNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reviewCoachStatusNote")
            }

            CoachingProvenanceDisclosure(cue: cue)

            Divider()
            actionButtons(for: cue)
        }
    }

    private func linkedObservationButton(_ observation: TimingObservation) -> some View {
        let clock = RehearsalTimeFormatter.clockString(for: observation.startTime)
        return Button {
            onSeekObservation(observation)
        } label: {
            Label("Hear Referenced Moment (\(clock))", systemImage: "play.circle")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isAudioLoaded)
        .accessibilityLabel(
            "Hear referenced moment at \(RehearsalTimeFormatter.accessibleDurationString(for: observation.startTime))"
        )
        .accessibilityHint("Seeks playback with a short lead-in to this validated observation.")
        .accessibilityIdentifier("reviewCoachSeekObservationButton")
    }

    @ViewBuilder
    private func actionButtons(for cue: CoachingSuggestion) -> some View {
        let onDeviceAvailable = coordinator.modelAvailability.isAvailable

        VStack(alignment: .leading, spacing: 8) {
            if isAccessibilitySize {
                VStack(spacing: 8) {
                    editButton
                    dismissButton
                }
            } else {
                HStack(spacing: 10) {
                    editButton
                    dismissButton
                }
            }

            if cue.origin == .onDeviceModel || cue.isUserEdited {
                Button {
                    resetToAuthored()
                } label: {
                    Label("Use Authored Cue", systemImage: "book.closed")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("resetReviewCueToAuthoredButton")
            }

            Button {
                onRequestOnDevice()
            } label: {
                Label(
                    onDeviceAvailable ? "Try On-Device Coach" : "Try On-Device Coach (Unavailable)",
                    systemImage: "cpu"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Try Apple On-Device Coach for This Take")
            .accessibilityHint(
                onDeviceAvailable
                    ? "Generates a grounded post-take suggestion using Apple’s on-device Foundation Model."
                    : coordinator.modelAvailability.shortStatusLabel
            )
            .accessibilityIdentifier("tryOnDeviceReviewCoachButton")

            if !onDeviceAvailable {
                Text(coordinator.modelAvailability.shortStatusLabel + " — authored default stays active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reviewCoachModelAvailabilityNote")
            }
        }
    }

    private var editButton: some View {
        Button {
            showingEditSheet = true
        } label: {
            Label("Edit Cue", systemImage: "pencil")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("editReviewCueButton")
    }

    private var dismissButton: some View {
        Button {
            dismissCue()
        } label: {
            Label("Dismiss", systemImage: "eye.slash")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("dismissReviewCueButton")
    }

    private func saveEditedCue(_ text: String) {
        actionErrorMessage = nil
        do {
            try coordinator.saveEditedAction(text)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func dismissCue() {
        actionErrorMessage = nil
        do {
            try coordinator.dismissCurrentCue()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func restoreCue() {
        actionErrorMessage = nil
        do {
            try coordinator.restoreDismissedCue()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func resetToAuthored() {
        actionErrorMessage = nil
        do {
            try coordinator.resetToAuthoredCue()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}
