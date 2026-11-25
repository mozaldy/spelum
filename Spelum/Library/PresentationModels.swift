import Foundation
import SwiftData

enum SpeakerRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case presenter
    case teammate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .presenter: "Presenter"
        case .teammate: "Teammate"
        }
    }

    var symbolName: String {
        switch self {
        case .presenter: "person.fill"
        case .teammate: "person.2.fill"
        }
    }
}

enum SectionPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case general
    case story
    case reveal
    case demonstration
    case closing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: "General"
        case .story: "Story"
        case .reveal: "Reveal"
        case .demonstration: "Demonstration"
        case .closing: "Closing"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "text.alignleft"
        case .story: "book"
        case .reveal: "sparkles"
        case .demonstration: "play.display"
        case .closing: "flag.checkered"
        }
    }
}

enum PresentationImportError: LocalizedError, Equatable, Sendable {
    case emptyScript
    case unreadableFile
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .emptyScript:
            "The script is empty. Paste or import non-empty UTF-8 text."
        case .unreadableFile:
            "The selected file could not be read."
        case .invalidUTF8:
            "The selected file is not valid UTF-8 plain text."
        }
    }
}

enum SectionEditError: LocalizedError, Equatable, Sendable {
    case presentationNotFound
    case sectionNotFound
    case emptySectionText
    case invalidSplitPosition
    case splitCrossesExactPhrase
    case cannotDeleteLastSection

    var errorDescription: String? {
        switch self {
        case .presentationNotFound:
            "The presentation revision could not be found."
        case .sectionNotFound:
            "The selected section could not be found in the current revision."
        case .emptySectionText:
            "Section text cannot be empty."
        case .invalidSplitPosition:
            "Choose a split point with text on both sides."
        case .splitCrossesExactPhrase:
            "This split point cuts through your marked exact phrase. " +
            "Move the split before or after the phrase, or confirm clearing it."
        case .cannotDeleteLastSection:
            "A presentation must keep at least one section."
        }
    }
}

enum ExactPhraseSplitPolicy: Equatable, Sendable {
    case protect
    case clearExactPhrase
}

struct ExactPhraseSplitConflict: Equatable, Sendable {
    let phrase: String
    let beforePhraseSplitIndex: String.Index?
    let afterPhraseSplitIndex: String.Index?
}

enum HandoffTransitionOrigin: Equatable, Sendable {
    case opening
    case fromSection(UUID)
}

struct EditableCueWord: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

enum CueWordListHelper {
    static func updateText(_ newText: String, for id: UUID, in items: inout [EditableCueWord]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = newText
    }

    static func remove(id: UUID, from items: inout [EditableCueWord], focusedID: inout UUID?) {
        if focusedID == id {
            focusedID = nil
        }
        items.removeAll { $0.id == id }
    }

    static func remove(at offsets: IndexSet, from items: inout [EditableCueWord], focusedID: inout UUID?) {
        let removedIDs = Set(offsets.compactMap { items.indices.contains($0) ? items[$0].id : nil })
        if let currentFocus = focusedID, removedIDs.contains(currentFocus) {
            focusedID = nil
        }
        items = items.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
    }

    static func cleanedCueWords(from items: [EditableCueWord], pendingNewWord: String = "") -> [String] {
        var cleaned = items
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedPending = pendingNewWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPending.isEmpty {
            cleaned.append(trimmedPending)
        }
        return cleaned
    }
}

struct SectionDraft: Equatable, Sendable {
    var title: String
    var text: String
    var speaker: String
    var speakerRole: SpeakerRole
    var purpose: SectionPurpose
    var cueWords: [String]
    var exactPhrase: String?
    var handoffCueOverride: String?

    init(
        title: String,
        text: String,
        speaker: String,
        speakerRole: SpeakerRole,
        purpose: SectionPurpose,
        cueWords: [String],
        exactPhrase: String?,
        handoffCueOverride: String?
    ) {
        self.title = title
        self.text = text
        self.speaker = speaker
        self.speakerRole = speakerRole
        self.purpose = purpose
        self.cueWords = cueWords
        self.exactPhrase = exactPhrase
        self.handoffCueOverride = handoffCueOverride
    }

    init(record: SectionRevisionRecord) {
        self.title = record.title
        self.text = record.text
        self.speaker = record.speaker
        self.speakerRole = record.speakerRole
        self.purpose = record.purpose
        self.cueWords = record.cueWords
        self.exactPhrase = record.exactPhrase
        self.handoffCueOverride = record.handoffCueOverride
    }
}

struct HandoffContext: Equatable, Sendable {
    let sectionID: UUID
    let sectionIndex: Int
    let precedingSectionID: UUID?
    let precedingSectionTitle: String?
    let precedingSpeaker: String?
    let precedingSpeakerRole: SpeakerRole?
    let derivedFinalLine: String?
    let customCue: String?
    let effectiveCueText: String?
    let isCustomCue: Bool
    let isFirstSection: Bool
    let isSpeakerChange: Bool
    let isSingleSpeakerTalk: Bool
}

