import CryptoKit
import Foundation

nonisolated struct PreparationCoachingRequest: Equatable, Hashable, Sendable {
    let presentationID: UUID?
    let sectionRevisionID: UUID
    let talkRevisionID: UUID
    let sectionTitle: String
    let scriptText: String
    let exactPhrase: String?
    let cueWords: [String]
    let purpose: SectionPurpose
    let handoffCueText: String?
    let isSpeakerChangeHandoff: Bool
    let isMultiSpeakerTalk: Bool
    let knownSpeakerNames: [String]
    let selectedTechniqueID: String?
    let candidateTechniques: [CoachingTechnique]
    let promptVersion: String

    init(
        presentationID: UUID? = nil,
        sectionRevisionID: UUID,
        talkRevisionID: UUID,
        sectionTitle: String,
        scriptText: String,
        exactPhrase: String?,
        cueWords: [String],
        purpose: SectionPurpose,
        handoffCueText: String?,
        isSpeakerChangeHandoff: Bool,
        isMultiSpeakerTalk: Bool? = nil,
        knownSpeakerNames: [String] = [],
        selectedTechniqueID: String? = nil,
        candidateTechniques: [CoachingTechnique],
        promptVersion: String
    ) {
        self.presentationID = presentationID
        self.sectionRevisionID = sectionRevisionID
        self.talkRevisionID = talkRevisionID
        self.sectionTitle = sectionTitle
        self.scriptText = scriptText
        self.exactPhrase = exactPhrase
        self.cueWords = cueWords
        self.purpose = purpose
        self.handoffCueText = handoffCueText
        self.isSpeakerChangeHandoff = isSpeakerChangeHandoff
        self.isMultiSpeakerTalk = isMultiSpeakerTalk ?? (isSpeakerChangeHandoff || knownSpeakerNames.count > 1)
        self.knownSpeakerNames = knownSpeakerNames
        self.selectedTechniqueID = selectedTechniqueID
        self.candidateTechniques = candidateTechniques
        self.promptVersion = promptVersion
    }

    var hasHandoffCue: Bool {
        guard let handoffCueText else { return false }
        return !handoffCueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var effectiveTechniqueKey: String {
        selectedTechniqueID ?? "auto"
    }

    var cacheKey: String {
        "prep|\(sectionRevisionID.uuidString.lowercased())|\(effectiveTechniqueKey)|\(promptVersion)"
    }

    var contentFingerprint: String {
        let components = [
            sectionTitle,
            scriptText,
            exactPhrase ?? "",
            cueWords.joined(separator: "\u{1F}"),
            purpose.rawValue,
            handoffCueText ?? "",
            isSpeakerChangeHandoff ? "1" : "0",
            isMultiSpeakerTalk ? "1" : "0",
            effectiveTechniqueKey,
            candidateTechniques.map(\.id).joined(separator: ","),
            promptVersion
        ].joined(separator: "\u{1E}")
        return CoachingFingerprint.sha256Hex(components)
    }
}

nonisolated struct PostTakeCoachingRequest: Equatable, Hashable, Sendable {
    let presentationID: UUID?
    let attemptID: UUID
    let talkRevisionID: UUID
    let sectionRevisionID: UUID
    let sectionTitle: String
    let scriptText: String
    let exactPhrase: String?
    let cueWords: [String]
    let purpose: SectionPurpose
    let handoffCueText: String?
    let isSpeakerChangeHandoff: Bool
    let isMultiSpeakerTalk: Bool
    let knownSpeakerNames: [String]
    let attemptStatus: AttemptStatus
    let practiceMode: PracticeMode
    let playableDuration: TimeInterval
    let revealCount: Int
    let markers: [AttemptMarker]
    let timingAnalysis: TimingAnalysisResult?
    let candidateTechniques: [CoachingTechnique]
    let promptVersion: String

    init(
        presentationID: UUID? = nil,
        attemptID: UUID,
        talkRevisionID: UUID,
        sectionRevisionID: UUID,
        sectionTitle: String,
        scriptText: String,
        exactPhrase: String?,
        cueWords: [String],
        purpose: SectionPurpose,
        handoffCueText: String?,
        isSpeakerChangeHandoff: Bool,
        isMultiSpeakerTalk: Bool? = nil,
        knownSpeakerNames: [String] = [],
        attemptStatus: AttemptStatus,
        practiceMode: PracticeMode,
        playableDuration: TimeInterval,
        revealCount: Int,
        markers: [AttemptMarker],
        timingAnalysis: TimingAnalysisResult?,
        candidateTechniques: [CoachingTechnique],
        promptVersion: String
    ) {
        self.presentationID = presentationID
        self.attemptID = attemptID
        self.talkRevisionID = talkRevisionID
        self.sectionRevisionID = sectionRevisionID
        self.sectionTitle = sectionTitle
        self.scriptText = scriptText
        self.exactPhrase = exactPhrase
        self.cueWords = cueWords
        self.purpose = purpose
        self.handoffCueText = handoffCueText
        self.isSpeakerChangeHandoff = isSpeakerChangeHandoff
        self.isMultiSpeakerTalk = isMultiSpeakerTalk ?? (isSpeakerChangeHandoff || knownSpeakerNames.count > 1)
        self.knownSpeakerNames = knownSpeakerNames
        self.attemptStatus = attemptStatus
        self.practiceMode = practiceMode
        self.playableDuration = max(0, playableDuration.isFinite ? playableDuration : 0)
        self.revealCount = max(0, revealCount)
        self.markers = markers
        self.timingAnalysis = timingAnalysis
        self.candidateTechniques = candidateTechniques
        self.promptVersion = promptVersion
    }

    var hasHandoffCue: Bool {
        guard let handoffCueText else { return false }
        return !handoffCueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var evidenceVersion: String {
        let markerPart = markers.map {
            "\($0.id.uuidString.lowercased()):\(String(format: "%.2f", $0.timestamp)):\($0.label)"
        }.joined(separator: ",")
        let analysisPart: String
        if let analysis = timingAnalysis {
            let obsSummary = analysis.observations.map { obs in
                let gap = obs.gapDuration.map { String(format: "%.2f", $0) } ?? ""
                return "\(obs.id.uuidString.lowercased()):\(obs.kind.rawValue):\(gap):\(obs.matchedPhrase ?? "")"
            }.joined(separator: ",")
            let noteReasons = analysis.ambiguousNotes.map(\.reason.rawValue).joined(separator: ",")
            let wpmPart = analysis.estimatedWordsPerMinute.map { String(format: "%.1f", $0) } ?? ""
            analysisPart = [
                analysis.analysisID.uuidString.lowercased(),
                String(analysis.analysisVersion),
                analysis.outcome.rawValue,
                wpmPart,
                obsSummary,
                noteReasons
            ].joined(separator: "|")
        } else {
            analysisPart = "none"
        }
        let raw = [
            sectionRevisionID.uuidString.lowercased(),
            scriptText,
            exactPhrase ?? "",
            handoffCueText ?? "",
            isSpeakerChangeHandoff ? "1" : "0",
            isMultiSpeakerTalk ? "1" : "0",
            attemptStatus.rawValue,
            practiceMode.rawValue,
            String(format: "%.2f", playableDuration),
            String(revealCount),
            markerPart,
            analysisPart,
            candidateTechniques.map(\.id).joined(separator: ","),
            promptVersion
        ].joined(separator: "\u{1E}")
        return CoachingFingerprint.sha256Hex(raw)
    }

    var cacheKey: String {
        "review|\(attemptID.uuidString.lowercased())|\(evidenceVersion)|\(promptVersion)"
    }
}

nonisolated enum CoachingFingerprint {
    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
