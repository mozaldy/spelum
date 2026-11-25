import SwiftUI

struct CoachingEvaluationCaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let task: CoachingTaskKind
    let entry: BlindedEvaluationEntry
    let caseIndex: Int
    let totalCases: Int
    let isUnblinded: Bool
    let hasNextCase: Bool
    let onSave: (BlindedCaseRating, Bool) -> Void

    @State private var draft: BlindedCaseRatingDraft

    init(
        task: CoachingTaskKind = .preparation,
        entry: BlindedEvaluationEntry,
        caseIndex: Int,
        totalCases: Int,
        isUnblinded: Bool,
        hasNextCase: Bool,
        onSave: @escaping (BlindedCaseRating, Bool) -> Void
    ) {
        self.task = task
        self.entry = entry
        self.caseIndex = caseIndex
        self.totalCases = totalCases
        self.isUnblinded = isUnblinded
        self.hasNextCase = hasNextCase
        self.onSave = onSave
        self._draft = State(initialValue: BlindedCaseRatingDraft(existing: entry.rating))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    caseContextCard
                    CoachingEvaluationOptionCard(
                        label: "Option A",
                        suggestion: entry.optionASuggestion,
                        revealedBadge: revealedBadge(for: entry.optionASource),
                        fallbackDetail: revealedFallbackDetail(for: entry.optionASource),
                        isUseful: $draft.optionAUseful,
                        safetyIssues: $draft.optionASafetyIssues,
                        idPrefix: "optionA"
                    )
                    CoachingEvaluationOptionCard(
                        label: "Option B",
                        suggestion: entry.optionBSuggestion,
                        revealedBadge: revealedBadge(for: entry.optionBSource),
                        fallbackDetail: revealedFallbackDetail(for: entry.optionBSource),
                        isUseful: $draft.optionBUseful,
                        safetyIssues: $draft.optionBSafetyIssues,
                        idPrefix: "optionB"
                    )
                    preferenceCard
                    saveButtons
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Case \(caseIndex + 1) of \(totalCases)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func revealedBadge(for source: CoachingSourceMode) -> String? {
        guard isUnblinded else { return nil }
        if source == .onDeviceModel && entry.isModelFallback {
            return "On-Device Fallback (Authored)"
        }
        return source.displayName
    }

    private func revealedFallbackDetail(for source: CoachingSourceMode) -> String? {
        guard isUnblinded, source == .onDeviceModel, entry.isModelFallback else { return nil }
        return entry.modelFallbackSummary ?? "Fell back to authored baseline."
    }

    private var caseContextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.displayTitle(at: caseIndex, isUnblinded: isUnblinded))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("evaluationCaseHeaderTitle")
                Spacer()
                Text(entry.category.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }

            Text(entry.displayContextSummary(for: task, isUnblinded: isUnblinded))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("evaluationCaseContextSummary")

            if let handoff = entry.handoffCueText, !handoff.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Handoff Cue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("“\(handoff)”")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Section Script (\(entry.sectionTitle))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.scriptText)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var preferenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blinded Preference (Required)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(BlindedPreference.allCases) { pref in
                        preferenceButton(pref)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(BlindedPreference.allCases) { pref in
                        preferenceButton(pref)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func preferenceButton(_ pref: BlindedPreference) -> some View {
        let selected = draft.preference == pref
        return Button {
            draft.preference = pref
        } label: {
            HStack {
                Text(pref.displayName)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("blindedPreference_\(pref.rawValue)")
    }

    private var saveButtons: some View {
        VStack(spacing: 10) {
            if !draft.isComplete {
                Text("Select Useful or Not Useful for both options and pick a preference to save.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("evaluationIncompleteRatingHint")
            }

            if hasNextCase {
                Button {
                    if let rating = draft.buildRating() {
                        onSave(rating, true)
                    }
                } label: {
                    Label("Save & Next Case", systemImage: "arrow.right.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isComplete)
                .accessibilityIdentifier("saveAndNextEvaluationCaseButton")
            }

            Button {
                if let rating = draft.buildRating() {
                    onSave(rating, false)
                    dismiss()
                }
            } label: {
                Label("Save Rating", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!draft.isComplete)
            .accessibilityIdentifier("saveEvaluationCaseButton")
        }
    }
}

private struct CoachingEvaluationOptionCard: View {
    let label: String
    let suggestion: CoachingSuggestion
    let revealedBadge: String?
    let fallbackDetail: String?
    @Binding var isUseful: Bool?
    @Binding var safetyIssues: Set<EvaluationSafetyIssue>
    let idPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let revealedBadge {
                    Text(revealedBadge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                }
            }

            if let fallbackDetail {
                Label(fallbackDetail, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let title = suggestion.techniqueTitle {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let phrase = suggestion.exactPhrase, !phrase.isEmpty {
                CoachingQuotedPassageBox(
                    phrase: phrase,
                    fromHandoff: suggestion.exactPhraseFromHandoff
                )
            }

            Text(suggestion.displayedAction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text(suggestion.rationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            usefulnessButtons

            VStack(alignment: .leading, spacing: 6) {
                Text("Safety Checks (flag any violation)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(EvaluationSafetyIssue.allCases) { issue in
                    safetyIssueToggle(issue: issue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var usefulnessButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Useful for this rehearsal case? (Required)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                usefulChoiceButton(title: "Useful", value: true, idSuffix: "usefulYesButton")
                usefulChoiceButton(title: "Not Useful", value: false, idSuffix: "usefulNoButton")
            }
        }
    }

    private func usefulChoiceButton(title: String, value: Bool, idSuffix: String) -> some View {
        let selected = isUseful == value
        return Button {
            isUseful = value
        } label: {
            HStack {
                Text(title)
                if selected {
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(selected ? (value ? .green : .orange) : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(idPrefix)_\(idSuffix)")
    }

    private func safetyIssueToggle(issue: EvaluationSafetyIssue) -> some View {
        let isFlagged = Binding<Bool>(
            get: { safetyIssues.contains(issue) },
            set: { newValue in
                if newValue {
                    safetyIssues.insert(issue)
                } else {
                    safetyIssues.remove(issue)
                }
            }
        )
        return Toggle(issue.displayName, isOn: isFlagged)
            .font(.footnote)
            .tint(.red)
            .accessibilityIdentifier("\(idPrefix)_safety_\(issue.rawValue)")
    }
}
