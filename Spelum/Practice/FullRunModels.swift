import Foundation

enum AttemptKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case section
    case fullRun

    var displayName: String {
        switch self {
        case .section: "Section Take"
        case .fullRun: "Full Run"
        }
    }

    var shortLabel: String {
        switch self {
        case .section: "Section"
        case .fullRun: "Full Run"
        }
    }

    var symbolName: String {
        switch self {
        case .section: "doc.text"
        case .fullRun: "list.number"
        }
    }
}

enum FullRunStartKind: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case entireTalk
    case fromHandoff

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .entireTalk: "Entire Talk"
        case .fromHandoff: "From Handoff"
        }
    }

    var symbolName: String {
        switch self {
        case .entireTalk: "play.square.stack"
        case .fromHandoff: "arrow.triangle.turn.up.right.diamond"
        }
    }
}

enum FullRunCompletionKind: String, Codable, Equatable, Hashable, Sendable {
    case completedAllSections
    case finishedEarly
    case interrupted

    var displayName: String {
        switch self {
        case .completedAllSections: "Completed"
        case .finishedEarly: "Finished Early"
        case .interrupted: "Interrupted"
        }
    }
}

struct FullRunTarget: Hashable, Sendable {
    let presentationID: UUID
    let talkRevisionID: UUID?
    let startKind: FullRunStartKind
    let startingSectionID: UUID?
    let initialMode: PracticeMode
    let retryToken: UUID

    init(
        presentationID: UUID,
        talkRevisionID: UUID? = nil,
        startKind: FullRunStartKind = .entireTalk,
        startingSectionID: UUID? = nil,
        initialMode: PracticeMode = .cueWords,
        retryToken: UUID = UUID()
    ) {
        self.presentationID = presentationID
        self.talkRevisionID = talkRevisionID
        self.startKind = startKind
        self.startingSectionID = startingSectionID
        self.initialMode = initialMode
        self.retryToken = retryToken
    }
}

struct FullRunSectionSnapshot: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID { sectionRevisionID }

    let runIndex: Int
    let talkSectionIndex: Int
    let sectionID: UUID
    let sectionRevisionID: UUID
    let title: String
    let text: String
    let speaker: String
    let speakerRole: SpeakerRole
    let purpose: SectionPurpose
    let cueWords: [String]
    let exactPhrase: String?
    let handoffCueText: String?
    let handoffPrecedingSpeaker: String?
    let handoffPrecedingSectionTitle: String?
    let handoffIsSpeakerChange: Bool

    var speakerSummary: String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(speakerRole.displayName) == .orderedSame {
            return speakerRole.displayName
        }
        return "\(trimmed) · \(speakerRole.displayName)"
    }
}

struct FullRunSectionTransition: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let runIndex: Int
    let talkSectionIndex: Int
    let sectionID: UUID
    let sectionRevisionID: UUID
    let sectionTitle: String
    let speaker: String
    let speakerRole: SpeakerRole
    let purpose: SectionPurpose
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let recordedAt: Date

    init(
        id: UUID = UUID(),
        runIndex: Int,
        talkSectionIndex: Int,
        sectionID: UUID,
        sectionRevisionID: UUID,
        sectionTitle: String,
        speaker: String,
        speakerRole: SpeakerRole,
        purpose: SectionPurpose,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.runIndex = max(0, runIndex)
        self.talkSectionIndex = max(0, talkSectionIndex)
        self.sectionID = sectionID
        self.sectionRevisionID = sectionRevisionID
        self.sectionTitle = sectionTitle
        self.speaker = speaker
        self.speakerRole = speakerRole
        self.purpose = purpose
        let safeStart = startTime.isFinite ? max(0, startTime) : 0
        self.startTime = safeStart
        if let endTime, endTime.isFinite {
            self.endTime = max(safeStart, endTime)
        } else {
            self.endTime = nil
        }
        self.recordedAt = recordedAt
    }

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return max(0, endTime - startTime)
    }

    var speakerSummary: String {
        let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(speakerRole.displayName) == .orderedSame {
            return speakerRole.displayName
        }
        return "\(trimmed) · \(speakerRole.displayName)"
    }
}

struct FullRunSnapshot: Codable, Equatable, Hashable, Sendable {
    let presentationID: UUID
    let presentationTitle: String
    let talkRevisionID: UUID
    let talkRevisionNumber: Int
    let startKind: FullRunStartKind
    let startingTalkSectionIndex: Int
    let totalTalkSectionCount: Int
    let sections: [FullRunSectionSnapshot]

    var startingSection: FullRunSectionSnapshot? {
        sections.first
    }

    var scopeIdentifier: String {
        let revIDs = sections
            .map { $0.sectionRevisionID.uuidString.lowercased() }
            .joined(separator: ",")
        return "\(startKind.rawValue)|\(startingTalkSectionIndex)|\(revIDs)"
    }

    var scopeTitle: String {
        switch startKind {
        case .entireTalk:
            let count = sections.count
            return count == 1 ? "Entire Talk (1 section)" : "Entire Talk (\(count) sections)"
        case .fromHandoff:
            if let first = sections.first {
                return "From Handoff: \(first.title)"
            }
            return "From Presenter Handoff"
        }
    }

    var scopeShortBadge: String {
        switch startKind {
        case .entireTalk: "Entire Talk"
        case .fromHandoff: "From Handoff"
        }
    }

    var hasMultipleSpeakers: Bool {
        let keys = Set(sections.map { section -> String in
            let trimmed = section.speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? section.speakerRole.rawValue : trimmed
        })
        return keys.count > 1 || sections.contains(where: \.handoffIsSpeakerChange)
    }

    func makeAttemptSnapshotReference() -> AttemptSnapshotReference {
        let first = sections.first
        return AttemptSnapshotReference(
            presentationID: presentationID,
            talkRevisionID: talkRevisionID,
            talkRevisionNumber: talkRevisionNumber,
            sectionID: first?.sectionID ?? talkRevisionID,
            sectionRevisionID: first?.sectionRevisionID ?? talkRevisionID,
            sectionTitle: scopeTitle
        )
    }
}

struct FullRunAttemptPayload: Codable, Equatable, Hashable, Sendable {
    let snapshot: FullRunSnapshot
    let transitions: [FullRunSectionTransition]
    let completionKind: FullRunCompletionKind
    let reachedSectionCount: Int

    var totalPlannedSections: Int {
        snapshot.sections.count
    }

    var finishedEarly: Bool {
        completionKind == .finishedEarly
    }

    var unreachedSections: [FullRunSectionSnapshot] {
        let reachedIDs = Set(transitions.map(\.sectionRevisionID))
        return snapshot.sections.filter { !reachedIDs.contains($0.sectionRevisionID) }
    }

    func activeTransition(at playbackTime: TimeInterval) -> FullRunSectionTransition? {
        guard !transitions.isEmpty, playbackTime.isFinite else { return transitions.first }
        let safeTime = max(0, playbackTime)
        if let exact = transitions.last(where: { $0.startTime <= safeTime }) {
            return exact
        }
        return transitions.first
    }

    func progressSummary(status: AttemptStatus) -> String {
        let total = totalPlannedSections
        let reached = min(max(reachedSectionCount, transitions.count), total)
        let noun = total == 1 ? "section" : "sections"
        switch completionKind {
        case .completedAllSections:
            return status == .interrupted
                ? "Interrupted (\(reached) of \(total) \(noun))"
                : "All \(total) \(noun)"
        case .finishedEarly:
            return "Finished early (\(reached) of \(total) \(noun))"
        case .interrupted:
            return "Interrupted (\(reached) of \(total) \(noun))"
        }
    }
}
