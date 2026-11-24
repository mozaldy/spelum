import Foundation
import SwiftData

extension PresentationStore {
    @discardableResult
    func saveSectionEdit(
        in presentation: PresentationRecord,
        sectionID: UUID,
        draft: SectionDraft,
        changeSummary: String = "Edited section"
    ) throws -> TalkRevisionRecord {
        guard let currentRevision = currentTalkRevision(for: presentation) else {
            throw SectionEditError.presentationNotFound
        }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SectionEditError.emptySectionText
        }

        let sections = orderedSections(in: currentRevision)
        guard let targetIndex = sections.firstIndex(where: { $0.sectionID == sectionID }) else {
            throw SectionEditError.sectionNotFound
        }

        let existing = sections[targetIndex]
        let now = Date()
        let newSectionRevision = makeSectionRevision(
            from: draft,
            sectionID: existing.sectionID,
            fallbackTitle: existing.title,
            timestamp: now,
            presentation: presentation
        )

        var updatedSections = sections
        updatedSections[targetIndex] = newSectionRevision

        presentation.sectionRevisions.append(newSectionRevision)
        modelContext.insert(newSectionRevision)

        return try appendTalkRevision(
            to: presentation,
            previousRevision: currentRevision,
            orderedSections: updatedSections,
            changeSummary: changeSummary,
            timestamp: now
        )
    }

    @discardableResult
    func splitSection(
        in presentation: PresentationRecord,
        sectionID: UUID,
        at splitIndex: String.Index,
        pendingDraft: SectionDraft? = nil
    ) throws -> SectionSplitResult {
        guard let currentRevision = currentTalkRevision(for: presentation) else {
            throw SectionEditError.presentationNotFound
        }

        let sections = orderedSections(in: currentRevision)
        guard let targetIndex = sections.firstIndex(where: { $0.sectionID == sectionID }) else {
            throw SectionEditError.sectionNotFound
        }

        let existing = sections[targetIndex]
        let base = pendingDraft ?? SectionDraft(record: existing)
        let (firstText, secondText) = try splitText(base.text, at: splitIndex)
        let now = Date()
        let (firstSection, secondSection) = makeSplitSections(
            base: base,
            existing: existing,
            splitTexts: (firstText, secondText),
            nextSectionNumber: sections.count + 1,
            timestamp: now
        )

        var updatedSections = sections
        updatedSections.replaceSubrange(targetIndex ... targetIndex, with: [firstSection, secondSection])
        presentation.sectionRevisions.append(contentsOf: [firstSection, secondSection])
        modelContext.insert(firstSection)
        modelContext.insert(secondSection)

        let newRevision = try appendTalkRevision(
            to: presentation,
            previousRevision: currentRevision,
            orderedSections: updatedSections,
            changeSummary: "Split \(firstSection.title)",
            timestamp: now
        )
        return SectionSplitResult(
            talkRevision: newRevision,
            firstSection: firstSection,
            secondSection: secondSection
        )
    }

    @discardableResult
    func reorderSections(
        in presentation: PresentationRecord,
        orderedSectionIDs: [UUID]
    ) throws -> TalkRevisionRecord {
        guard let currentRevision = currentTalkRevision(for: presentation) else {
            throw SectionEditError.presentationNotFound
        }

        let currentSections = orderedSections(in: currentRevision)
        guard orderedSectionIDs.count == currentSections.count else {
            throw SectionEditError.sectionNotFound
        }

        let sectionsByID = Dictionary(uniqueKeysWithValues: currentSections.map { ($0.sectionID, $0) })
        var reordered: [SectionRevisionRecord] = []
        var seen: Set<UUID> = []
        for sectionID in orderedSectionIDs {
            guard seen.insert(sectionID).inserted, let record = sectionsByID[sectionID] else {
                throw SectionEditError.sectionNotFound
            }
            reordered.append(record)
        }

        if currentSections.map(\.sectionID) == orderedSectionIDs {
            return currentRevision
        }

        return try appendTalkRevision(
            to: presentation,
            previousRevision: currentRevision,
            orderedSections: reordered,
            changeSummary: "Reordered sections"
        )
    }

    @discardableResult
    func deleteSection(
        in presentation: PresentationRecord,
        sectionID: UUID
    ) throws -> TalkRevisionRecord {
        guard let currentRevision = currentTalkRevision(for: presentation) else {
            throw SectionEditError.presentationNotFound
        }

        let currentSections = orderedSections(in: currentRevision)
        guard currentSections.count > 1 else {
            throw SectionEditError.cannotDeleteLastSection
        }
        guard let target = currentSections.first(where: { $0.sectionID == sectionID }) else {
            throw SectionEditError.sectionNotFound
        }

        let remaining = currentSections.filter { $0.sectionID != sectionID }
        return try appendTalkRevision(
            to: presentation,
            previousRevision: currentRevision,
            orderedSections: remaining,
            changeSummary: "Removed \(target.title)"
        )
    }

    @discardableResult
    func renamePresentation(
        _ presentation: PresentationRecord,
        to newTitle: String
    ) throws -> TalkRevisionRecord {
        guard let currentRevision = currentTalkRevision(for: presentation) else {
            throw SectionEditError.presentationNotFound
        }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != presentation.title else {
            return currentRevision
        }

        presentation.title = trimmed
        return try appendTalkRevision(
            to: presentation,
            previousRevision: currentRevision,
            orderedSections: orderedSections(in: currentRevision),
            changeSummary: "Renamed presentation"
        )
    }

    func deletePresentation(_ presentation: PresentationRecord) throws {
        modelContext.delete(presentation)
        try modelContext.save()
    }
}

