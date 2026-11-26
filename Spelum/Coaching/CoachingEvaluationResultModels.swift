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
            "First evaluation request after app launch"
        case .processAlreadyWarmed:
            "Unmeasured (an evaluation already started during this launch)"
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
    let exactPhrase: String?
    let handoffCueText: String?
    let isSpeakerChangeHandoff: Bool
    let isMultiSpeakerTalk: Bool
    let knownSpeakerNames: [String]
    let postTakeEvidence: EvaluationPostTakeEvidence?
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

    init(
        id: String,
        category: CoachingCategory,
        title: String,
        sectionTitle: String,
        scriptText: String,
        exactPhrase: String? = nil,
        handoffCueText: String?,
        isSpeakerChangeHandoff: Bool = false,
        isMultiSpeakerTalk: Bool? = nil,
        knownSpeakerNames: [String] = [],
        postTakeEvidence: EvaluationPostTakeEvidence? = nil,
        tags: [String],
        expectsAbstention: Bool,
        contextSummary: String,
        optionASource: CoachingSourceMode,
        optionBSource: CoachingSourceMode,
        optionASuggestion: CoachingSuggestion,
        optionBSuggestion: CoachingSuggestion,
        modelLatencyMilliseconds: Double?,
        modelFellBackToAuthored: Bool,
        modelFallbackSummary: String?,
        rating: BlindedCaseRating?
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.sectionTitle = sectionTitle
        self.scriptText = scriptText
        self.exactPhrase = exactPhrase
        self.handoffCueText = handoffCueText
        self.isSpeakerChangeHandoff = isSpeakerChangeHandoff
        self.isMultiSpeakerTalk = isMultiSpeakerTalk ?? (isSpeakerChangeHandoff || knownSpeakerNames.count > 1)
        self.knownSpeakerNames = knownSpeakerNames
        self.postTakeEvidence = postTakeEvidence
        self.tags = tags
        self.expectsAbstention = expectsAbstention
        self.contextSummary = contextSummary
        self.optionASource = optionASource
        self.optionBSource = optionBSource
        self.optionASuggestion = optionASuggestion
        self.optionBSuggestion = optionBSuggestion
        self.modelLatencyMilliseconds = modelLatencyMilliseconds
        self.modelFellBackToAuthored = modelFellBackToAuthored
        self.modelFallbackSummary = modelFallbackSummary
        self.rating = rating
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, title, sectionTitle, scriptText, exactPhrase, handoffCueText
        case isSpeakerChangeHandoff, isMultiSpeakerTalk, knownSpeakerNames, postTakeEvidence
        case tags, expectsAbstention, contextSummary
        case optionASource, optionBSource, optionASuggestion, optionBSuggestion
        case modelLatencyMilliseconds, modelFellBackToAuthored, modelFallbackSummary, rating
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(CoachingCategory.self, forKey: .category)
        title = try container.decode(String.self, forKey: .title)
        sectionTitle = try container.decode(String.self, forKey: .sectionTitle)
        scriptText = try container.decode(String.self, forKey: .scriptText)
        exactPhrase = try container.decodeIfPresent(String.self, forKey: .exactPhrase)
        handoffCueText = try container.decodeIfPresent(String.self, forKey: .handoffCueText)
        isSpeakerChangeHandoff = try container.decodeIfPresent(Bool.self, forKey: .isSpeakerChangeHandoff) ?? false
        knownSpeakerNames = try container.decodeIfPresent([String].self, forKey: .knownSpeakerNames) ?? []
        isMultiSpeakerTalk = try container.decodeIfPresent(Bool.self, forKey: .isMultiSpeakerTalk)
            ?? (isSpeakerChangeHandoff || knownSpeakerNames.count > 1)
        postTakeEvidence = try container.decodeIfPresent(EvaluationPostTakeEvidence.self, forKey: .postTakeEvidence)
        tags = try container.decode([String].self, forKey: .tags)
        expectsAbstention = try container.decode(Bool.self, forKey: .expectsAbstention)
        contextSummary = try container.decode(String.self, forKey: .contextSummary)
        optionASource = try container.decode(CoachingSourceMode.self, forKey: .optionASource)
        optionBSource = try container.decode(CoachingSourceMode.self, forKey: .optionBSource)
        optionASuggestion = try container.decode(CoachingSuggestion.self, forKey: .optionASuggestion)
        optionBSuggestion = try container.decode(CoachingSuggestion.self, forKey: .optionBSuggestion)
        modelLatencyMilliseconds = try container.decodeIfPresent(Double.self, forKey: .modelLatencyMilliseconds)
        modelFellBackToAuthored = try container.decode(Bool.self, forKey: .modelFellBackToAuthored)
        modelFallbackSummary = try container.decodeIfPresent(String.self, forKey: .modelFallbackSummary)
        rating = try container.decodeIfPresent(BlindedCaseRating.self, forKey: .rating)
    }

    var isRated: Bool { rating != nil }

    var modelSuggestion: CoachingSuggestion {
        optionASource == .onDeviceModel ? optionASuggestion : optionBSuggestion
    }

    var isModelFallback: Bool {
        modelFellBackToAuthored || modelSuggestion.origin == .authoredFallback
    }

    var speakerContextSummary: String? {
        let names = knownSpeakerNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let namesText = names.isEmpty ? nil : "Known speakers: \(names.joined(separator: ", "))"
        if isSpeakerChangeHandoff {
            return namesText.map { "Speaker-change handoff · \($0)" } ?? "Speaker-change handoff"
        }
        if isMultiSpeakerTalk {
            return namesText.map { "Multi-speaker talk · \($0)" } ?? "Multi-speaker talk"
        }
        if let handoff = handoffCueText?.trimmingCharacters(in: .whitespacesAndNewlines), !handoff.isEmpty {
            return namesText.map { "Solo section transition · \($0)" } ?? "Solo section transition"
        }
        return names.count > 1 ? namesText : nil
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
