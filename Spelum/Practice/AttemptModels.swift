import Foundation
import SwiftData

enum PracticeMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case fullScript
    case cueWords
    case memory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullScript: "Full Script"
        case .cueWords: "Cue Words"
        case .memory: "Memory"
        }
    }

    var shortLabel: String {
        switch self {
        case .fullScript: "Script"
        case .cueWords: "Cues"
        case .memory: "Memory"
        }
    }

    var symbolName: String {
        switch self {
        case .fullScript: "doc.text"
        case .cueWords: "tag"
        case .memory: "brain"
        }
    }

    var guidanceText: String {
        switch self {
        case .fullScript:
            "Read your full section script while rehearsing."
        case .cueWords:
            "Use your cue words and reveal the full script only when needed."
        case .memory:
            "Deliver from memory after the handoff cue and reveal only if stuck."
        }
    }

    var supportsReveal: Bool {
        self != .fullScript
    }
}

enum AttemptStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case inProgress
    case ready
    case interrupted
    case silentCompleted

    var displayName: String {
        switch self {
        case .inProgress: "In Progress"
        case .ready: "Ready"
        case .interrupted: "Interrupted"
        case .silentCompleted: "Silent Recall"
        }
    }

    var symbolName: String {
        switch self {
        case .inProgress: "record.circle"
        case .ready: "checkmark.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        case .silentCompleted: "mic.slash.circle.fill"
        }
    }

    var isFinalized: Bool {
        self != .inProgress
    }
}

struct AttemptMarker: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    let label: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        label: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.timestamp = max(0, timestamp.isFinite ? timestamp : 0)
        self.label = label
        self.createdAt = createdAt
    }
}

struct AttemptSnapshotReference: Codable, Equatable, Hashable, Sendable {
    let presentationID: UUID
    let talkRevisionID: UUID
    let talkRevisionNumber: Int
    let sectionID: UUID
    let sectionRevisionID: UUID
    let sectionTitle: String
}

struct AttemptFinalizationInput: Sendable {
    let id: UUID
    let snapshot: AttemptSnapshotReference
    let practiceMode: PracticeMode
    let startedAt: Date
    let finishedAt: Date
    let relativeAudioPath: String?
    let elapsedDuration: TimeInterval
    let revealCount: Int
    let markers: [AttemptMarker]
    let isSilentRecall: Bool
    let interrupted: Bool
    let interruptionReason: String?

    init(
        id: UUID,
        snapshot: AttemptSnapshotReference,
        practiceMode: PracticeMode,
        startedAt: Date,
        finishedAt: Date = Date(),
        relativeAudioPath: String?,
        elapsedDuration: TimeInterval,
        revealCount: Int,
        markers: [AttemptMarker],
        isSilentRecall: Bool,
        interrupted: Bool,
        interruptionReason: String?
    ) {
        self.id = id
        self.snapshot = snapshot
        self.practiceMode = practiceMode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.relativeAudioPath = relativeAudioPath
        self.elapsedDuration = max(0, elapsedDuration.isFinite ? elapsedDuration : 0)
        self.revealCount = max(0, revealCount)
        self.markers = markers.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.timestamp < rhs.timestamp
        }
        self.isSilentRecall = isSilentRecall
        self.interrupted = interrupted
        self.interruptionReason = interruptionReason
    }
}

struct PendingSaveManifest: Codable, Equatable, Sendable {
    let attemptID: UUID
    let snapshot: AttemptSnapshotReference
    let practiceMode: PracticeMode
    let startedAt: Date
    let finishedAt: Date
    let relativeAudioPath: String?
    let elapsedDuration: TimeInterval
    let revealCount: Int
    let markers: [AttemptMarker]
    let isSilentRecall: Bool
    let interrupted: Bool
    let interruptionReason: String?
}

struct AttemptRecoverySummary: Equatable, Sendable {
    let recoveredPlayableCount: Int
    let recoveredWithoutAudioCount: Int
    let removedStaleSidecarCount: Int

    var totalRecoveredCount: Int {
        recoveredPlayableCount + recoveredWithoutAudioCount
    }
}

enum AttemptStoreError: LocalizedError, Equatable, Sendable {
    case invalidRelativeAudioPath
    case attemptNotFound
    case audioDirectoryUnavailable
    case audioReferenceStateUnknown

    var errorDescription: String? {
        switch self {
        case .invalidRelativeAudioPath:
            "The recording path is invalid or outside Spelum’s local storage."
        case .attemptNotFound:
            "This rehearsal take could not be found."
        case .audioDirectoryUnavailable:
            "Spelum could not access its local rehearsal storage folder."
        case .audioReferenceStateUnknown:
            "Spelum could not verify whether another take still uses this audio file."
        }
    }
}

