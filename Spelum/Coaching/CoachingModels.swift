import Foundation

nonisolated enum CoachingTaskKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case preparation
    case postTake

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preparation: "Pre-Practice Coaching"
        case .postTake: "Post-Take Coaching"
        }
    }

    var shortName: String {
        switch self {
        case .preparation: "Preparation"
        case .postTake: "Post-Take"
        }
    }
}

nonisolated enum CoachingCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case handoff
    case reveal
    case demo
    case close
    case story
    case general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .handoff: "Handoff"
        case .reveal: "Reveal"
        case .demo: "Demo"
        case .close: "Close"
        case .story: "Story"
        case .general: "General"
        }
    }

    var symbolName: String {
        switch self {
        case .handoff: "arrow.triangle.swap"
        case .reveal: "sparkles"
        case .demo: "play.display"
        case .close: "flag.checkered"
        case .story: "book"
        case .general: "text.alignleft"
        }
    }
}

nonisolated enum CoachingSourceMode: String, Codable, Equatable, Hashable, Sendable {
    case authoredBaseline
    case onDeviceModel

    var displayName: String {
        switch self {
        case .authoredBaseline: "Authored Baseline"
        case .onDeviceModel: "On-Device Foundation Model"
        }
    }
}

nonisolated struct CoachingFeaturePolicy: Equatable, Sendable {
    let preparationQualifiedOnDevice: Bool
    let postTakeQualifiedOnDevice: Bool

    /// Authored cues remain the default for both tasks until real physical-device human evaluation qualifies each task.
    static let `default` = CoachingFeaturePolicy(
        preparationQualifiedOnDevice: false,
        postTakeQualifiedOnDevice: false
    )

    func isModelQualified(for task: CoachingTaskKind) -> Bool {
        switch task {
        case .preparation: preparationQualifiedOnDevice
        case .postTake: postTakeQualifiedOnDevice
        }
    }

    func defaultMode(for task: CoachingTaskKind) -> CoachingSourceMode {
        isModelQualified(for: task) ? .onDeviceModel : .authoredBaseline
    }
}

nonisolated enum CoachingModelUnavailableReason: String, Codable, Equatable, Hashable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unknown

    var userMessage: String {
        switch self {
        case .deviceNotEligible:
            "Apple’s on-device Foundation Model is not supported on this device. Using authored cues."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off on this device. Using authored cues."
        case .modelNotReady:
            "Apple’s on-device Foundation Model is still preparing assets. Using authored cues."
        case .unsupportedLocale:
            "Apple’s on-device Foundation Model does not support English in this locale. Using authored cues."
        case .unknown:
            "Apple’s on-device Foundation Model is currently unavailable. Using authored cues."
        }
    }
}

nonisolated enum CoachingModelAvailability: Codable, Equatable, Hashable, Sendable {
    case available
    case unavailable(CoachingModelUnavailableReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var unavailableReason: CoachingModelUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    var shortStatusLabel: String {
        switch self {
        case .available:
            "On-Device Model Available"
        case .unavailable(.deviceNotEligible):
            "Unavailable (Device Not Eligible)"
        case .unavailable(.appleIntelligenceNotEnabled):
            "Unavailable (Apple Intelligence Off)"
        case .unavailable(.modelNotReady):
            "Unavailable (Model Not Ready)"
        case .unavailable(.unsupportedLocale):
            "Unavailable (Locale Unsupported)"
        case .unavailable(.unknown):
            "Unavailable"
        }
    }
}

nonisolated enum CoachingValidationFailure: String, Codable, Equatable, Hashable, Sendable {
    case unknownTechniqueID
    case unknownPassageID
    case alteredOrInventedQuote
    case unknownEvidenceID
    case unknownObservationID
    case unknownActionID
    case incompatibleSelection
    case invalidAbstentionState
    case inventedMeasurement
    case unsupportedSpeakerJudgment
    case disallowedCoachingClaim
    case emptyOrInvalidAction

    var summaryLabel: String {
        switch self {
        case .unknownTechniqueID: "Unrecognized technique ID"
        case .unknownPassageID: "Unrecognized passage ID"
        case .alteredOrInventedQuote: "Quotation did not match source verbatim"
        case .unknownEvidenceID: "Referenced evidence ID was absent"
        case .unknownObservationID: "Referenced observation ID was absent"
        case .unknownActionID: "Unrecognized action option ID"
        case .incompatibleSelection: "Selected passage, evidence, technique, and action were incompatible"
        case .invalidAbstentionState: "Invalid abstention selection for available evidence"
        case .inventedMeasurement: "Included an ungrounded timing measurement"
        case .unsupportedSpeakerJudgment: "Attributed timing to a speaker without evidence"
        case .disallowedCoachingClaim: "Included disallowed score or voice/accent judgment"
        case .emptyOrInvalidAction: "Action text was empty or too long"
        }
    }
}

nonisolated enum CoachingFallbackReason: Codable, Equatable, Hashable, Sendable {
    case modelUnavailable(CoachingModelUnavailableReason)
    case generationError(String)
    case validationFailed(CoachingValidationFailure)

    var userSummary: String {
        switch self {
        case .modelUnavailable(let reason):
            reason.userMessage
        case .generationError:
            "On-device generation could not complete. Showing the authored cue instead."
        case .validationFailed:
            "On-device suggestion did not pass grounding checks. Showing the authored cue instead."
        }
    }
}

nonisolated enum CoachingCueOrigin: String, Codable, Equatable, Hashable, Sendable {
    case authoredBaseline
    case onDeviceModel
    case authoredFallback

    var badgeLabel: String {
        switch self {
        case .authoredBaseline: "Authored Cue"
        case .onDeviceModel: "On-Device Coach"
        case .authoredFallback: "Authored Fallback"
        }
    }

    var symbolName: String {
        switch self {
        case .authoredBaseline: "book.closed"
        case .onDeviceModel: "cpu"
        case .authoredFallback: "checkmark.shield"
        }
    }
}

nonisolated struct CoachingTechniqueActionOption: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let label: String
    let instruction: String
}

