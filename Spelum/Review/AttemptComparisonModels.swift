import Foundation

enum AttemptHistoryFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case fullRuns
    case sectionTakes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All"
        case .fullRuns: "Full Runs"
        case .sectionTakes: "Sections"
        }
    }

    func includes(_ attempt: AttemptRecord) -> Bool {
        switch self {
        case .all: true
        case .fullRuns: attempt.isFullRun
        case .sectionTakes: !attempt.isFullRun
        }
    }
}

struct ComparableAttemptDescriptor: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let presentationID: UUID
    let talkRevisionID: UUID
    let talkRevisionNumber: Int
    let sectionID: UUID
    let sectionRevisionID: UUID
    let title: String
    let startedAt: Date
    let practiceMode: PracticeMode
    let status: AttemptStatus
    let attemptKind: AttemptKind
    let hasPlayableAudio: Bool
    let isSilentRecall: Bool
    let displayDuration: TimeInterval
    let revealCount: Int
    let markerCount: Int
    let estimatedWordsPerMinute: Double?
    let observationCount: Int?
    let fullRunPayload: FullRunAttemptPayload?

    init(record: AttemptRecord) {
        self.id = record.id
        self.presentationID = record.presentationID
        self.talkRevisionID = record.talkRevisionID
        self.talkRevisionNumber = record.talkRevisionNumber
        self.sectionID = record.sectionID
        self.sectionRevisionID = record.sectionRevisionID
        self.title = record.displayTitle
        self.startedAt = record.startedAt
        self.practiceMode = record.practiceMode
        self.status = record.status
        self.attemptKind = record.attemptKind
        self.hasPlayableAudio = record.hasPlayableAudio
        self.isSilentRecall = record.isSilentRecall
        self.displayDuration = record.displayDuration
        self.revealCount = record.revealCount
        self.markerCount = record.markers.count
        if let analysis = record.timingAnalysis, analysis.outcome == .completed {
            self.estimatedWordsPerMinute = analysis.estimatedWordsPerMinute
            self.observationCount = analysis.observations.count
        } else {
            self.estimatedWordsPerMinute = nil
            self.observationCount = nil
        }
        self.fullRunPayload = record.fullRunPayload
    }

    var fullRunScopeIdentifier: String? {
        fullRunPayload?.snapshot.scopeIdentifier
    }

    var fullRunScopeTitle: String? {
        fullRunPayload?.snapshot.scopeTitle
    }

    func isOlderRevision(
        currentTalkRevisionID: UUID?,
        currentSectionRevisionIDs: Set<UUID>
    ) -> Bool {
        switch attemptKind {
        case .fullRun:
            guard let currentTalkRevisionID else { return false }
            return talkRevisionID != currentTalkRevisionID
        case .section:
            if !currentSectionRevisionIDs.isEmpty {
                return !currentSectionRevisionIDs.contains(sectionRevisionID)
            }
            guard let currentTalkRevisionID else { return false }
            return talkRevisionID != currentTalkRevisionID
        }
    }
}

enum AttemptComparisonScope: Equatable, Sendable {
    case sameSectionRevision(
        sectionTitle: String,
        talkRevisionNumber: Int,
        isOlderRevision: Bool
    )
    case sameFullRunRevisionAndScope(
        scopeTitle: String,
        talkRevisionNumber: Int,
        isOlderRevision: Bool
    )
    case differentSectionRevisions(
        sameSection: Bool,
        leftTitle: String,
        rightTitle: String,
        leftRevisionNumber: Int,
        rightRevisionNumber: Int
    )
    case differentFullRunScopeOrRevision(
        sameTalkRevision: Bool,
        sameScope: Bool,
        leftScopeTitle: String,
        rightScopeTitle: String,
        leftRevisionNumber: Int,
        rightRevisionNumber: Int
    )
    case mixedAttemptKinds

    var isDirectlyComparable: Bool {
        switch self {
        case .sameSectionRevision, .sameFullRunRevisionAndScope:
            true
        case .differentSectionRevisions, .differentFullRunScopeOrRevision, .mixedAttemptKinds:
            false
        }
    }

