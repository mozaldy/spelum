import Foundation
import SwiftData

extension PresentationStore {
    func resolvedDeckURL(for relativePath: String?) -> URL? {
        guard let relativePath else { return nil }
        return try? SlideDeckStorage.resolvedDeckURL(for: relativePath, storageRootURL: storageRootURL)
    }

    func collectDeckPaths(for presentation: PresentationRecord) -> Set<String> {
        var paths = Set(presentation.talkRevisions.compactMap(\.slideDeckRelativePath))
        for section in presentation.sectionRevisions {
            paths.formUnion(section.slideReferences.compactMap(\.deckRelativePath))
        }
        return paths
    }

    func removeUnreferencedDeckFiles(candidates: Set<String>) {
        guard !candidates.isEmpty else { return }
        let referenced = allReferencedDeckPathsInStore()
        for path in candidates where !referenced.contains(path) {
            SlideDeckStorage.removeDeckFile(relativePath: path, storageRootURL: storageRootURL)
        }
    }

    func persistImportedPresentation(
        text: String,
        title: String?,
        parsed: ParsedAnnotatedScript,
        copiedDeck: CopiedSlideDeck?
    ) throws -> PresentationRecord {
        try performAtomicWrite {
            let now = Date()
            let resolvedTitle = Self.resolvedTitle(explicit: title, fallbackText: text)
            let presentation = PresentationRecord(
                title: resolvedTitle,
                sourceText: text,
                createdAt: now,
                updatedAt: now
            )
            let changeSummary = copiedDeck == nil
                ? "Imported script"
                : "Imported script with slide deck"
            let initialRevision = TalkRevisionRecord(
                revisionNumber: 1,
                title: resolvedTitle,
                changeSummary: changeSummary,
                slideDeckRelativePath: copiedDeck?.relativePath,
                slideDeckPageCount: copiedDeck?.pageCount,
                createdAt: now,
                presentation: presentation
            )

            let sectionRecords = makeImportedSectionRecords(
                rawText: text,
                parsed: parsed,
                copiedDeck: copiedDeck,
                createdAt: now,
                presentation: presentation
            )

            modelContext.insert(presentation)
            modelContext.insert(initialRevision)
            for (index, section) in sectionRecords.enumerated() {
                let entry = TalkRevisionEntryRecord(
                    orderIndex: index,
                    sectionRevisionID: section.revisionID,
                    talkRevision: initialRevision,
                    sectionRevision: section
                )
                initialRevision.entries.append(entry)
                presentation.sectionRevisions.append(section)
                modelContext.insert(section)
                modelContext.insert(entry)
            }

            presentation.talkRevisions.append(initialRevision)
            presentation.currentRevisionID = initialRevision.id
            return presentation
        }
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
            slideDeckRelativePath: previousRevision.slideDeckRelativePath,
            slideDeckPageCount: previousRevision.slideDeckPageCount,
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

    func makeImportedSectionRecords(
        rawText: String,
        parsed: ParsedAnnotatedScript,
        copiedDeck: CopiedSlideDeck?,
        createdAt: Date,
        presentation: PresentationRecord
    ) -> [SectionRevisionRecord] {
        guard parsed.hasStructuredHeadings, !parsed.sections.isEmpty else {
            let single = SectionRevisionRecord(
                title: "Section 1",
                text: rawText,
                speaker: SpeakerRole.presenter.displayName,
                speakerRole: .presenter,
                purpose: .general,
                slideReferences: [],
                createdAt: createdAt,
                presentation: presentation
            )
            return [single]
        }

        var nextPDFPageIndex = 0
        return parsed.sections.map { parsedSection in
            let refs = buildImportedSlideReferences(
                for: parsedSection,
                copiedDeck: copiedDeck,
                nextPDFPageIndex: &nextPDFPageIndex
            )
            return SectionRevisionRecord(
                title: parsedSection.title,
                text: parsedSection.rawText,
                speaker: SpeakerRole.presenter.displayName,
                speakerRole: .presenter,
                purpose: .general,
                slideReferences: refs,
                createdAt: createdAt,
                presentation: presentation
            )
        }
    }

    static func reconcileSlideReferences(
        existing: [SectionSlideReference],
        editedText: String,
        sectionTitle: String
    ) -> [SectionSlideReference] {
        let parsed = AnnotatedScriptParser.parseSection(editedText, sectionTitle: sectionTitle)
        let explicitSlides = parsed.slides.filter(\.isExplicitSlide)
        guard !explicitSlides.isEmpty else {
            return existing.count == 1 ? existing : []
        }
        guard !existing.isEmpty else {
            return explicitSlides.enumerated().map { index, slide in
                SectionSlideReference(slideOrderIndex: index, headingTitle: slide.displayTitle)
            }
        }
        if explicitSlides.count == existing.count {
            return zip(explicitSlides.indices, explicitSlides).map { index, slide in
                let old = existing[index]
                return SectionSlideReference(
                    id: old.id,
                    slideOrderIndex: index,
                    headingTitle: slide.displayTitle,
                    deckRelativePath: old.deckRelativePath,
                    pdfPageIndex: old.pdfPageIndex,
                    pageAspectRatio: old.pageAspectRatio
                )
            }
        }

        var unused = existing
        return explicitSlides.enumerated().map { index, slide in
            let normalized = slide.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let matchIdx = unused.firstIndex(where: {
                $0.headingTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
            }) {
                let matched = unused.remove(at: matchIdx)
                return SectionSlideReference(
                    id: matched.id,
                    slideOrderIndex: index,
                    headingTitle: slide.displayTitle,
                    deckRelativePath: matched.deckRelativePath,
                    pdfPageIndex: matched.pdfPageIndex,
                    pageAspectRatio: matched.pageAspectRatio
                )
            }
            return SectionSlideReference(slideOrderIndex: index, headingTitle: slide.displayTitle)
        }
    }

    static func partitionSlideReferences(
        _ existing: [SectionSlideReference],
        firstText: String,
        secondText: String,
        firstTitle: String,
        secondTitle: String
    ) -> ([SectionSlideReference], [SectionSlideReference]) {
        guard !existing.isEmpty else { return ([], []) }
        let firstExplicit = AnnotatedScriptParser.parseSection(firstText, sectionTitle: firstTitle)
            .slides.filter(\.isExplicitSlide)
        let secondExplicit = AnnotatedScriptParser.parseSection(secondText, sectionTitle: secondTitle)
            .slides.filter(\.isExplicitSlide)

        let splitPoint = min(firstExplicit.count, existing.count)
        let firstRaw = Array(existing.prefix(splitPoint))
        let secondRaw = Array(existing.dropFirst(splitPoint))

        let firstRefs = reconcileSlideReferences(
            existing: firstRaw,
            editedText: firstText,
            sectionTitle: firstTitle
        )
        if secondExplicit.isEmpty, secondRaw.isEmpty, let inherited = firstRefs.last, inherited.pdfPageIndex != nil {
            let carried = SectionSlideReference(
                slideOrderIndex: 0,
                headingTitle: secondTitle,
                deckRelativePath: inherited.deckRelativePath,
                pdfPageIndex: inherited.pdfPageIndex,
                pageAspectRatio: inherited.pageAspectRatio
            )
            return (firstRefs, [carried])
        }
        let secondRefs = reconcileSlideReferences(
            existing: secondRaw,
            editedText: secondText,
            sectionTitle: secondTitle
        )
        return (firstRefs, secondRefs)
    }

    private func buildImportedSlideReferences(
        for parsedSection: ParsedScriptSection,
        copiedDeck: CopiedSlideDeck?,
        nextPDFPageIndex: inout Int
    ) -> [SectionSlideReference] {
        var refs: [SectionSlideReference] = []
        var explicitOrderIndex = 0
        for slide in parsedSection.slides where slide.isExplicitSlide {
            let pageIndex: Int?
            let aspectRatio: Double?
            if let copiedDeck, nextPDFPageIndex < copiedDeck.pageCount {
                pageIndex = nextPDFPageIndex
                aspectRatio = nextPDFPageIndex < copiedDeck.pageAspectRatios.count
                    ? copiedDeck.pageAspectRatios[nextPDFPageIndex]
                    : nil
                nextPDFPageIndex += 1
            } else {
                pageIndex = nil
                aspectRatio = nil
            }
            refs.append(
                SectionSlideReference(
                    slideOrderIndex: explicitOrderIndex,
                    headingTitle: slide.displayTitle,
                    deckRelativePath: pageIndex == nil ? nil : copiedDeck?.relativePath,
                    pdfPageIndex: pageIndex,
                    pageAspectRatio: aspectRatio
                )
            )
            explicitOrderIndex += 1
        }
        return refs
    }

    private func allReferencedDeckPathsInStore() -> Set<String> {
        var referenced = referencedDeckPathsFromTalkRevisions()
        referenced.formUnion(referencedDeckPathsFromSectionRevisions())
        referenced.formUnion(referencedDeckPathsFromAttempts())
        return referenced
    }

    private func referencedDeckPathsFromTalkRevisions() -> Set<String> {
        let revisions = (try? modelContext.fetch(FetchDescriptor<TalkRevisionRecord>())) ?? []
        return Set(revisions.compactMap(\.slideDeckRelativePath))
    }

    private func referencedDeckPathsFromSectionRevisions() -> Set<String> {
        let sections = (try? modelContext.fetch(FetchDescriptor<SectionRevisionRecord>())) ?? []
        return Set(sections.flatMap { $0.slideReferences.compactMap(\.deckRelativePath) })
    }

    private func referencedDeckPathsFromAttempts() -> Set<String> {
        let attempts = (try? modelContext.fetch(FetchDescriptor<AttemptRecord>())) ?? []
        let paths = attempts
            .compactMap(\.fullRunPayload)
            .flatMap(\.snapshot.sections)
            .flatMap { $0.slideReferences ?? [] }
            .compactMap(\.deckRelativePath)
        return Set(paths)
    }
}
