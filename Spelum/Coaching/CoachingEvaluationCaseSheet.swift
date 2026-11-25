import SwiftUI

struct CoachingEvaluationCaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let entry: BlindedEvaluationEntry
    let caseIndex: Int
    let totalCases: Int
    let isUnblinded: Bool
    let hasNextCase: Bool
    let onSave: (BlindedCaseRating, Bool) -> Void

    @State private var rating: BlindedCaseRating

    init(
        entry: BlindedEvaluationEntry,
        caseIndex: Int,
        totalCases: Int,
        isUnblinded: Bool,
        hasNextCase: Bool,
        onSave: @escaping (BlindedCaseRating, Bool) -> Void
    ) {
        self.entry = entry
        self.caseIndex = caseIndex
        self.totalCases = totalCases
        self.isUnblinded = isUnblinded
        self.hasNextCase = hasNextCase
        self.onSave = onSave
        self._rating = State(initialValue: entry.rating ?? BlindedCaseRating())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    caseContextCard
                    optionCard(
                        label: "Option A",
                        suggestion: entry.optionASuggestion,
                        revealedSource: isUnblinded ? entry.optionASource : nil,
                        isUseful: $rating.optionAUseful,
                        safetyIssues: $rating.optionASafetyIssues,
                        idPrefix: "optionA"
                    )
                    optionCard(
                        label: "Option B",
                        suggestion: entry.optionBSuggestion,
                        revealedSource: isUnblinded ? entry.optionBSource : nil,
                        isUseful: $rating.optionBUseful,
                        safetyIssues: $rating.optionBSafetyIssues,
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

    private var caseContextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(entry.category.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }

            Text(entry.contextSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    // swiftlint:disable:next function_parameter_count
    private func optionCard(
        label: String,
        suggestion: CoachingSuggestion,
        revealedSource: CoachingSourceMode?,
        isUseful: Binding<Bool>,
        safetyIssues: Binding<Set<EvaluationSafetyIssue>>,
        idPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let revealedSource {
                    Text(revealedSource.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                }
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

            Toggle("Useful for this rehearsal case", isOn: isUseful)
                .accessibilityIdentifier("\(idPrefix)_usefulToggle")

            VStack(alignment: .leading, spacing: 6) {
                Text("Safety Checks (flag any violation)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(EvaluationSafetyIssue.allCases) { issue in
                    safetyIssueToggle(
                        issue: issue,
                        selectedIssues: safetyIssues,
                        idPrefix: idPrefix
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func safetyIssueToggle(
        issue: EvaluationSafetyIssue,
        selectedIssues: Binding<Set<EvaluationSafetyIssue>>,
        idPrefix: String
    ) -> some View {
        let isFlagged = Binding<Bool>(
            get: { selectedIssues.wrappedValue.contains(issue) },
            set: { newValue in
                if newValue {
                    selectedIssues.wrappedValue.insert(issue)
                } else {
                    selectedIssues.wrappedValue.remove(issue)
                }
            }
        )
        return Toggle(issue.displayName, isOn: isFlagged)
            .font(.footnote)
            .tint(.red)
            .accessibilityIdentifier("\(idPrefix)_safety_\(issue.rawValue)")
    }

    private var preferenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blinded Preference")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(BlindedPreference.allCases) { pref in
                        preferenceButton(pref)
                    }
                }
            } else {
                Picker("Preference", selection: $rating.preference) {
                    ForEach(BlindedPreference.allCases) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("blindedPreferencePicker")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func preferenceButton(_ pref: BlindedPreference) -> some View {
        Button {
            rating.preference = pref
        } label: {
            HStack {
                Text(pref.displayName)
                Spacer()
                if rating.preference == pref {
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("blindedPreference_\(pref.rawValue)")
    }

    private var saveButtons: some View {
        VStack(spacing: 10) {
            if hasNextCase {
                Button {
                    onSave(rating, true)
                } label: {
                    Label("Save & Next Case", systemImage: "arrow.right.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("saveAndNextEvaluationCaseButton")
            }

            Button {
                onSave(rating, false)
                dismiss()
            } label: {
                Label("Save Rating", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("saveEvaluationCaseButton")
        }
    }
}