private extension PresentationStore {
    func makeSplitSections(
        base: SectionDraft,
        existing: SectionRevisionRecord,
        splitTexts: (String, String),
        nextSectionNumber: Int,
        timestamp: Date
    ) -> (SectionRevisionRecord, SectionRevisionRecord) {
        let (firstExact, secondExact) = partitionExactPhrase(
            base.exactPhrase,
            firstText: splitTexts.0,
            secondText: splitTexts.1
        )
        let nextTitle = "Section \(nextSectionNumber)"
        let firstDraft = SectionDraft(
            title: base.title,
            text: splitTexts.0,
            speaker: base.speaker,
            speakerRole: base.speakerRole,
            purpose: base.purpose,
            cueWords: base.cueWords,
            exactPhrase: firstExact,
            handoffCueOverride: base.handoffCueOverride
        )
        let secondDraft = SectionDraft(
            title: nextTitle,
            text: splitTexts.1,
            speaker: base.speaker,
            speakerRole: base.speakerRole,
            purpose: .general,
            cueWords: [],
            exactPhrase: secondExact,
            handoffCueOverride: nil
        )
        let first = makeSectionRevision(
            from: firstDraft,
            sectionID: existing.sectionID,
            fallbackTitle: existing.title,
            timestamp: timestamp,
            presentation: existing.presentation
        )
        let second = makeSectionRevision(
            from: secondDraft,
            sectionID: UUID(),
            fallbackTitle: nextTitle,
            timestamp: timestamp,
            presentation: existing.presentation
        )
        return (first, second)
    }

    func splitText(_ sourceText: String, at splitIndex: String.Index) throws -> (String, String) {
        guard splitIndex > sourceText.startIndex, splitIndex < sourceText.endIndex else {
            throw SectionEditError.invalidSplitPosition
        }
        let firstText = String(sourceText[..<splitIndex])
        let secondText = String(sourceText[splitIndex...])
        guard !firstText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !secondText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SectionEditError.invalidSplitPosition
        }
        return (firstText, secondText)
    }

    func partitionExactPhrase(
        _ phrase: String?,
        firstText: String,
        secondText: String
    ) -> (String?, String?) {
        guard let normalized = Self.normalizedOptionalText(phrase, preserveOuterSpaces: true) else {
            return (nil, nil)
        }
        if firstText.contains(normalized) {
            return (normalized, nil)
        }
        if secondText.contains(normalized) {
            return (nil, normalized)
        }
        return (nil, nil)
    }

    func makeSectionRevision(
        from draft: SectionDraft,
        sectionID: UUID,
        fallbackTitle: String,
        timestamp: Date,
        presentation: PresentationRecord?
    ) -> SectionRevisionRecord {
        let cleanedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSpeaker = draft.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCues = draft.cueWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return SectionRevisionRecord(
            sectionID: sectionID,
            title: cleanedTitle.isEmpty ? fallbackTitle : cleanedTitle,
            text: draft.text,
            speaker: cleanedSpeaker.isEmpty ? draft.speakerRole.displayName : cleanedSpeaker,
            speakerRole: draft.speakerRole,
            purpose: draft.purpose,
            cueWords: cleanedCues,
            exactPhrase: Self.normalizedOptionalText(draft.exactPhrase, preserveOuterSpaces: true),
            handoffCueOverride: Self.normalizedOptionalText(draft.handoffCueOverride),
            createdAt: timestamp,
            presentation: presentation
        )
    }

    func appendTalkRevision(
        to presentation: PresentationRecord,
        previousRevision: TalkRevisionRecord,
        orderedSections: [SectionRevisionRecord],
        changeSummary: String,
        timestamp: Date = Date()
    ) throws -> TalkRevisionRecord {
        let newRevision = TalkRevisionRecord(
            revisionNumber: previousRevision.revisionNumber + 1,
            title: presentation.title,
            changeSummary: changeSummary,
            createdAt: timestamp,
            presentation: presentation
        )
        modelContext.insert(newRevision)

        for (index, section) in orderedSections.enumerated() {
            let entry = TalkRevisionEntryRecord(
                orderIndex: index,
                sectionRevisionID: section.revisionID,
                talkRevision: newRevision,
                sectionRevision: section
            )
            newRevision.entries.append(entry)
            modelContext.insert(entry)
        }

        presentation.talkRevisions.append(newRevision)
        presentation.currentRevisionID = newRevision.id
        presentation.updatedAt = timestamp
        try modelContext.save()

        return newRevision
    }
}
