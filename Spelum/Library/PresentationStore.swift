import Foundation
import SwiftData

@MainActor
final class PresentationStore {
    static let schema = Schema([
        PresentationRecord.self,
        TalkRevisionRecord.self,
        TalkRevisionEntryRecord.self,
        SectionRevisionRecord.self
    ])

    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    static func makeModelContainer(
        storeURL: URL? = nil,
        inMemory: Bool = false
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let storeURL {
            configuration = ModelConfiguration(schema: schema, url: storeURL)
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
            configuration = ModelConfiguration(schema: schema, url: defaultURL)
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
        let descriptor = FetchDescriptor<PresentationRecord>(
            predicate: #Predicate<PresentationRecord> { record in
                record.id == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    func talkRevision(withID id: UUID) throws -> TalkRevisionRecord? {
        let descriptor = FetchDescriptor<TalkRevisionRecord>(
            predicate: #Predicate<TalkRevisionRecord> { record in
                record.id == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    func sectionRevision(withID id: UUID) throws -> SectionRevisionRecord? {
        let descriptor = FetchDescriptor<SectionRevisionRecord>(
            predicate: #Predicate<SectionRevisionRecord> { record in
                record.revisionID == id
            }
        )
        return try modelContext.fetch(descriptor).first
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

    func handoffContext(
        forSectionID sectionID: UUID,
        in presentation: PresentationRecord
    ) -> HandoffContext? {
        guard let revision = currentTalkRevision(for: presentation) else {
            return nil
        }
        return handoffContext(forSectionID: sectionID, in: revision)
    }

    func handoffContext(
        forSectionID sectionID: UUID,
        in talkRevision: TalkRevisionRecord
    ) -> HandoffContext? {
        let sections = orderedSections(in: talkRevision)
        guard let index = sections.firstIndex(where: { $0.sectionID == sectionID }) else {
            return nil
        }

        let current = sections[index]
        let isSingleSpeakerTalk = Set(sections.map(Self.normalizedSpeakerKey)).count <= 1
        let customCue = Self.normalizedOptionalText(current.handoffCueOverride)

        guard index > 0 else {
            return HandoffContext(
                sectionID: current.sectionID,
                sectionIndex: index,
                precedingSectionID: nil,
                precedingSectionTitle: nil,
                precedingSpeaker: nil,
                precedingSpeakerRole: nil,
                derivedFinalLine: nil,
                customCue: customCue,
                effectiveCueText: customCue,
                isCustomCue: customCue != nil,
                isFirstSection: true,
                isSpeakerChange: false,
                isSingleSpeakerTalk: isSingleSpeakerTalk
            )
        }

        let preceding = sections[index - 1]
        let derivedLine = Self.finalNonEmptyLine(in: preceding.text)
        let isSpeakerChange = Self.normalizedSpeakerKey(preceding) != Self.normalizedSpeakerKey(current)

        return HandoffContext(
            sectionID: current.sectionID,
            sectionIndex: index,
            precedingSectionID: preceding.sectionID,
            precedingSectionTitle: preceding.title,
            precedingSpeaker: preceding.speaker,
            precedingSpeakerRole: preceding.speakerRole,
            derivedFinalLine: derivedLine,
            customCue: customCue,
            effectiveCueText: customCue ?? derivedLine,
            isCustomCue: customCue != nil,
            isFirstSection: false,
            isSpeakerChange: isSpeakerChange,
            isSingleSpeakerTalk: isSingleSpeakerTalk
        )
    }

    // MARK: - Unified Import Path

    @discardableResult
    func importScript(text: String, title: String? = nil) throws -> PresentationRecord {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PresentationImportError.emptyScript
        }

        let now = Date()
        let resolvedTitle = Self.resolvedTitle(explicit: title, fallbackText: text)
        let presentation = PresentationRecord(
            title: resolvedTitle,
            sourceText: text,
            createdAt: now,
            updatedAt: now
        )
        let initialSection = SectionRevisionRecord(
            title: "Section 1",
            text: text,
            speaker: SpeakerRole.presenter.displayName,
            speakerRole: .presenter,
            purpose: .general,
            createdAt: now,
            presentation: presentation
        )
        let initialRevision = TalkRevisionRecord(
            revisionNumber: 1,
            title: resolvedTitle,
            changeSummary: "Imported script",
            createdAt: now,
            presentation: presentation
        )
        let entry = TalkRevisionEntryRecord(
            orderIndex: 0,
            sectionRevisionID: initialSection.revisionID,
            talkRevision: initialRevision,
            sectionRevision: initialSection
        )

        initialRevision.entries.append(entry)
        presentation.sectionRevisions.append(initialSection)
        presentation.talkRevisions.append(initialRevision)
        presentation.currentRevisionID = initialRevision.id

        modelContext.insert(presentation)
        modelContext.insert(initialSection)
        modelContext.insert(initialRevision)
        modelContext.insert(entry)
        try modelContext.save()

        return presentation
    }

    @discardableResult
    func importScript(fromFileURL url: URL, title: String? = nil) throws -> PresentationRecord {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresentationImportError.unreadableFile
        }

        guard let decodedText = String(data: data, encoding: .utf8) else {
            throw PresentationImportError.invalidUTF8
        }

        let trimmedExplicit = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileTitle = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenTitle: String?
        if let trimmedExplicit, !trimmedExplicit.isEmpty {
            chosenTitle = trimmedExplicit
        } else if !fileTitle.isEmpty {
            chosenTitle = fileTitle
        } else {
            chosenTitle = nil
        }

        return try importScript(text: decodedText, title: chosenTitle)
    }
}
