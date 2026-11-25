import SwiftData
import SwiftUI

extension ScriptEditor {
    var store: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    var orderedSections: [SectionRevisionRecord] {
        store.orderedSections(for: presentation)
    }

    var currentSectionIndex: Int? {
        orderedSections.firstIndex { $0.sectionID == sectionID }
    }

    var currentSection: SectionRevisionRecord? {
        guard let index = currentSectionIndex else { return nil }
        return orderedSections[index]
    }

    var handoffContext: HandoffContext? {
        store.handoffContext(forSectionID: sectionID, in: presentation)
    }

    var currentTalkRevisionNumber: Int {
        store.currentTalkRevision(for: presentation)?.revisionNumber ?? 1
    }

    var previousSectionID: UUID? {
        guard let index = currentSectionIndex, index > 0 else { return nil }
        return orderedSections[index - 1].sectionID
    }

    var nextSectionID: UUID? {
        guard let index = currentSectionIndex, index + 1 < orderedSections.count else { return nil }
        return orderedSections[index + 1].sectionID
    }

    var isSectionTextValid: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasUnsavedChanges: Bool {
        guard let currentSection else { return false }
        return normalizedDraft != normalizedBaseline(SectionDraft(record: currentSection))
    }

    var normalizedDraft: SectionDraft {
        let trimmedHandoff = draftHandoffCue.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedLine = handoffContext?.derivedFinalLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let handoffOverride = (trimmedHandoff.isEmpty || trimmedHandoff == derivedLine) ? nil : trimmedHandoff
        let exactPhrase = draftExactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : draftExactPhrase
        let cleanedCues = CueWordListHelper.cleanedCueWords(
            from: draftCueWords,
            pendingNewWord: newCueWord
        )

        return SectionDraft(
            title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            text: draftText,
            speaker: draftSpeaker.trimmingCharacters(in: .whitespacesAndNewlines),
            speakerRole: draftSpeakerRole,
            purpose: draftPurpose,
            cueWords: cleanedCues,
            exactPhrase: exactPhrase,
            handoffCueOverride: handoffOverride
        )
    }

    var cursorSplitIndex: String.Index? {
        guard let range = selectedRange else { return nil }
        let candidate = range.lowerBound
        return PresentationStore.isValidSplitIndex(candidate, in: draftText) ? candidate : nil
    }

    var selectedNonEmptyText: String? {
        guard let range = selectedRange,
              range.lowerBound < range.upperBound,
              range.upperBound <= draftText.endIndex else {
            return nil
        }
        let substring = String(draftText[range])
        return substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : substring
    }

    var selectedRange: Range<String.Index>? {
        guard let selection = textSelection else { return nil }
        switch selection.indices {
        case .selection(let range): return range
        case .multiSelection(let rangeSet): return rangeSet.ranges.first
        @unknown default: return nil
        }
    }

    @ViewBuilder
    var unsavedExitDialogActions: some View {
        let isBack = pendingExit == .back
        if isSectionTextValid {
            Button(isBack ? "Save Revision & Leave" : "Save Revision & Continue") {
                if let exit = pendingExit {
                    pendingExit = nil
                    if saveRevision() {
                        completeExit(exit)
                    }
                }
            }
        }
        Button(isBack ? "Discard Edits & Leave" : "Discard Edits & Continue", role: .destructive) {
            if let exit = pendingExit {
                pendingExit = nil
                completeExit(exit)
            }
        }
        Button("Keep Editing", role: .cancel) { pendingExit = nil }
    }

    @ViewBuilder
    var unsavedExitDialogMessage: some View {
        if isSectionTextValid {
            Text("Save a new revision before leaving, or discard your unsaved edits.")
        } else {
            Text("Section text cannot be empty. Keep editing to add text, or discard your edits.")
        }
    }

    @ViewBuilder
    var exactPhraseSplitDialogActions: some View {
        if let pending = pendingExactPhraseSplit {
            if let beforeIndex = pending.conflict.beforePhraseSplitIndex {
                Button("Split Before Exact Phrase") {
                    pendingExactPhraseSplit = nil
                    performSplit(at: beforeIndex)
                }
            }
            if let afterIndex = pending.conflict.afterPhraseSplitIndex {
                Button("Split After Exact Phrase") {
                    pendingExactPhraseSplit = nil
                    performSplit(at: afterIndex)
                }
            }
            Button("Split Here & Clear Exact Phrase", role: .destructive) {
                pendingExactPhraseSplit = nil
                performSplit(at: pending.requestedIndex, exactPhrasePolicy: .clearExactPhrase)
            }
            Button("Cancel", role: .cancel) { pendingExactPhraseSplit = nil }
        }
    }

    @ViewBuilder
    var exactPhraseSplitDialogMessage: some View {
        if let pending = pendingExactPhraseSplit {
            Text(
                "This split divides “\(pending.conflict.phrase)”. " +
                "Choose a boundary that keeps your exact phrase intact, or clear it."
            )
        }
    }

