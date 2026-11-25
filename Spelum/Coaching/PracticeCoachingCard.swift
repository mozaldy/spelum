import SwiftUI

struct PracticeCoachingCard: View {
    let coordinator: PreparationCoachCoordinator
    let practiceMode: PracticeMode
    let isScriptRevealed: Bool
    let sectionExactPhrase: String?
    let handoffCueText: String?
    let isActiveTake: Bool
    let isAccessibilitySize: Bool
    let onRevealScript: () -> Void

    @State private var showingEditSheet = false
    @State private var actionErrorMessage: String?

    private var currentPolicy: PracticeCoachingConcealmentPolicy? {
        guard let cue = coordinator.currentCue, !cue.isDismissed else { return nil }
        return PracticeCoachingConcealmentPolicy.evaluate(
            practiceMode: practiceMode,
            isScriptRevealed: isScriptRevealed,
            sectionExactPhrase: sectionExactPhrase,
            handoffCueText: handoffCueText,
            cue: cue
        )
    }

    private var canPresentEditSheet: Bool {
        !isActiveTake && (currentPolicy?.allowsEditing == true)
    }

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
                } else if let policy = currentPolicy {
                    if policy.showsCueBody {
                        activeCueContent(cue, policy: policy)
                    } else {
                        PracticeCoachingConcealedCueView(
                            isActiveTake: isActiveTake,
                            onRevealScript: onRevealScript
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("practiceCoachingCard")
        .onChange(of: canPresentEditSheet) { _, allowed in
            if !allowed {
                showingEditSheet = false
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            if canPresentEditSheet, let cue = coordinator.currentCue {
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

    private func activeCueContent(
        _ cue: CoachingSuggestion,
        policy: PracticeCoachingConcealmentPolicy
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CoachingOriginBadgesView(cue: cue, isAccessibilitySize: isAccessibilitySize)

            if let techniqueTitle = cue.techniqueTitle {
                Text(techniqueTitle)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("practiceCoachTechniqueTitle")
            }

            if let phrase = cue.exactPhrase, !phrase.isEmpty {
                if policy.showsQuotedPassage {
                    CoachingQuotedPassageBox(phrase: phrase, fromHandoff: cue.exactPhraseFromHandoff)
                } else {
                    PracticeCoachingConcealedPassageBox(
                        isActiveTake: isActiveTake,
                        onRevealScript: onRevealScript
                    )
                }
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

            if policy.showsProvenanceDisclosure {
                CoachingProvenanceDisclosure(cue: cue)
            }

            if !isActiveTake && policy.allowsCustomActions {
                Divider()
                PracticeCoachingActionControls(
                    coordinator: coordinator,
                    cue: cue,
                    allowsEditing: policy.allowsEditing,
                    isAccessibilitySize: isAccessibilitySize,
                    onEdit: { showingEditSheet = true },
                    onDismiss: dismissCue,
                    onResetToAuthored: resetToAuthored
                )
            }
        }
    }

    private func saveEditedCue(_ text: String) {
        actionErrorMessage = nil
        do {
            try coordinator.saveEditedAction(text)
        } catch {
            actionErrorMessage = "Could not save edited cue: \(error.localizedDescription)"
        }
    }

    private func dismissCue() {
        actionErrorMessage = nil
        do {
            try coordinator.dismissCurrentCue()
        } catch {
            actionErrorMessage = "Could not dismiss cue: \(error.localizedDescription)"
        }
    }

    private func restoreCue() {
        actionErrorMessage = nil
        do {
            try coordinator.restoreDismissedCue()
        } catch {
            actionErrorMessage = "Could not restore cue: \(error.localizedDescription)"
        }
    }

    private func resetToAuthored() {
        actionErrorMessage = nil
        do {
            try coordinator.resetToAuthoredCue()
        } catch {
            actionErrorMessage = "Could not restore authored cue: \(error.localizedDescription)"
        }
    }
}

private struct PracticeCoachingActionControls: View {
    let coordinator: PreparationCoachCoordinator
    let cue: CoachingSuggestion
    let allowsEditing: Bool
    let isAccessibilitySize: Bool
    let onEdit: () -> Void
    let onDismiss: () -> Void
    let onResetToAuthored: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            techniquePickerMenu
            editAndDismissRow
            if cue.origin == .onDeviceModel || cue.isUserEdited {
                Button(action: onResetToAuthored) {
                    Label("Use Authored Cue", systemImage: "book.closed")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("resetPracticeCueToAuthoredButton")
            }
            onDeviceButton
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
    private var editAndDismissRow: some View {
        if allowsEditing {
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
        } else {
            dismissButton
        }
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Label("Edit Cue", systemImage: "pencil")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("editPracticeCueButton")
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Label("Dismiss", systemImage: "eye.slash")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("dismissPracticeCueButton")
    }

    @ViewBuilder
    private var onDeviceButton: some View {
        let onDeviceAvailable = coordinator.modelAvailability.isAvailable
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