@Model
final class AttemptRecord {
    var id: UUID
    var presentationID: UUID
    var talkRevisionID: UUID
    var talkRevisionNumber: Int
    var sectionID: UUID
    var sectionRevisionID: UUID
    var sectionTitleSnapshot: String
    var startedAt: Date
    var finishedAt: Date?
    var practiceModeRawValue: String
    var statusRawValue: String
    var relativeAudioPath: String?
    var playableDuration: TimeInterval
    var elapsedDuration: TimeInterval
    var revealCount: Int
    var markersData: Data
    var interruptionReason: String?
    var isSilentRecall: Bool

    init(
        id: UUID = UUID(),
        snapshot: AttemptSnapshotReference,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        practiceMode: PracticeMode,
        status: AttemptStatus,
        relativeAudioPath: String? = nil,
        playableDuration: TimeInterval = 0,
        elapsedDuration: TimeInterval = 0,
        revealCount: Int = 0,
        markers: [AttemptMarker] = [],
        interruptionReason: String? = nil,
        isSilentRecall: Bool = false
    ) {
        self.id = id
        self.presentationID = snapshot.presentationID
        self.talkRevisionID = snapshot.talkRevisionID
        self.talkRevisionNumber = snapshot.talkRevisionNumber
        self.sectionID = snapshot.sectionID
        self.sectionRevisionID = snapshot.sectionRevisionID
        self.sectionTitleSnapshot = snapshot.sectionTitle
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.practiceModeRawValue = practiceMode.rawValue
        self.statusRawValue = status.rawValue
        self.relativeAudioPath = relativeAudioPath
        self.playableDuration = max(0, playableDuration.isFinite ? playableDuration : 0)
        self.elapsedDuration = max(0, elapsedDuration.isFinite ? elapsedDuration : 0)
        self.revealCount = max(0, revealCount)
        self.markersData = Self.encodeMarkers(markers)
        self.interruptionReason = interruptionReason
        self.isSilentRecall = isSilentRecall
    }

    var practiceMode: PracticeMode {
        PracticeMode(rawValue: practiceModeRawValue) ?? .fullScript
    }

    var status: AttemptStatus {
        AttemptStatus(rawValue: statusRawValue) ?? .interrupted
    }

    var markers: [AttemptMarker] {
        let decoded = (try? JSONDecoder().decode([AttemptMarker].self, from: markersData)) ?? []
        return decoded.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    var hasPlayableAudio: Bool {
        guard let relativeAudioPath, !relativeAudioPath.isEmpty else { return false }
        return playableDuration > 0 && playableDuration.isFinite
    }

    var displayDuration: TimeInterval {
        hasPlayableAudio ? playableDuration : elapsedDuration
    }

    var snapshotReference: AttemptSnapshotReference {
        AttemptSnapshotReference(
            presentationID: presentationID,
            talkRevisionID: talkRevisionID,
            talkRevisionNumber: talkRevisionNumber,
            sectionID: sectionID,
            sectionRevisionID: sectionRevisionID,
            sectionTitle: sectionTitleSnapshot
        )
    }

    func updateMarkers(_ newMarkers: [AttemptMarker]) {
        let sorted = newMarkers.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.timestamp < rhs.timestamp
        }
        markersData = Self.encodeMarkers(sorted)
    }

    private static func encodeMarkers(_ markers: [AttemptMarker]) -> Data {
        (try? JSONEncoder().encode(markers)) ?? Data()
    }
}

enum RehearsalTimeFormatter {
    static func clockString(for seconds: TimeInterval) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let totalTenths = Int((clamped * 10).rounded(.down))
        let minutes = totalTenths / 600
        let remainingSeconds = (totalTenths % 600) / 10
        let tenths = totalTenths % 10
        return String(format: "%d:%02d.%d", minutes, remainingSeconds, tenths)
    }

    static func shortDurationString(for seconds: TimeInterval) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let totalSeconds = Int(clamped.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func accessibleDurationString(for seconds: TimeInterval) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(clamped) / 60
        let remaining = clamped.truncatingRemainder(dividingBy: 60)
        if minutes > 0 {
            let wholeSeconds = Int(remaining.rounded())
            let minuteUnit = minutes == 1 ? "minute" : "minutes"
            let secondUnit = wholeSeconds == 1 ? "second" : "seconds"
            return "\(minutes) \(minuteUnit) \(wholeSeconds) \(secondUnit)"
        }
        let roundedTenths = (remaining * 10).rounded() / 10
        if roundedTenths == roundedTenths.rounded() {
            let whole = Int(roundedTenths)
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
        return String(format: "%.1f seconds", roundedTenths)
    }
}