    func loadDraftIfNeeded(force: Bool) {
        guard let record = currentSection else { return }
        let talkRevID = presentation.currentRevisionID
        guard force || loadedRevisionID != record.revisionID || loadedTalkRevisionID != talkRevID else {
            return
        }
        loadedRevisionID = record.revisionID
        loadedTalkRevisionID = talkRevID
        draftTitle = record.title
        draftText = record.text
        draftSpeaker = record.speaker
        draftSpeakerRole = record.speakerRole
        draftPurpose = record.purpose
        draftCueWords = record.cueWords.map { EditableCueWord(text: $0) }
        newCueWord = ""
        draftExactPhrase = record.exactPhrase ?? ""
        draftHandoffCue = handoffContext?.effectiveCueText ?? ""
        textSelection = nil
        errorMessage = nil
    }

    func normalizedBaseline(_ baseline: SectionDraft) -> SectionDraft {
        SectionDraft(
            title: baseline.title.trimmingCharacters(in: .whitespacesAndNewlines),
            text: baseline.text,
            speaker: baseline.speaker.trimmingCharacters(in: .whitespacesAndNewlines),
            speakerRole: baseline.speakerRole,
            purpose: baseline.purpose,
            cueWords: baseline.cueWords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            exactPhrase: baseline.exactPhrase,
            handoffCueOverride: handoffContext?.customCue?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult
    func saveRevision() -> Bool {
        errorMessage = nil
        statusBanner = nil
        do {
            let revision = try store.saveSectionEdit(
                in: presentation,
                sectionID: sectionID,
                draft: normalizedDraft
            )
            loadDraftIfNeeded(force: true)
            statusBanner = "Saved Revision \(revision.revisionNumber)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func handlePendingLineSplit() {
        guard let splitIndex = pendingLineSplitIndex else { return }
        pendingLineSplitIndex = nil
        requestSplit(at: splitIndex)
    }

    func requestSplit(at splitIndex: String.Index) {
        errorMessage = nil
        statusBanner = nil
        if let conflict = PresentationStore.exactPhraseSplitConflict(
            in: draftText,
            exactPhrase: normalizedDraft.exactPhrase,
            at: splitIndex
        ) {
            pendingExactPhraseSplit = PendingExactPhraseSplit(
                requestedIndex: splitIndex,
                conflict: conflict
            )
            return
        }
        performSplit(at: splitIndex)
    }

    func performSplit(
        at splitIndex: String.Index,
        exactPhrasePolicy: ExactPhraseSplitPolicy = .protect
    ) {
        errorMessage = nil
        statusBanner = nil
        let hadExactPhrase = normalizedDraft.exactPhrase != nil
        do {
            let result = try store.splitSection(
                in: presentation,
                sectionID: sectionID,
                at: splitIndex,
                pendingDraft: normalizedDraft,
                exactPhrasePolicy: exactPhrasePolicy
            )
            loadDraftIfNeeded(force: true)
            statusBanner = splitStatusMessage(for: result, hadExactPhrase: hadExactPhrase)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func splitStatusMessage(for result: SectionSplitResult, hadExactPhrase: Bool) -> String {
        let firstTitle = result.firstSection.title
        let secondTitle = result.secondSection.title
        var parts = [
            "Split into “\(firstTitle)” and “\(secondTitle)” (Revision \(result.talkRevision.revisionNumber))."
        ]

        let firstCues = result.firstSection.cueWords.count
        let secondCues = result.secondSection.cueWords.count
        if firstCues > 0 && secondCues > 0 {
            parts.append("Placed \(firstCues) cue(s) on “\(firstTitle)” and \(secondCues) on “\(secondTitle)”.")
        } else if secondCues > 0 {
            parts.append("Moved \(secondCues) cue(s) to “\(secondTitle)”.")
        } else if firstCues > 0 {
            parts.append("Kept \(firstCues) cue(s) on “\(firstTitle)”.")
        }

        if hadExactPhrase {
            if result.firstSection.exactPhrase != nil {
                parts.append("Exact phrase kept on “\(firstTitle)”.")
            } else if result.secondSection.exactPhrase != nil {
                parts.append("Exact phrase kept on “\(secondTitle)”.")
            } else {
                parts.append("Exact phrase cleared.")
            }
        }
        return parts.joined(separator: " ")
    }

    func requestNavigation(to targetSectionID: UUID) {
        if hasUnsavedChanges {
            pendingExit = .section(targetSectionID)
        } else {
            onNavigateToSection(targetSectionID)
        }
    }

    func completeExit(_ exit: PendingEditorExit) {
        switch exit {
        case .back:
            dismiss()
        case .section(let targetID):
            onNavigateToSection(targetID)
        }
    }

    func previewHandoffContext(from base: HandoffContext) -> HandoffContext {
        let draftOverride = normalizedDraft.handoffCueOverride
        return HandoffContext(
            sectionID: base.sectionID,
            sectionIndex: base.sectionIndex,
            precedingSectionID: base.precedingSectionID,
            precedingSectionTitle: base.precedingSectionTitle,
            precedingSpeaker: base.precedingSpeaker,
            precedingSpeakerRole: base.precedingSpeakerRole,
            derivedFinalLine: base.derivedFinalLine,
            customCue: draftOverride,
            effectiveCueText: draftOverride ?? base.derivedFinalLine,
            isCustomCue: draftOverride != nil,
            isFirstSection: base.isFirstSection,
            isSpeakerChange: base.isSpeakerChange,
            isSingleSpeakerTalk: base.isSingleSpeakerTalk
        )
    }
}
