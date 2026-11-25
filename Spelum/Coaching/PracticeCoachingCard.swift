import SwiftUI

struct PracticeCoachingCard: View {
    let coordinator: PreparationCoachCoordinator
    let isActiveTake: Bool
    let isAccessibilitySize: Bool

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
                    Text("Generating on-device pre-practice cue…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("practiceCoachGeneratingIndicator")
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
        .accessibilityIdentifier("practiceCoachingCard")
        .sheet(isPresented: $showingEditSheet) {
            if let cue = coordinator.currentCue {
                CoachingEditCueSheet(
                    title: "Edit Pre-Practice Cue",
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
            Label("Pre-Practice Coach (Optional)", systemImage: "lightbulb")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("One editorial delivery experiment before you record. Keep, edit, or dismiss anytime.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dismissedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pre-practice cue dismissed for this section revision.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("practiceCoachDismissedLabel")

            Button {
                restoreCue()
            } label: {
                Label("Restore Cue", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isActiveTake)
            .accessibilityIdentifier("restorePracticeCueButton")
        }
    }

    private func activeCueContent(_ cue: CoachingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CoachingOriginBadgesView(cue: cue, isAccessibilitySize: isAccessibilitySize)

            if let techniqueTitle = cue.techniqueTitle {
                Text(techniqueTitle)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("practiceCoachTechniqueTitle")
            }

            if let phrase = cue.exactPhrase, !phrase.isEmpty {
                CoachingQuotedPassageBox(phrase: phrase, fromHandoff: cue.exactPhraseFromHandoff)
            }

            Text(cue.displayedAction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("practiceCoachActionText")

            Text(cue.rationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = coordinator.statusNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("practiceCoachStatusNote")
            }

            CoachingProvenanceDisclosure(cue: cue)

            if !isActiveTake {
                Divider()
                techniquePickerMenu
                actionButtons(for: cue)
            }
        }
    }

    @ViewBuilder
    private var techniquePickerMenu: some View {
        if let candidates = coordinator.activeRequest?.candidateTechniques, candidates.count > 1 {
            Menu {
                Button {
                    coordinator.selectTechnique(id: nil)
                } label: {
                    if coordinator.activeRequest?.selectedTechniqueID == nil {
                        Label("Recommended for Section", systemImage: "checkmark")
                    } else {
                        Text("Recommended for Section")
                    }
                }
                Divider()
                ForEach(candidates) { technique in
                    Button {
                        coordinator.selectTechnique(id: technique.id)
                    } label: {
                        if coordinator.activeRequest?.selectedTechniqueID == technique.id {
                            Label(technique.title, systemImage: "checkmark")
                        } else {
                            Text(technique.title)
                        }
                    }
                }
            } label: {
                Label("Choose Technique", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Choose Pre-Practice Technique")
            .accessibilityHint("Selects a delivery technique from the 2007 keynote library.")
            .accessibilityIdentifier("choosePracticeTechniqueMenu")
        }
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
                .accessibilityIdentifier("resetPracticeCueToAuthoredButton")
            }

            Button {
                coordinator.requestOnDeviceSuggestion()
            } label: {
                Label(
                    onDeviceAvailable ? "Try On-Device Coach" : "Try On-Device Coach (Unavailable)",
                    systemImage: "cpu"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Try Apple On-Device Coach")
            .accessibilityHint(
                onDeviceAvailable
                    ? "Generates a grounded suggestion using Apple’s on-device Foundation Model."
                    : coordinator.modelAvailability.shortStatusLabel
            )
            .accessibilityIdentifier("tryOnDevicePracticeCoachButton")

            if !onDeviceAvailable {
                Text(coordinator.modelAvailability.shortStatusLabel + " — authored default stays active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("practiceCoachModelAvailabilityNote")
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
        .accessibilityIdentifier("editPracticeCueButton")
    }

    private var dismissButton: some View {
        Button {
            dismissCue()
        } label: {
            Label("Dismiss", systemImage: "eye.slash")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("dismissPracticeCueButton")
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
