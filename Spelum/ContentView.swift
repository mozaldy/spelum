import SwiftData
import SwiftUI

enum LibraryRoute: Hashable {
    case presentation(UUID)
    case section(presentationID: UUID, sectionID: UUID)
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Query(sort: \PresentationRecord.updatedAt, order: .reverse)
    private var presentations: [PresentationRecord]

    @State private var navigationPath: [LibraryRoute] = []
    @State private var showingImportSheet = false
    @State private var presentationPendingDelete: PresentationRecord?
    @State private var errorMessage: String?

    private var store: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if presentations.isEmpty {
                    emptyLibraryView
                } else {
                    presentationsListView
                }
            }
            .navigationTitle("Presentations")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImportSheet = true
                    } label: {
                        Label("Import Script", systemImage: "plus")
                    }
                    .accessibilityLabel("Import Script")
                    .accessibilityHint("Paste a script or import a UTF-8 plain text file.")
                    .accessibilityIdentifier("importScriptButton")
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                destinationView(for: route)
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportScriptSheet { importedPresentationID in
                    navigationPath = [.presentation(importedPresentationID)]
                }
            }
            .confirmationDialog(
                "Delete “\(presentationPendingDelete?.title ?? "Presentation")”?",
                isPresented: Binding(
                    get: { presentationPendingDelete != nil },
                    set: { isPresented in
                        if !isPresented { presentationPendingDelete = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Presentation", role: .destructive) {
                    if let target = presentationPendingDelete {
                        presentationPendingDelete = nil
                        deletePresentation(target)
                    }
                }
                Button("Cancel", role: .cancel) {
                    presentationPendingDelete = nil
                }
            } message: {
                Text("This removes the presentation and all of its saved script revisions from this device.")
            }
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Presentations Yet", systemImage: "doc.text")
        } description: {
            Text(
                "Paste a rehearsal script or import a UTF-8 plain text file " +
                "to organize sections and prepare your handoff."
            )
        } actions: {
            Button {
                showingImportSheet = true
            } label: {
                Label("Import Script", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("emptyStateImportButton")
        }
    }

    private var presentationsListView: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                ForEach(presentations, id: \.id) { presentation in
                    NavigationLink(value: LibraryRoute.presentation(presentation.id)) {
                        PresentationLibraryRow(
                            presentation: presentation,
                            sectionCount: store.orderedSections(for: presentation).count,
                            revisionNumber: store.currentTalkRevision(for: presentation)?.revisionNumber ?? 1,
                            speakerCount: store.speakerCount(for: presentation),
                            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                        )
                    }
                    .accessibilityIdentifier("presentationRow_\(presentation.title)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            presentationPendingDelete = presentation
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Scripts and saved revisions stay strictly local on this device.")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func destinationView(for route: LibraryRoute) -> some View {
        switch route {
        case .presentation(let presentationID):
            if let presentation = presentations.first(where: { $0.id == presentationID }) {
                PresentationDetailView(presentation: presentation) { sectionID in
                    navigationPath.append(
                        .section(presentationID: presentation.id, sectionID: sectionID)
                    )
                }
            } else {
                ContentUnavailableView(
                    "Presentation Not Found",
                    systemImage: "doc.questionmark",
                    description: Text("This presentation may have been deleted.")
                )
            }
        case .section(let presentationID, let sectionID):
            if let presentation = presentations.first(where: { $0.id == presentationID }) {
                ScriptEditor(presentation: presentation, sectionID: sectionID) { nextSectionID in
                    replaceCurrentSectionRoute(
                        presentationID: presentation.id,
                        sectionID: nextSectionID
                    )
                }
            } else {
                ContentUnavailableView(
                    "Presentation Not Found",
                    systemImage: "doc.questionmark",
                    description: Text("This presentation may have been deleted.")
                )
            }
        }
    }

    private func replaceCurrentSectionRoute(presentationID: UUID, sectionID: UUID) {
        if !navigationPath.isEmpty {
            navigationPath[navigationPath.count - 1] = .section(
                presentationID: presentationID,
                sectionID: sectionID
            )
        } else {
            navigationPath = [
                .presentation(presentationID),
                .section(presentationID: presentationID, sectionID: sectionID)
            ]
        }
    }

    private func deletePresentation(_ presentation: PresentationRecord) {
        errorMessage = nil
        do {
            try store.deletePresentation(presentation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PresentationLibraryRow: View {
    let presentation: PresentationRecord
    let sectionCount: Int
    let revisionNumber: Int
    let speakerCount: Int
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title)
                .font(.headline)

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sectionsLabel)
                    Text(speakersLabel)
                    Text("Revision \(revisionNumber)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text("\(sectionsLabel) · \(speakersLabel) · Rev \(revisionNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Updated \(presentation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens ordered sections and handoff preparation.")
    }

    private var sectionsLabel: String {
        sectionCount == 1 ? "1 section" : "\(sectionCount) sections"
    }

    private var speakersLabel: String {
        speakerCount <= 1 ? "1 speaker" : "\(speakerCount) speakers"
    }
}

#Preview {
    if let container = try? PresentationStore.makeModelContainer(inMemory: true) {
        ContentView()
            .modelContainer(container)
    }
}
