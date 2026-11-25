import Foundation

nonisolated enum EvaluationSafetyIssue: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case inventedMeasurement
    case alteredQuote
    case unsupportedSpeakerJudgment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inventedMeasurement: "Invented Measurement"
        case .alteredQuote: "Altered Quote"
        case .unsupportedSpeakerJudgment: "Unsupported Speaker Judgment"
        }
    }
}

nonisolated enum BlindedPreference: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case optionA
    case optionB
    case tie
    case neither

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .optionA: "Option A"
        case .optionB: "Option B"
        case .tie: "Tie"
        case .neither: "Neither"
        }
    }
}

nonisolated enum ColdLatencyMeasurementStatus: String, Codable, Equatable, Hashable, Sendable {
    case verifiedColdLaunch
    case processAlreadyWarmed
    case firstCallFailed
    case modelUnavailable
    case simulatorNotPhysical
    case unknownLegacy

    var displayLabel: String {
        switch self {
        case .verifiedColdLaunch:
            "Verified cold launch"
        case .processAlreadyWarmed:
            "Unmeasured (app already warmed — relaunch app for cold check)"
        case .firstCallFailed:
            "Unmeasured (first model call failed or fell back)"
        case .modelUnavailable:
            "Unmeasured (on-device model unavailable)"
        case .simulatorNotPhysical:
            "Unmeasured (simulator — physical iPhone required)"
        case .unknownLegacy:
            "Unverified (legacy session)"
        }
    }
}

nonisolated struct BlindedCaseRating: Codable, Equatable, Hashable, Sendable {
    var optionAUseful: Bool
    var optionBUseful: Bool
    var optionASafetyIssues: Set<EvaluationSafetyIssue>
    var optionBSafetyIssues: Set<EvaluationSafetyIssue>
    var preference: BlindedPreference

    init(
        optionAUseful: Bool,
        optionBUseful: Bool,
        optionASafetyIssues: Set<EvaluationSafetyIssue> = [],
        optionBSafetyIssues: Set<EvaluationSafetyIssue> = [],
        preference: BlindedPreference
    ) {
        self.optionAUseful = optionAUseful
        self.optionBUseful = optionBUseful
        self.optionASafetyIssues = optionASafetyIssues
        self.optionBSafetyIssues = optionBSafetyIssues
        self.preference = preference
    }
}

nonisolated struct BlindedCaseRatingDraft: Equatable, Hashable, Sendable {
    var optionAUseful: Bool?
    var optionBUseful: Bool?
    var optionASafetyIssues: Set<EvaluationSafetyIssue>
    var optionBSafetyIssues: Set<EvaluationSafetyIssue>
    var preference: BlindedPreference?

    init(existing: BlindedCaseRating? = nil) {
        self.optionAUseful = existing?.optionAUseful
        self.optionBUseful = existing?.optionBUseful
        self.optionASafetyIssues = existing?.optionASafetyIssues ?? []
        self.optionBSafetyIssues = existing?.optionBSafetyIssues ?? []
        self.preference = existing?.preference
    }

    var isComplete: Bool {
        optionAUseful != nil && optionBUseful != nil && preference != nil
    }

    func buildRating() -> BlindedCaseRating? {
        guard let optionAUseful, let optionBUseful, let preference else { return nil }
        return BlindedCaseRating(
            optionAUseful: optionAUseful,
            optionBUseful: optionBUseful,
            optionASafetyIssues: optionASafetyIssues,
            optionBSafetyIssues: optionBSafetyIssues,
            preference: preference
        )
    }
}

nonisolated struct BlindedEvaluationEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let category: CoachingCategory
    let title: String
    let sectionTitle: String
    let scriptText: String
    let handoffCueText: String?
    let tags: [String]
    let expectsAbstention: Bool
    let contextSummary: String
    let optionASource: CoachingSourceMode
    let optionBSource: CoachingSourceMode
    let optionASuggestion: CoachingSuggestion
    let optionBSuggestion: CoachingSuggestion
    let modelLatencyMilliseconds: Double?
    let modelFellBackToAuthored: Bool
    let modelFallbackSummary: String?
    var rating: BlindedCaseRating?

    var isRated: Bool { rating != nil }

    var modelSuggestion: CoachingSuggestion {
        optionASource == .onDeviceModel ? optionASuggestion : optionBSuggestion
    }

    var isModelFallback: Bool {
        modelFellBackToAuthored || modelSuggestion.origin == .authoredFallback
    }

    func displayTitle(at index: Int, isUnblinded: Bool) -> String {
        if isUnblinded {
            return title
        }
        return "Case \(index + 1) · \(sectionTitle)"
    }

    func displayContextSummary(for task: CoachingTaskKind, isUnblinded: Bool) -> String {
        if isUnblinded || task == .postTake {
            return contextSummary
        }
        if let separatorRange = contextSummary.range(of: " · ") {
            return String(contextSummary[..<separatorRange.lowerBound])
        }
        return contextSummary
    }
}

nonisolated struct RepeatVariationResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let caseTitle: String
    let trialCount: Int
    let successfulTrialCount: Int
    let uniqueActionCount: Int
    let techniqueAgreementRate: Double?
    let meanTokenOverlapSimilarity: Double?
    let trialLatenciesMilliseconds: [Double]
    let fallbackCount: Int

    init(
        id: String,
        caseTitle: String,
        trialCount: Int,
        successfulTrialCount: Int,
        uniqueActionCount: Int,
        techniqueAgreementRate: Double?,
        meanTokenOverlapSimilarity: Double?,
        trialLatenciesMilliseconds: [Double],
        fallbackCount: Int
    ) {
        self.id = id
        self.caseTitle = caseTitle
        self.trialCount = trialCount
        self.successfulTrialCount = successfulTrialCount
        self.uniqueActionCount = uniqueActionCount
        self.techniqueAgreementRate = techniqueAgreementRate
        self.meanTokenOverlapSimilarity = meanTokenOverlapSimilarity
        self.trialLatenciesMilliseconds = trialLatenciesMilliseconds
        self.fallbackCount = fallbackCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, caseTitle, trialCount, successfulTrialCount, uniqueActionCount
        case techniqueAgreementRate, meanTokenOverlapSimilarity, trialLatenciesMilliseconds, fallbackCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        caseTitle = try container.decode(String.self, forKey: .caseTitle)
        trialCount = try container.decode(Int.self, forKey: .trialCount)
        fallbackCount = try container.decode(Int.self, forKey: .fallbackCount)
        let decodedSuccess = try container.decodeIfPresent(Int.self, forKey: .successfulTrialCount)
            ?? max(0, trialCount - fallbackCount)
        successfulTrialCount = decodedSuccess
        uniqueActionCount = try container.decode(Int.self, forKey: .uniqueActionCount)
        let rawAgree = try container.decodeIfPresent(Double.self, forKey: .techniqueAgreementRate)
        let rawSim = try container.decodeIfPresent(Double.self, forKey: .meanTokenOverlapSimilarity)
        techniqueAgreementRate = decodedSuccess >= 2 ? rawAgree : nil
        meanTokenOverlapSimilarity = decodedSuccess >= 2 ? rawSim : nil
        trialLatenciesMilliseconds = try container.decode([Double].self, forKey: .trialLatenciesMilliseconds)
    }
}
