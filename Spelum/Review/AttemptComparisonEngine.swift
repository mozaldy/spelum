import Foundation

enum AttemptComparisonEngine {
    static func areDirectlyComparable(
        _ lhs: ComparableAttemptDescriptor,
        _ rhs: ComparableAttemptDescriptor
    ) -> Bool {
        guard lhs.id != rhs.id,
              lhs.presentationID == rhs.presentationID,
              lhs.attemptKind == rhs.attemptKind else {
            return false
        }
        switch lhs.attemptKind {
        case .section:
            return lhs.sectionID == rhs.sectionID && lhs.sectionRevisionID == rhs.sectionRevisionID
        case .fullRun:
            guard let lhsScope = lhs.fullRunScopeIdentifier,
                  let rhsScope = rhs.fullRunScopeIdentifier else {
                return false
            }
            return lhs.talkRevisionID == rhs.talkRevisionID && lhsScope == rhsScope
        }
    }

    static func classifyScope(
        earlier: ComparableAttemptDescriptor,
        later: ComparableAttemptDescriptor,
        currentTalkRevisionID: UUID?,
        currentSectionRevisionIDs: Set<UUID>
    ) -> AttemptComparisonScope {
        guard earlier.attemptKind == later.attemptKind else {
            return .mixedAttemptKinds
        }
        switch earlier.attemptKind {
        case .section:
            if earlier.sectionID == later.sectionID && earlier.sectionRevisionID == later.sectionRevisionID {
                let isOlder = later.isOlderRevision(
                    currentTalkRevisionID: currentTalkRevisionID,
                    currentSectionRevisionIDs: currentSectionRevisionIDs
                )
                return .sameSectionRevision(
                    sectionTitle: later.title,
                    talkRevisionNumber: later.talkRevisionNumber,
                    isOlderRevision: isOlder
                )
            }
            return .differentSectionRevisions(
                sameSection: earlier.sectionID == later.sectionID,
                leftTitle: earlier.title,
                rightTitle: later.title,
                leftRevisionNumber: earlier.talkRevisionNumber,
                rightRevisionNumber: later.talkRevisionNumber
            )

        case .fullRun:
            let sameRev = earlier.talkRevisionID == later.talkRevisionID
            let sameScope = earlier.fullRunScopeIdentifier != nil
                && earlier.fullRunScopeIdentifier == later.fullRunScopeIdentifier
            if sameRev && sameScope {
                let isOlder = later.isOlderRevision(
                    currentTalkRevisionID: currentTalkRevisionID,
                    currentSectionRevisionIDs: currentSectionRevisionIDs
                )
                return .sameFullRunRevisionAndScope(
                    scopeTitle: later.fullRunScopeTitle ?? later.title,
                    talkRevisionNumber: later.talkRevisionNumber,
                    isOlderRevision: isOlder
                )
            }
            return .differentFullRunScopeOrRevision(
                sameTalkRevision: sameRev,
                sameScope: sameScope,
                leftScopeTitle: earlier.fullRunScopeTitle ?? earlier.title,
                rightScopeTitle: later.fullRunScopeTitle ?? later.title,
                leftRevisionNumber: earlier.talkRevisionNumber,
                rightRevisionNumber: later.talkRevisionNumber
            )
        }
    }

    static func defaultComparablePair(
        from descriptors: [ComparableAttemptDescriptor],
        filter: AttemptHistoryFilter = .all,
        anchorAttemptID: UUID? = nil,
        currentTalkRevisionID: UUID? = nil,
        currentSectionRevisionIDs: Set<UUID> = []
    ) -> DefaultComparisonSelection? {
        let finalized = descriptors
            .filter { $0.status.isFinalized }
            .sorted(by: isNewerFirst)

        if let anchorAttemptID,
           let anchor = finalized.first(where: { $0.id == anchorAttemptID }) {
            let candidates = finalized.filter { $0.id != anchor.id && areDirectlyComparable(anchor, $0) }
            let preferredPartner = candidates.first(where: { $0.talkRevisionID == anchor.talkRevisionID })
                ?? candidates.first
            guard let partner = preferredPartner else { return nil }
            let ordered = orderChronologically(anchor, partner)
            let scope = classifyScope(
                earlier: ordered.earlier,
                later: ordered.later,
                currentTalkRevisionID: currentTalkRevisionID,
                currentSectionRevisionIDs: currentSectionRevisionIDs
            )
            return DefaultComparisonSelection(
                earlierID: ordered.earlier.id,
                laterID: ordered.later.id,
                scope: scope
            )
        }

        let filtered = finalized.filter { descriptor in
            switch filter {
            case .all: true
            case .fullRuns: descriptor.attemptKind == .fullRun
            case .sectionTakes: descriptor.attemptKind == .section
            }
        }

        for (index, newest) in filtered.enumerated() {
            let remaining = filtered.dropFirst(index + 1)
            let directMatches = remaining.filter { areDirectlyComparable(newest, $0) }
            if let partner = directMatches.first(where: { $0.talkRevisionID == newest.talkRevisionID })
                ?? directMatches.first {
                let ordered = orderChronologically(newest, partner)
                let scope = classifyScope(
                    earlier: ordered.earlier,
                    later: ordered.later,
                    currentTalkRevisionID: currentTalkRevisionID,
                    currentSectionRevisionIDs: currentSectionRevisionIDs
                )
                return DefaultComparisonSelection(
                    earlierID: ordered.earlier.id,
                    laterID: ordered.later.id,
                    scope: scope
                )
            }
        }
        return nil
    }