nonisolated struct CoachingTechnique: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let category: CoachingCategory
    let applicablePurposes: [SectionPurpose]
    let appliesToHandoff: Bool
    let sourceWork: String
    let sourceTimestamp: String
    let sourcePassageSummary: String
    let deliveryInstruction: String
    let postTakeFocus: String
    let preparationActionOptions: [CoachingTechniqueActionOption]

    init(
        id: String,
        title: String,
        category: CoachingCategory,
        applicablePurposes: [SectionPurpose],
        appliesToHandoff: Bool,
        sourceWork: String,
        sourceTimestamp: String,
        sourcePassageSummary: String,
        deliveryInstruction: String,
        postTakeFocus: String,
        preparationActionOptions: [CoachingTechniqueActionOption] = []
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.applicablePurposes = applicablePurposes
        self.appliesToHandoff = appliesToHandoff
        self.sourceWork = sourceWork
        self.sourceTimestamp = sourceTimestamp
        self.sourcePassageSummary = sourcePassageSummary
        self.deliveryInstruction = deliveryInstruction
        self.postTakeFocus = postTakeFocus
        self.preparationActionOptions = preparationActionOptions
    }
}

nonisolated struct RawModelPreparationSelection: Codable, Equatable, Hashable, Sendable {
    let shouldAbstain: Bool
    let abstentionReasonID: String?
    let techniqueID: String?
    let passageID: String?
    let actionID: String?
}

nonisolated struct RawModelPostTakeSelection: Codable, Equatable, Hashable, Sendable {
    let shouldAbstain: Bool
    let abstentionReasonID: String?
    let techniqueID: String?
    let passageID: String?
    let evidenceID: String?
    let actionID: String?
}

nonisolated struct CoachingSuggestion: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let task: CoachingTaskKind
    let origin: CoachingCueOrigin
    let fallbackReason: CoachingFallbackReason?
    let isAbstention: Bool
    let techniqueID: String?
    let techniqueTitle: String?
    let sourceWork: String?
    let sourceTimestamp: String?
    let sourcePassageSummary: String?
    let exactPhrase: String?
    let exactPhraseFromHandoff: Bool
    let observationID: UUID?
    let action: String
    let rationale: String
    let promptVersion: String
    let sectionRevisionID: UUID
    let attemptID: UUID?
    let evidenceVersion: String?
    var userEditedAction: String?
    var isDismissed: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        task: CoachingTaskKind,
        origin: CoachingCueOrigin,
        fallbackReason: CoachingFallbackReason? = nil,
        isAbstention: Bool = false,
        techniqueID: String?,
        techniqueTitle: String?,
        sourceWork: String?,
        sourceTimestamp: String?,
        sourcePassageSummary: String?,
        exactPhrase: String?,
        exactPhraseFromHandoff: Bool = false,
        observationID: UUID? = nil,
        action: String,
        rationale: String,
        promptVersion: String,
        sectionRevisionID: UUID,
        attemptID: UUID? = nil,
        evidenceVersion: String? = nil,
        userEditedAction: String? = nil,
        isDismissed: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.task = task
        self.origin = origin
        self.fallbackReason = fallbackReason
        self.isAbstention = isAbstention
        self.techniqueID = techniqueID
        self.techniqueTitle = techniqueTitle
        self.sourceWork = sourceWork
        self.sourceTimestamp = sourceTimestamp
        self.sourcePassageSummary = sourcePassageSummary
        self.exactPhrase = exactPhrase
        self.exactPhraseFromHandoff = exactPhraseFromHandoff
        self.observationID = observationID
        self.action = action
        self.rationale = rationale
        self.promptVersion = promptVersion
        self.sectionRevisionID = sectionRevisionID
        self.attemptID = attemptID
        self.evidenceVersion = evidenceVersion
        self.userEditedAction = userEditedAction
        self.isDismissed = isDismissed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isUserEdited: Bool {
        guard let edited = userEditedAction else { return false }
        return !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayedAction: String {
        if let edited = userEditedAction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !edited.isEmpty {
            return edited
        }
        return action
    }

    var hasProvenance: Bool {
        sourceWork != nil && sourceTimestamp != nil && sourcePassageSummary != nil
    }
}
