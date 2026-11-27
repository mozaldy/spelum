import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum ImportFilePickerKind: Equatable {
    case scriptFile
    case pdfDeck
}

struct ImportScriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onImported: (UUID) -> Void

    @State private var draftTitle = ""
    @State private var draftText = ""
    @State private var loadedScriptFileName: String?
    @State private var stagedPDF: InspectedPDFDeck?
    @State private var activePickerKind: ImportFilePickerKind?
    @State private var isPresentingFileImporter = false
    @State private var showingDiscardConfirmation = false
    @State private var errorMessage: String?

    private var isScriptTextValid: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPendingInput: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isScriptTextValid
            || stagedPDF != nil
    }

    private var pairingPlan: SlidePairingPlan {
        SlidePairingPlan.build(
            scriptText: draftText,
            pdfPageCount: stagedPDF?.pageCount,
            pdfAspectRatios: stagedPDF?.pageAspectRatios ?? []
        )
    }

    private var activeAllowedContentTypes: [UTType] {
        switch activePickerKind {
        case .pdfDeck:
            [.pdf]
        case .scriptFile, .none:
            [.utf8PlainText, .plainText]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    errorSection(errorMessage)
                }
                titleSection
                fileImportSection
                pdfDeckSection
                pasteScriptSection
                if isScriptTextValid || stagedPDF != nil {
                    ImportPairingPreviewSection(
                        plan: pairingPlan,
                        stagedPDF: stagedPDF,
                        onReplacePDF: { presentPicker(.pdfDeck) },
                        onRemovePDF: removeStagedPDF
                    )
                }
            }
            .navigationTitle("Import Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        requestCancel()
                    }
                    .accessibilityIdentifier("cancelImportButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performImport()
                    }
                    .accessibilityIdentifier("confirmImportButton")
                }
            }
            .fileImporter(
                isPresented: $isPresentingFileImporter,
                allowedContentTypes: activeAllowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImporterResult(result)
            }
            .confirmationDialog(
                "You have an unsaved import draft.",
                isPresented: $showingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                if pairingPlan.isValidForImport {
                    Button("Import Now") {
                        performImport()
                    }
                }
                Button("Discard Draft", role: .destructive) {
                    cleanupStagedPDF()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                if pairingPlan.isValidForImport {
                    Text("Import this presentation now, discard your draft, or keep editing.")
                } else {
                    Text("Finish resolving your script or PDF pairing, or discard your draft.")
                }
            }
            .onChange(of: draftText) { _, newValue in
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = nil
                }
            }
            .onDisappear {
                cleanupStagedPDF()
            }
        }
        .interactiveDismissDisabled(hasPendingInput)
    }

    private var titleSection: some View {
        Section {
            TextField("Optional presentation title", text: $draftTitle)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("importTitleField")
        } header: {
            Text("Title")
        } footer: {
            Text("Leave blank to use the file name, first # section, or first spoken line.")
        }
    }

    private var fileImportSection: some View {
        Section {
            Button {
                presentPicker(.scriptFile)
            } label: {
                Label("Choose UTF-8 Text File…", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("chooseUTF8FileButton")
            .accessibilityHint("Opens Files to load a UTF-8 plain text script into this draft.")

            if let loadedScriptFileName {
                Label(loadedScriptFileName, systemImage: "doc.text")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("loadedScriptFileNameLabel")
            }
        } header: {
            Text("Script File")
        } footer: {
            Text("UTF-8 files load into the same draft so you can preview headings or attach slides.")
        }
    }

    private var pdfDeckSection: some View {
        Section {
            if let stagedPDF {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stagedPDF.displayFileName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .accessibilityIdentifier("selectedPDFNameLabel")
                        Text("\(stagedPDF.pageCount) \(stagedPDF.pageCount == 1 ? "page" : "pages")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("selectedPDFPageCountLabel")
                    }
                    Spacer()
                }

                Button {
                    presentPicker(.pdfDeck)
                } label: {
                    Label("Replace Slide PDF…", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("replacePDFButton")

                Button(role: .destructive) {
                    removeStagedPDF()
                } label: {
                    Label("Remove Slide PDF", systemImage: "trash")
                }
                .accessibilityIdentifier("removePDFButton")
            } else {
                Button {
                    presentPicker(.pdfDeck)
                } label: {
                    Label("Attach Keynote Slide PDF…", systemImage: "rectangle.stack.badge.plus")
                }
                .accessibilityIdentifier("choosePDFButton")
                .accessibilityHint("Optional. Opens Files to pair a static PDF deck with ## slide headings.")
            }
        } header: {
            Text("Slides (Optional)")
        } footer: {
            Text("Export your Keynote deck as a static PDF. Spelum copies it locally and pairs pages in order.")
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

            if !draftText.isEmpty && !isScriptTextValid {
                Label(
                    PresentationImportError.emptyScript.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("importTextValidationError")
            }
        } header: {
            Text("Paste or Edit Script")
        } footer: {
            Text("Use # for sections, ## for slides, [directions], / // /// pauses, and ↗ ↘ pitch cues.")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("importErrorLabel")
        }
    }
}

private extension ImportScriptSheet {
    func presentPicker(_ kind: ImportFilePickerKind) {
        errorMessage = nil
        activePickerKind = kind
        isPresentingFileImporter = true
    }

    private func requestCancel() {
        if hasPendingInput {
            showingDiscardConfirmation = true
        } else {
            cleanupStagedPDF()
            dismiss()
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

    private func performImport() {
        errorMessage = nil
        let store = PresentationStore(modelContext: modelContext)
        do {
            let presentation = try store.importScript(
                text: draftText,
                title: draftTitle,
                pdfFileURL: stagedPDF?.stagedURL
            )
            cleanupStagedPDF()
            onImported(presentation.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        let kind = activePickerKind ?? .scriptFile
        activePickerKind = nil

        switch result {
        case .failure(let error):
            if Self.isUserCancelledError(error) {
                return
            }
            errorMessage = kind == .pdfDeck
                ? PresentationImportError.unreadableOrCorruptPDF.localizedDescription
                : PresentationImportError.unreadableFile.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStartScope = url.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            switch kind {
            case .scriptFile:
                loadScriptFile(from: url)
            case .pdfDeck:
                loadPDFDeck(from: url)
            }
        }
    }

    private func loadScriptFile(from url: URL) {
        errorMessage = nil
        do {
            let loaded = try PresentationStore.readUTF8ScriptFile(at: url)
            guard !loaded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = PresentationImportError.emptyScript.localizedDescription
                return
            }
            draftText = loaded.text
            loadedScriptFileName = url.lastPathComponent
            if draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggested = loaded.suggestedTitle {
                draftTitle = suggested
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPDFDeck(from url: URL) {
        errorMessage = nil
        do {
            let inspected = try SlideDeckStorage.inspectAndStagePDF(from: url)
            if let previous = stagedPDF {
                SlideDeckStorage.removeStagedFile(at: previous.stagedURL)
            }
            stagedPDF = inspected
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeStagedPDF() {
        errorMessage = nil
        cleanupStagedPDF()
    }

    private func cleanupStagedPDF() {
        if let current = stagedPDF {
            SlideDeckStorage.removeStagedFile(at: current.stagedURL)
            stagedPDF = nil
        }
    }

    private static func isUserCancelledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
