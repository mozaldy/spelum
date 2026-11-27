import Foundation

enum FullRunTimelineNormalizer {
    static func normalize(
        payload: FullRunAttemptPayload,
        finalDuration: TimeInterval,
        interrupted: Bool,
        isSilentRecall: Bool
    ) -> FullRunAttemptPayload {
        let safeFinalDuration = finalDuration.isFinite ? max(0, finalDuration) : 0
        let plannedCount = payload.snapshot.sections.count
        let sourceTransitions = orderedSourceTransitions(for: payload, safeFinalDuration: safeFinalDuration)
        let normalizedTransitions = buildNormalizedTransitions(
            from: sourceTransitions,
            safeFinalDuration: safeFinalDuration
        )

        let reachedCount = min(normalizedTransitions.count, plannedCount)
        let completionKind: FullRunCompletionKind
        if interrupted || (!isSilentRecall && safeFinalDuration <= 0) {
            completionKind = .interrupted
        } else if reachedCount < plannedCount {
            completionKind = .finishedEarly
        } else {
            completionKind = .completedAllSections
        }

        return FullRunAttemptPayload(
            snapshot: payload.snapshot,
            transitions: normalizedTransitions,
            completionKind: completionKind,
            reachedSectionCount: reachedCount
        )
    }

    private static func orderedSourceTransitions(
        for payload: FullRunAttemptPayload,
        safeFinalDuration: TimeInterval
    ) -> [FullRunSectionTransition] {
        let orderedInput = payload.transitions.sorted { lhs, rhs in
            if lhs.runIndex != rhs.runIndex {
                return lhs.runIndex < rhs.runIndex
            }
            return lhs.recordedAt < rhs.recordedAt
        }

        if orderedInput.isEmpty, let first = payload.snapshot.sections.first {
            return [
                FullRunSectionTransition(
                    runIndex: first.runIndex,
                    talkSectionIndex: first.talkSectionIndex,
                    sectionID: first.sectionID,
                    sectionRevisionID: first.sectionRevisionID,
                    sectionTitle: first.title,
                    speaker: first.speaker,
                    speakerRole: first.speakerRole,
                    purpose: first.purpose,
                    startTime: 0,
                    endTime: safeFinalDuration
                )
            ]
        }
        return orderedInput
    }

    private static func buildNormalizedTransitions(
        from sourceTransitions: [FullRunSectionTransition],
        safeFinalDuration: TimeInterval
    ) -> [FullRunSectionTransition] {
        var monotonicStarts: [TimeInterval] = []
        monotonicStarts.reserveCapacity(sourceTransitions.count)
        var floorTime: TimeInterval = 0
        for (index, transition) in sourceTransitions.enumerated() {
            let rawStart = index == 0
                ? 0
                : (transition.startTime.isFinite ? max(0, transition.startTime) : floorTime)
            let clampedStart = safeFinalDuration > 0 ? min(rawStart, safeFinalDuration) : rawStart
            let monotonicStart = max(floorTime, clampedStart)
            monotonicStarts.append(monotonicStart)
            floorTime = monotonicStart
        }

        let effectiveEnd = max(safeFinalDuration, monotonicStarts.last ?? 0)
        return sourceTransitions.enumerated().map { index, transition in
            let start = monotonicStarts[index]
            let end = (index + 1 < monotonicStarts.count)
                ? max(start, monotonicStarts[index + 1])
                : max(start, effectiveEnd)
            return FullRunSectionTransition(
                id: transition.id,
                runIndex: transition.runIndex,
                talkSectionIndex: transition.talkSectionIndex,
                sectionID: transition.sectionID,
                sectionRevisionID: transition.sectionRevisionID,
                sectionTitle: transition.sectionTitle,
                speaker: transition.speaker,
                speakerRole: transition.speakerRole,
                purpose: transition.purpose,
                startTime: start,
                endTime: end,
                recordedAt: transition.recordedAt
            )
        }
    }
}

extension PresentationStore {
    func defaultPresenterHandoffSection(in talkRevision: TalkRevisionRecord) -> SectionRevisionRecord? {
        let ordered = orderedSections(in: talkRevision)
        guard ordered.count > 1 else { return nil }

        for index in 1 ..< ordered.count {
            let section = ordered[index]
            if section.speakerRole == .presenter,
               let handoff = handoffContext(forSectionID: section.sectionID, in: talkRevision),
               handoff.isSpeakerChange {
                return section
            }
        }
        if let firstPresenterAfterOpening = ordered.dropFirst().first(where: { $0.speakerRole == .presenter }) {
            return firstPresenterAfterOpening
        }
        return ordered[1]
    }

    func handoffStartCandidates(in talkRevision: TalkRevisionRecord) -> [SectionRevisionRecord] {
        let ordered = orderedSections(in: talkRevision)
        guard ordered.count > 1 else { return [] }
        return Array(ordered.dropFirst())
    }

    func makeFullRunSnapshot(
        for presentation: PresentationRecord,
        talkRevision: TalkRevisionRecord,
        startKind: FullRunStartKind,
        startingSectionID: UUID? = nil
    ) -> FullRunSnapshot? {
        let ordered = orderedSections(in: talkRevision)
        guard !ordered.isEmpty else { return nil }

        let resolvedStartKind: FullRunStartKind
        let startIndex: Int

        if startKind == .fromHandoff && ordered.count > 1 {
            resolvedStartKind = .fromHandoff
            if let startingSectionID,
               let matchedIndex = ordered.firstIndex(where: { $0.sectionID == startingSectionID }),
               matchedIndex > 0 {
                startIndex = matchedIndex
            } else if let defaultSection = defaultPresenterHandoffSection(in: talkRevision),
                      let matchedIndex = ordered.firstIndex(where: { $0.sectionID == defaultSection.sectionID }) {
                startIndex = matchedIndex
            } else {
                startIndex = 1
            }
        } else {
            resolvedStartKind = .entireTalk
            startIndex = 0
        }

        let sliced = Array(ordered[startIndex...])
        let snapshots = sliced.enumerated().map { offset, section in
            let handoff = handoffContext(forSectionID: section.sectionID, in: talkRevision)
            return FullRunSectionSnapshot(
                runIndex: offset,
                talkSectionIndex: startIndex + offset,
                sectionID: section.sectionID,
                sectionRevisionID: section.revisionID,
                title: section.title,
                text: section.text,
                speaker: section.speaker,
                speakerRole: section.speakerRole,
                purpose: section.purpose,
                cueWords: section.cueWords,
                exactPhrase: section.exactPhrase,
                handoffCueText: handoff?.effectiveCueText,
                handoffPrecedingSpeaker: handoff?.precedingSpeaker,
                handoffPrecedingSectionTitle: handoff?.precedingSectionTitle,
                handoffIsSpeakerChange: handoff?.isSpeakerChange ?? false,
                slideReferences: section.slideReferences.isEmpty ? nil : section.slideReferences
            )
        }

        return FullRunSnapshot(
            presentationID: presentation.id,
            presentationTitle: presentation.title,
            talkRevisionID: talkRevision.id,
            talkRevisionNumber: talkRevision.revisionNumber,
            startKind: resolvedStartKind,
            startingTalkSectionIndex: startIndex,
            totalTalkSectionCount: ordered.count,
            sections: snapshots
        )
    }
}