    var title: String {
        switch self {
        case .sameSectionRevision(let sectionTitle, let revNumber, let isOlder):
            let suffix = isOlder ? " (Older Revision)" : ""
            return "Section Take · \(sectionTitle) · Rev \(revNumber)\(suffix)"
        case .sameFullRunRevisionAndScope(let scopeTitle, let revNumber, let isOlder):
            let suffix = isOlder ? " (Older Revision)" : ""
            return "Full Run · \(scopeTitle) · Rev \(revNumber)\(suffix)"
        case .differentSectionRevisions(let sameSection, _, _, let leftRev, let rightRev):
            if sameSection {
                return "Different Section Revisions (Rev \(leftRev) vs. Rev \(rightRev))"
            }
            return "Different Sections Compared"
        case .differentFullRunScopeOrRevision(
            let sameTalkRev,
            let sameScope,
            _,
            _,
            let leftRev,
            let rightRev
        ):
            if !sameTalkRev && !sameScope {
                return "Different Revisions & Scopes (Rev \(leftRev) vs. Rev \(rightRev))"
            }
            if !sameTalkRev {
                return "Different Talk Revisions (Rev \(leftRev) vs. Rev \(rightRev))"
            }
            return "Different Run Scopes (Rev \(leftRev))"
        case .mixedAttemptKinds:
            return "Section Take vs. Full Run"
        }
    }

    var detailMessage: String {
        switch self {
        case .sameSectionRevision(_, _, let isOlder):
            return isOlder
                ? "Both takes share this exact earlier section revision. Replay either to decide which to keep."
                : "Both takes share the exact same section revision. Replay either to decide which to keep."
        case .sameFullRunRevisionAndScope(_, _, let isOlder):
            return isOlder
                ? "Both runs share this earlier talk revision and run scope. Replay either to compare transitions."
                : "Both runs share the exact same talk revision and run scope. Replay either to compare transitions."
        case .differentSectionRevisions(let sameSection, let leftTitle, let rightTitle, let leftRev, let rightRev):
            if sameSection {
                return "The script changed between Revision \(leftRev) and Revision \(rightRev). " +
                    "Duration and reveal differences may reflect script edits."
            }
            return "Comparing “\(leftTitle)” (Rev \(leftRev)) with “\(rightTitle)” (Rev \(rightRev))."
        case .differentFullRunScopeOrRevision(
            let sameTalkRev,
            let sameScope,
            let leftScope,
            let rightScope,
            let leftRev,
            let rightRev
        ):
            if !sameTalkRev && !sameScope {
                return "Earlier run used \(leftScope) (Rev \(leftRev)); later run used \(rightScope) (Rev \(rightRev))."
            }
            if !sameTalkRev {
                return "Talk script or order changed between Rev \(leftRev) and Rev \(rightRev)."
            }
            return "Run scopes differ: \(leftScope) vs. \(rightScope)."
        case .mixedAttemptKinds:
            return "Comparing a single-section take with a multi-section full run — scopes do not match."
        }
    }
}

struct FullRunSectionComparisonRow: Identifiable, Equatable, Sendable {
    let id: String
    let displayOrderIndex: Int
    let sectionTitle: String
    let speakerSummary: String
    let purpose: SectionPurpose
    let earlierTransition: FullRunSectionTransition?
    let laterTransition: FullRunSectionTransition?
    let speakerChanged: Bool

    var durationDelta: TimeInterval? {
        guard let earlierDur = earlierTransition?.duration,
              let laterDur = laterTransition?.duration else {
            return nil
        }
        return laterDur - earlierDur
    }
}

struct AttemptComparisonSummary: Equatable, Sendable {
    let earlier: ComparableAttemptDescriptor
    let later: ComparableAttemptDescriptor
    let scope: AttemptComparisonScope
    let earlierIsOlderRevision: Bool
    let laterIsOlderRevision: Bool
    let durationDelta: TimeInterval
    let revealDelta: Int
    let markerDelta: Int
    let estimatedWPMDelta: Double?
    let fullRunSectionRows: [FullRunSectionComparisonRow]
    let completionContextNote: String?

    var formattedDurationDelta: String {
        Self.formatSignedSeconds(durationDelta)
    }

    var formattedRevealDelta: String {
        if revealDelta == 0 { return "No change" }
        let sign = revealDelta > 0 ? "+" : ""
        let noun = abs(revealDelta) == 1 ? "reveal" : "reveals"
        return "\(sign)\(revealDelta) \(noun)"
    }

    static func formatSignedSeconds(_ delta: TimeInterval) -> String {
        guard delta.isFinite else { return "0.0s" }
        if abs(delta) < 0.05 { return "0.0s" }
        let sign = delta > 0 ? "+" : "-"
        return String(format: "%@%.1fs", sign, abs(delta))
    }
}

struct DefaultComparisonSelection: Equatable, Sendable {
    let earlierID: UUID
    let laterID: UUID
    let scope: AttemptComparisonScope
}