struct LineSplitOption: Identifiable, Sendable {
    let id: Int
    let lineNumber: Int
    let beforePreview: String
    let afterPreview: String
    let splitIndex: String.Index
}

struct SectionSplitResult {
    let talkRevision: TalkRevisionRecord
    let firstSection: SectionRevisionRecord
    let secondSection: SectionRevisionRecord
}

@Model
final class PresentationRecord {
    var id: UUID
    var title: String
    var sourceText: String
    var createdAt: Date
    var updatedAt: Date
    var currentRevisionID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \TalkRevisionRecord.presentation)
    var talkRevisions: [TalkRevisionRecord]

    @Relationship(deleteRule: .cascade, inverse: \SectionRevisionRecord.presentation)
    var sectionRevisions: [SectionRevisionRecord]

    init(
        id: UUID = UUID(),
        title: String,
        sourceText: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        currentRevisionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceText = sourceText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.currentRevisionID = currentRevisionID
        self.talkRevisions = []
        self.sectionRevisions = []
    }
}

@Model
final class TalkRevisionRecord {
    var id: UUID
    var revisionNumber: Int
    var title: String
    var changeSummary: String
    var createdAt: Date
    var presentation: PresentationRecord?

    @Relationship(deleteRule: .cascade, inverse: \TalkRevisionEntryRecord.talkRevision)
    var entries: [TalkRevisionEntryRecord]

    init(
        id: UUID = UUID(),
        revisionNumber: Int,
        title: String,
        changeSummary: String,
        createdAt: Date = Date(),
        presentation: PresentationRecord? = nil
    ) {
        self.id = id
        self.revisionNumber = revisionNumber
        self.title = title
        self.changeSummary = changeSummary
        self.createdAt = createdAt
        self.presentation = presentation
        self.entries = []
    }

    var orderedSectionRevisionIDs: [UUID] {
        entries
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(\.sectionRevisionID)
    }
}

@Model
final class TalkRevisionEntryRecord {
    var orderIndex: Int
    var sectionRevisionID: UUID
    var talkRevision: TalkRevisionRecord?
    var sectionRevision: SectionRevisionRecord?

    init(
        orderIndex: Int,
        sectionRevisionID: UUID,
        talkRevision: TalkRevisionRecord? = nil,
        sectionRevision: SectionRevisionRecord? = nil
    ) {
        self.orderIndex = orderIndex
        self.sectionRevisionID = sectionRevisionID
        self.talkRevision = talkRevision
        self.sectionRevision = sectionRevision
    }
}

@Model
final class SectionRevisionRecord {
    var revisionID: UUID
    var sectionID: UUID
    var title: String
    var text: String
    var speaker: String
    var speakerRoleRawValue: String
    var purposeRawValue: String
    var cueWordsData: Data
    var exactPhrase: String?
    var handoffCueOverride: String?
    var handoffCueSourceSectionID: UUID?
    var handoffCueIsOpening: Bool?
    var createdAt: Date
    var presentation: PresentationRecord?

    init(
        revisionID: UUID = UUID(),
        sectionID: UUID = UUID(),
        title: String,
        text: String,
        speaker: String,
        speakerRole: SpeakerRole = .presenter,
        purpose: SectionPurpose = .general,
        cueWords: [String] = [],
        exactPhrase: String? = nil,
        handoffCueOverride: String? = nil,
        handoffCueSourceSectionID: UUID? = nil,
        handoffCueIsOpening: Bool? = nil,
        createdAt: Date = Date(),
        presentation: PresentationRecord? = nil
    ) {
        self.revisionID = revisionID
        self.sectionID = sectionID
        self.title = title
        self.text = text
        self.speaker = speaker
        self.speakerRoleRawValue = speakerRole.rawValue
        self.purposeRawValue = purpose.rawValue
        self.cueWordsData = Self.encodeCueWords(cueWords)
        self.exactPhrase = exactPhrase
        self.handoffCueOverride = handoffCueOverride
        self.handoffCueSourceSectionID = handoffCueSourceSectionID
        self.handoffCueIsOpening = handoffCueIsOpening
        self.createdAt = createdAt
        self.presentation = presentation
    }

    var speakerRole: SpeakerRole {
        SpeakerRole(rawValue: speakerRoleRawValue) ?? .presenter
    }

    var purpose: SectionPurpose {
        SectionPurpose(rawValue: purposeRawValue) ?? .general
    }

    var cueWords: [String] {
        (try? JSONDecoder().decode([String].self, from: cueWordsData)) ?? []
    }

    private static func encodeCueWords(_ words: [String]) -> Data {
        (try? JSONEncoder().encode(words)) ?? Data()
    }
}
