import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportScriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onImported: (UUID) -> Void

    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var showingFileImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                fileImportSection
                pasteScriptSection
                if let errorMessage {
                    errorSection(errorMessage)
                }
            }
            .navigationTitle("Import Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importPastedText()
                    }
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("confirmImportButton")
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.utf8PlainText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .onChange(of: draftText) { _, newValue in
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = nil
                }
            }
        }
    }

    private var titleSection: some View {
        Section {
            TextField("Optional presentation title", text: $draftTitle)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("importTitleField")
        } header: {
            Text("Title")
        } footer: {
            Text("Leave blank to use the file name or first line of your script.")
        }
    }

    private var fileImportSection: some View {
        Section {
            Button {
                errorMessage = nil
                showingFileImporter = true
            } label: {
                Label("Choose UTF-8 Text File…", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("chooseUTF8FileButton")
            .accessibilityHint("Opens Files to import a UTF-8 plain text script.")
        } header: {
            Text("Files")
        } footer: {
            Text("UTF-8 plain text files use the same import path as pasted scripts.")
        }
    }

    private var pasteScriptSection: some View {
        Section {
            PasteButton(payloadType: String.self) { pastedStrings in
                handlePastedStrings(pastedStrings)
            }
            .accessibilityIdentifier("pasteFromClipboardButton")

            TextEditor(text: $draftText)
                .frame(minHeight: 200)
                .accessibilityLabel("Script text")
                .accessibilityIdentifier("importScriptTextEditor")
        } header: {
            Text("Paste or Type Script")
        } footer: {
            Text("Blank lines, curly quotes, and emoji are preserved verbatim on this device.")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("importErrorLabel")
        }
    }

    private func handlePastedStrings(_ strings: [String]) {
        errorMessage = nil
        let combined = strings.joined(separator: "\n")
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = PresentationImportError.emptyScript.localizedDescription
            return
        }
        draftText = combined
    }

    private func importPastedText() {
        errorMessage = nil
        let store = PresentationStore(modelContext: modelContext)
        do {
            let presentation = try store.importScript(text: draftText, title: draftTitle)
            onImported(presentation.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .failure:
            errorMessage = PresentationImportError.unreadableFile.localizedDescription
        case .success(let urls):
            guard let url = urls.first else {
                errorMessage = PresentationImportError.unreadableFile.localizedDescription
                return
            }
            let didStartScope = url.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let store = PresentationStore(modelContext: modelContext)
            do {
                let presentation = try store.importScript(fromFileURL: url, title: draftTitle)
                onImported(presentation.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
