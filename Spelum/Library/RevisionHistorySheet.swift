import SwiftData
import SwiftUI

struct RevisionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let presentation: PresentationRecord

    private var store: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var revisions: [TalkRevisionRecord] {
        store.revisionHistory(for: presentation)
    }

    var body: some View {
        NavigationStack {
            List(revisions, id: \.id) { revision in
                NavigationLink {
                    RevisionSnapshotView(
                        revision: revision,
                        sections: store.orderedSections(in: revision)
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Revision \(revision.revisionNumber)")
                                .font(.headline)
                            if revision.id == presentation.currentRevisionID {
                                Text("Current")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text(revision.changeSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(
                            "\(revision.entries.count) " +
                            "\(revision.entries.count == 1 ? "section" : "sections") · " +
                            "\(revision.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Revision History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RevisionSnapshotView: View {
    let revision: TalkRevisionRecord
    let sections: [SectionRevisionRecord]

    var body: some View {
        List {
            Section("Snapshot") {
                LabeledContent("Title", value: revision.title)
                LabeledContent("Revision", value: "\(revision.revisionNumber)")
                LabeledContent("Change", value: revision.changeSummary)
                LabeledContent(
                    "Saved",
                    value: revision.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
            }

            ForEach(Array(sections.enumerated()), id: \.element.revisionID) { index, section in
                Section("\(index + 1). \(section.title)") {
                    LabeledContent("Speaker", value: speakerSummary(for: section))
                    LabeledContent("Purpose", value: section.purpose.displayName)
                    if let exactPhrase = section.exactPhrase, !exactPhrase.isEmpty {
                        LabeledContent("Exact Phrase", value: exactPhrase)
                    }
                    if !section.cueWords.isEmpty {
                        LabeledContent("Cue Words", value: section.cueWords.joined(separator: ", "))
                    }
                    if let customCue = section.handoffCueOverride, !customCue.isEmpty {
                        LabeledContent("Custom Handoff", value: customCue)
                    }
                    Text(section.text)
                        .font(.body)
                }
            }
        }
        .navigationTitle("Revision \(revision.revisionNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func speakerSummary(for section: SectionRevisionRecord) -> String {
        let trimmed = section.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleName = section.speakerRole.displayName
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(roleName) == .orderedSame {
            return roleName
        }
        return "\(trimmed) (\(roleName))"
    }
}

struct OriginalScriptSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let sourceText: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.headline)
                    Text("Preserved verbatim from original import.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(sourceText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .accessibilityIdentifier("originalImportedScriptText")
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Original Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
