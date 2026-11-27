import Foundation
import SwiftData

@MainActor
final class PresentationStore {
    static let schema = Schema([
        PresentationRecord.self,
        TalkRevisionRecord.self,
        TalkRevisionEntryRecord.self,
        SectionRevisionRecord.self,
        AttemptRecord.self,
        CoachingCueRecord.self
    ])

    let modelContext: ModelContext
    let storageRootURL: URL
    private let saveContext: (ModelContext) throws -> Void

    init(
        modelContext: ModelContext,
        storageRootURL: URL? = nil,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.storageRootURL = storageRootURL ?? SlideDeckStorage.defaultStorageRootURL()
        self.saveContext = saveContext
    }

    static func makeModelContainer(
        storeURL: URL? = nil,
        inMemory: Bool = false,
        allowsSave: Bool = true
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave
            )
        } else if let storeURL {
            configuration = ModelConfiguration(
                schema: schema,
                url: storeURL,
                allowsSave: allowsSave
            )
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storeDirectory = appSupport.appendingPathComponent("Spelum", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let defaultURL = storeDirectory.appendingPathComponent("spelum.sqlite")
            configuration = ModelConfiguration(
                schema: schema,
                url: defaultURL,
                allowsSave: allowsSave
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Queries

    func fetchPresentations() throws -> [PresentationRecord] {
        let descriptor = FetchDescriptor<PresentationRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func presentation(withID id: UUID) throws -> PresentationRecord? {
        try presentation(withID: id, in: modelContext)
    }

    func presentation(withID id: UUID, in context: ModelContext) throws -> PresentationRecord? {
        let descriptor = FetchDescriptor<PresentationRecord>(
            predicate: #Predicate<PresentationRecord> { record in
                record.id == id
            }
        )
        return try context.fetch(descriptor).first
    }

    func talkRevision(withID id: UUID) throws -> TalkRevisionRecord? {
        try talkRevision(withID: id, in: modelContext)
    }

    func talkRevision(withID id: UUID, in context: ModelContext) throws -> TalkRevisionRecord? {
        let descriptor = FetchDescriptor<TalkRevisionRecord>(
            predicate: #Predicate<TalkRevisionRecord> { record in
                record.id == id
            }
        )
        return try context.fetch(descriptor).first
    }

    func sectionRevision(withID id: UUID) throws -> SectionRevisionRecord? {
        try sectionRevision(withID: id, in: modelContext)
    }

    func sectionRevision(withID id: UUID, in context: ModelContext) throws -> SectionRevisionRecord? {
        let descriptor = FetchDescriptor<SectionRevisionRecord>(
            predicate: #Predicate<SectionRevisionRecord> { record in
                record.revisionID == id
            }
        )
        return try context.fetch(descriptor).first
    }

    func currentTalkRevision(for presentation: PresentationRecord) -> TalkRevisionRecord? {
        if let currentRevisionID = presentation.currentRevisionID,
           let matched = presentation.talkRevisions.first(where: { $0.id == currentRevisionID }) {
            return matched
        }
        return presentation.talkRevisions.max { $0.revisionNumber < $1.revisionNumber }
    }

    func revisionHistory(for presentation: PresentationRecord) -> [TalkRevisionRecord] {
        presentation.talkRevisions.sorted { $0.revisionNumber > $1.revisionNumber }
    }

    func orderedSections(in talkRevision: TalkRevisionRecord) -> [SectionRevisionRecord] {
        let sortedEntries = talkRevision.entries.sorted { $0.orderIndex < $1.orderIndex }
        let lookup = Dictionary(
            uniqueKeysWithValues: (talkRevision.presentation?.sectionRevisions ?? []).map {
                ($0.revisionID, $0)
            }
        )
        return sortedEntries.compactMap { entry in
            entry.sectionRevision ?? lookup[entry.sectionRevisionID]
        }
    }

    func orderedSections(for presentation: PresentationRecord) -> [SectionRevisionRecord] {
        guard let revision = currentTalkRevision(for: presentation) else {
            return []
        }
        return orderedSections(in: revision)
    }

    func speakerCount(for presentation: PresentationRecord) -> Int {
        let sections = orderedSections(for: presentation)
        let keys = Set(sections.map(Self.normalizedSpeakerKey))
        return max(keys.count, sections.isEmpty ? 0 : 1)
    }

    func knownSpeakers(in presentation: PresentationRecord) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for section in orderedSections(for: presentation) {
            let trimmed = section.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }

    // MARK: - Atomic Transaction Boundary

    func performAtomicWrite<Result>(_ body: () throws -> Result) throws -> Result {
        let previousAutosave = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosave }

        do {
            let result = try body()
            try saveContext(modelContext)
            return result
        } catch {
            modelContext.processPendingChanges()
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Unified Import Path

    static func readUTF8ScriptFile(at url: URL) throws -> (text: String, suggestedTitle: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresentationImportError.unreadableFile
        }

        guard let decodedText = String(data: data, encoding: .utf8) else {
            throw PresentationImportError.invalidUTF8
        }

        let fileTitle = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (decodedText, fileTitle.isEmpty ? nil : fileTitle)
    }

    @discardableResult
    func importScript(
        text: String,
        title: String? = nil,
        pdfFileURL: URL? = nil
    ) throws -> PresentationRecord {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PresentationImportError.emptyScript
        }

        let parsed = AnnotatedScriptParser.parseDocument(text)
        var copiedDeck: CopiedSlideDeck?
        if let pdfFileURL {
            let inspected = try SlideDeckStorage.inspectPDF(at: pdfFileURL)
            let plan = SlidePairingPlan.build(
                scriptText: text,
                pdfPageCount: inspected.pageCount,
                pdfAspectRatios: inspected.pageAspectRatios
            )
            guard plan.isValidForImport else {
                throw PresentationImportError.slideCountMismatch(
                    headings: plan.explicitHeadingCount,
                    pages: inspected.pageCount
                )
            }
            copiedDeck = try SlideDeckStorage.copyPDFToAppStorage(
                from: pdfFileURL,
                storageRootURL: storageRootURL
            )
        }

        do {
            return try persistImportedPresentation(
                text: text,
                title: title,
                parsed: parsed,
                copiedDeck: copiedDeck
            )
        } catch {
            if let deckPath = copiedDeck?.relativePath {
                SlideDeckStorage.removeDeckFile(
                    relativePath: deckPath,
                    storageRootURL: storageRootURL
                )
            }
            throw error
        }
    }

    @discardableResult
    func importScript(
        fromFileURL url: URL,
        title: String? = nil,
        pdfFileURL: URL? = nil
    ) throws -> PresentationRecord {
        let loaded = try Self.readUTF8ScriptFile(at: url)
        let trimmedExplicit = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenTitle: String?
        if let trimmedExplicit, !trimmedExplicit.isEmpty {
            chosenTitle = trimmedExplicit
        } else {
            chosenTitle = loaded.suggestedTitle
        }

        return try importScript(text: loaded.text, title: chosenTitle, pdfFileURL: pdfFileURL)
    }
}
