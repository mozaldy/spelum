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
        let origin: HandoffTransitionOrigin = targetIndex == 0
            ? .opening
            : .fromSection(sections[targetIndex - 1].sectionID)

        return try performAtomicWrite {
            let now = Date()
            let newSectionRevision = makeSectionRevision(
                from: draft,
                sectionID: existing.sectionID,
                fallbackTitle: existing.title,
                handoffOrigin: origin,
                timestamp: now,
                presentation: presentation
            )

            var updatedSections = sections
            updatedSections[targetIndex] = newSectionRevision
            presentation.sectionRevisions.append(newSectionRevision)
            modelContext.insert(newSectionRevision)

            return appendTalkRevision(
                to: presentation,
                previousRevision: currentRevision,
                orderedSections: updatedSections,
                changeSummary: changeSummary,
                timestamp: now
            )
        }
    }

    @discardableResult
    func splitSection(
        in presentation: PresentationRecord,
        sectionID: UUID,
        at splitIndex: String.Index,
        pendingDraft: SectionDraft? = nil,
        exactPhrasePolicy: ExactPhraseSplitPolicy = .protect
    ) throws -> SectionSplitResult {
        guard let currentRevision = currentTalkRevision(for: presentation) else {
            throw SectionEditError.presentationNotFound
        }
        let sections = orderedSections(in: currentRevision)
        guard let targetIndex = sections.firstIndex(where: { $0.sectionID == sectionID }) else {
            throw SectionEditError.sectionNotFound
        }

        let existing = sections[targetIndex]
        let base = resolvedBaseDraft(pendingDraft: pendingDraft, existing: existing, in: currentRevision)
        let splitTexts = try splitText(base.text, at: splitIndex)
        let exactPhrases = try Self.partitionExactPhrase(
            base.exactPhrase,
            in: base.text,
            at: splitIndex,
            policy: exactPhrasePolicy
        )
        let firstOrigin: HandoffTransitionOrigin = targetIndex == 0
            ? .opening
            : .fromSection(sections[targetIndex - 1].sectionID)

        return try performAtomicWrite {
            let now = Date()
            let (firstSection, secondSection) = makeSplitSections(
                base: base,
                existing: existing,
                splitTexts: splitTexts,
                exactPhrases: exactPhrases,
                firstOrigin: firstOrigin,
                nextSectionNumber: sections.count + 1,
                timestamp: now,
                presentation: presentation
            )
            var updatedSections = sections
            updatedSections.replaceSubrange(targetIndex ... targetIndex, with: [firstSection, secondSection])
            presentation.sectionRevisions.append(contentsOf: [firstSection, secondSection])
            modelContext.insert(firstSection)
            modelContext.insert(secondSection)

            rebindFollowerHandoffIfNeeded(
                in: &updatedSections,
                followerIndex: targetIndex + 2,
                oldPredecessorID: existing.sectionID,
                newPredecessorID: secondSection.sectionID,
                previousRevision: currentRevision,
                presentation: presentation,
                timestamp: now
            )
            let newRevision = appendTalkRevision(
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

        return try performAtomicWrite {
            let now = Date()
            let reconciled = reconcileHandoffOverrides(
                for: reordered,
                previousRevision: currentRevision,
                presentation: presentation,
                timestamp: now
            )
            return appendTalkRevision(
                to: presentation,
                previousRevision: currentRevision,
                orderedSections: reconciled,
                changeSummary: "Reordered sections",
                timestamp: now
            )
        }
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
        return try performAtomicWrite {
            let now = Date()
            let reconciled = reconcileHandoffOverrides(
                for: remaining,
                previousRevision: currentRevision,
                presentation: presentation,
                timestamp: now
            )
            return appendTalkRevision(
                to: presentation,
                previousRevision: currentRevision,
                orderedSections: reconciled,
                changeSummary: "Removed \(target.title)",
                timestamp: now
            )
        }
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

        return try performAtomicWrite {
            presentation.title = trimmed
            return appendTalkRevision(
                to: presentation,
                previousRevision: currentRevision,
                orderedSections: orderedSections(in: currentRevision),
                changeSummary: "Renamed presentation"
            )
        }
    }

    func deletePresentation(_ presentation: PresentationRecord) throws {
        let presentationID = presentation.id
        try performAtomicWrite {
            try CoachingStore(modelContext: modelContext).deleteCues(forPresentationID: presentationID)
            modelContext.delete(presentation)
        }
    }
}

private extension PresentationStore {
    func resolvedBaseDraft(
        pendingDraft: SectionDraft?,
        existing: SectionRevisionRecord,
        in talkRevision: TalkRevisionRecord
    ) -> SectionDraft {
        if let pendingDraft {
            return pendingDraft
        }
        var draft = SectionDraft(record: existing)
        draft.handoffCueOverride = handoffContext(forSectionID: existing.sectionID, in: talkRevision)?.customCue
        return draft
    }

    // swiftlint:disable:next function_parameter_count
    func makeSplitSections(
        base: SectionDraft,
        existing: SectionRevisionRecord,
        splitTexts: (String, String),
        exactPhrases: (String?, String?),
        firstOrigin: HandoffTransitionOrigin,
        nextSectionNumber: Int,
        timestamp: Date,
        presentation: PresentationRecord
    ) -> (SectionRevisionRecord, SectionRevisionRecord) {
        let (firstCues, secondCues) = Self.partitionCueWords(
            base.cueWords,
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
            cueWords: firstCues,
            exactPhrase: exactPhrases.0,
            handoffCueOverride: base.handoffCueOverride
        )
        let secondDraft = SectionDraft(
            title: nextTitle,
            text: splitTexts.1,
            speaker: base.speaker,
            speakerRole: base.speakerRole,
            purpose: .general,
            cueWords: secondCues,
            exactPhrase: exactPhrases.1,
            handoffCueOverride: nil
        )
        let first = makeSectionRevision(
            from: firstDraft,
            sectionID: existing.sectionID,
            fallbackTitle: existing.title,
            handoffOrigin: firstOrigin,
            timestamp: timestamp,
            presentation: presentation
        )
        let second = makeSectionRevision(
            from: secondDraft,
            sectionID: UUID(),
            fallbackTitle: nextTitle,
            handoffOrigin: .fromSection(first.sectionID),
            timestamp: timestamp,
            presentation: presentation
        )
        return (first, second)
    }

    func splitText(_ sourceText: String, at splitIndex: String.Index) throws -> (String, String) {
        guard Self.isValidSplitIndex(splitIndex, in: sourceText) else {
            throw SectionEditError.invalidSplitPosition
        }
        return (String(sourceText[..<splitIndex]), String(sourceText[splitIndex...]))
    }

    // swiftlint:disable:next function_parameter_count
    func makeSectionRevision(
        from draft: SectionDraft,
        sectionID: UUID,
        fallbackTitle: String,
        handoffOrigin: HandoffTransitionOrigin,
        timestamp: Date,
        presentation: PresentationRecord?
    ) -> SectionRevisionRecord {
        let cleanedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSpeaker = draft.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCues = draft.cueWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedOverride = Self.normalizedOptionalText(draft.handoffCueOverride)

        let sourceSectionID: UUID?
        let isOpening: Bool?
        if normalizedOverride != nil {
            switch handoffOrigin {
            case .opening:
                sourceSectionID = nil
                isOpening = true
            case .fromSection(let precedingID):
                sourceSectionID = precedingID
                isOpening = false
            }
        } else {
            sourceSectionID = nil
            isOpening = nil
        }

        return SectionRevisionRecord(
            sectionID: sectionID,
            title: cleanedTitle.isEmpty ? fallbackTitle : cleanedTitle,
            text: draft.text,
            speaker: cleanedSpeaker.isEmpty ? draft.speakerRole.displayName : cleanedSpeaker,
            speakerRole: draft.speakerRole,
            purpose: draft.purpose,
            cueWords: cleanedCues,
            exactPhrase: Self.normalizedOptionalText(draft.exactPhrase, preserveOuterSpaces: true),
            handoffCueOverride: normalizedOverride,
            handoffCueSourceSectionID: sourceSectionID,
            handoffCueIsOpening: isOpening,
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
    ) -> TalkRevisionRecord {
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
        return newRevision
    }
}