    static func buildSummary(
        first: ComparableAttemptDescriptor,
        second: ComparableAttemptDescriptor,
        currentTalkRevisionID: UUID?,
        currentSectionRevisionIDs: Set<UUID>
    ) -> AttemptComparisonSummary {
        let ordered = orderChronologically(first, second)
        let earlier = ordered.earlier
        let later = ordered.later
        let scope = classifyScope(
            earlier: earlier,
            later: later,
            currentTalkRevisionID: currentTalkRevisionID,
            currentSectionRevisionIDs: currentSectionRevisionIDs
        )
        let earlierOlder = earlier.isOlderRevision(
            currentTalkRevisionID: currentTalkRevisionID,
            currentSectionRevisionIDs: currentSectionRevisionIDs
        )
        let laterOlder = later.isOlderRevision(
            currentTalkRevisionID: currentTalkRevisionID,
            currentSectionRevisionIDs: currentSectionRevisionIDs
        )
        let wpmDelta: Double?
        if let earlierWPM = earlier.estimatedWordsPerMinute,
           let laterWPM = later.estimatedWordsPerMinute {
            wpmDelta = laterWPM - earlierWPM
        } else {
            wpmDelta = nil
        }

        let sectionRows = buildFullRunSectionRows(earlier: earlier, later: later)
        let completionNote = buildCompletionContextNote(earlier: earlier, later: later)

        return AttemptComparisonSummary(
            earlier: earlier,
            later: later,
            scope: scope,
            earlierIsOlderRevision: earlierOlder,
            laterIsOlderRevision: laterOlder,
            durationDelta: later.displayDuration - earlier.displayDuration,
            revealDelta: later.revealCount - earlier.revealCount,
            markerDelta: later.markerCount - earlier.markerCount,
            estimatedWPMDelta: wpmDelta,
            fullRunSectionRows: sectionRows,
            completionContextNote: completionNote
        )
    }
}

private extension AttemptComparisonEngine {
    static func isNewerFirst(
        _ lhs: ComparableAttemptDescriptor,
        _ rhs: ComparableAttemptDescriptor
    ) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    static func orderChronologically(
        _ lhs: ComparableAttemptDescriptor,
        _ rhs: ComparableAttemptDescriptor
    ) -> (earlier: ComparableAttemptDescriptor, later: ComparableAttemptDescriptor) {
        if lhs.startedAt < rhs.startedAt {
            return (lhs, rhs)
        }
        if lhs.startedAt > rhs.startedAt {
            return (rhs, lhs)
        }
        return lhs.id.uuidString <= rhs.id.uuidString ? (lhs, rhs) : (rhs, lhs)
    }

    static func buildFullRunSectionRows(
        earlier: ComparableAttemptDescriptor,
        later: ComparableAttemptDescriptor
    ) -> [FullRunSectionComparisonRow] {
        guard let earlierPayload = earlier.fullRunPayload,
              let laterPayload = later.fullRunPayload else {
            return []
        }

        let earlierByRev = Dictionary(
            earlierPayload.transitions.map { ($0.sectionRevisionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let earlierBySec = Dictionary(
            earlierPayload.transitions.map { ($0.sectionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let laterByRev = Dictionary(
            laterPayload.transitions.map { ($0.sectionRevisionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let laterBySec = Dictionary(
            laterPayload.transitions.map { ($0.sectionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var rows: [FullRunSectionComparisonRow] = []
        var seenSectionIDs: Set<UUID> = []

        for (index, section) in laterPayload.snapshot.sections.enumerated() {
            seenSectionIDs.insert(section.sectionID)
            let earlierT = earlierByRev[section.sectionRevisionID] ?? earlierBySec[section.sectionID]
            let laterT = laterByRev[section.sectionRevisionID] ?? laterBySec[section.sectionID]
            let speakerChanged = earlierT != nil && earlierT?.speaker != section.speaker
            rows.append(
                FullRunSectionComparisonRow(
                    id: "later-\(section.sectionID.uuidString)-\(index)",
                    displayOrderIndex: index,
                    sectionTitle: section.title,
                    speakerSummary: section.speakerSummary,
                    purpose: section.purpose,
                    earlierTransition: earlierT,
                    laterTransition: laterT,
                    speakerChanged: speakerChanged
                )
            )
        }

        for section in earlierPayload.snapshot.sections where !seenSectionIDs.contains(section.sectionID) {
            let earlierT = earlierByRev[section.sectionRevisionID] ?? earlierBySec[section.sectionID]
            rows.append(
                FullRunSectionComparisonRow(
                    id: "earlier-\(section.sectionID.uuidString)-\(rows.count)",
                    displayOrderIndex: rows.count,
                    sectionTitle: section.title,
                    speakerSummary: section.speakerSummary,
                    purpose: section.purpose,
                    earlierTransition: earlierT,
                    laterTransition: nil,
                    speakerChanged: false
                )
            )
        }

        return rows
    }

    static func buildCompletionContextNote(
        earlier: ComparableAttemptDescriptor,
        later: ComparableAttemptDescriptor
    ) -> String? {
        guard let earlierPayload = earlier.fullRunPayload,
              let laterPayload = later.fullRunPayload else {
            return nil
        }
        let earlierComplete = earlierPayload.completionKind == .completedAllSections
        let laterComplete = laterPayload.completionKind == .completedAllSections
        if earlierComplete && laterComplete {
            return nil
        }
        let leftSummary = earlierPayload.progressSummary(status: earlier.status)
        let rightSummary = laterPayload.progressSummary(status: later.status)
        return "Completion differs: Earlier run — \(leftSummary); Later run — \(rightSummary)."
    }
}
