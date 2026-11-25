import Foundation

nonisolated struct CoachingTaskEvaluationSummary: Equatable, Sendable {
    static let requiredCaseCount = 20
    static let qualificationUsefulThreshold = 16

    let task: CoachingTaskKind
    let totalCases: Int
    let ratedCases: Int
    let authoredUsefulCount: Int
    let modelUsefulCount: Int
    let modelFallbackCount: Int
    let modelValidationFailureCount: Int
    let fallbackPreferredCount: Int
    let expectedAbstentionCount: Int
    let modelAbstentionCorrectCount: Int
    let modelMissedAbstentionCount: Int
    let modelFalseAbstentionCount: Int
    let modelInventedMeasurementCount: Int
    let modelAlteredQuoteCount: Int
    let modelUnsupportedSpeakerCount: Int
    let modelPreferredCount: Int
    let authoredPreferredCount: Int
    let tieCount: Int
    let neitherCount: Int
    let coldLatencyStatus: ColdLatencyMeasurementStatus
    let coldLatencyMilliseconds: Double?
    let warmMedianLatencyMilliseconds: Double?
    let warmMinLatencyMilliseconds: Double?
    let warmMaxLatencyMilliseconds: Double?
    let meanRepeatSimilarity: Double?
    let meanRepeatTechniqueAgreement: Double?
    let isSimulator: Bool
    let isLegacySession: Bool
    let unblindedEarly: Bool
    let modelAvailability: CoachingModelAvailability

    var totalModelSafetyViolations: Int {
        modelInventedMeasurementCount + modelAlteredQuoteCount + modelUnsupportedSpeakerCount
    }

    var offersPracticalBenefit: Bool {
        modelPreferredCount > authoredPreferredCount
    }

    var isQualifiedForShipping: Bool {
        hasValidEvaluationContext &&
            totalCases >= Self.requiredCaseCount &&
            ratedCases == totalCases &&
            modelFallbackCount == 0 &&
            modelValidationFailureCount == 0 &&
            modelUsefulCount >= Self.qualificationUsefulThreshold &&
            totalModelSafetyViolations == 0 &&
            modelMissedAbstentionCount == 0 &&
            offersPracticalBenefit
    }

    private var hasValidEvaluationContext: Bool {
        !isSimulator && !isLegacySession && !unblindedEarly && modelAvailability.isAvailable
    }

    var decisionHeadline: String {
        if isQualifiedForShipping {
            return "Qualified for On-Device Generation (Physical Device Verified)"
        }
        if let contextBlock = contextDisqualificationHeadline {
            return contextBlock
        }
        if ratedCases < totalCases {
            return "Keep Authored Baseline (\(ratedCases)/\(totalCases) Cases Rated)"
        }
        if modelFallbackCount > 0 {
            return "Keep Authored Baseline (\(modelFallbackCount) Model Fallback(s) Excluded)"
        }
        if totalModelSafetyViolations > 0 {
            return "Keep Authored Baseline (\(totalModelSafetyViolations) Safety Violation(s))"
        }
        if modelMissedAbstentionCount > 0 {
            return "Keep Authored Baseline (\(modelMissedAbstentionCount) Missed Abstention(s))"
        }
        if modelUsefulCount < Self.qualificationUsefulThreshold {
            return "Keep Authored Baseline (\(modelUsefulCount)/\(totalCases) Useful; Need 16+)"
        }
        return "Keep Authored Baseline (No Practical Benefit Over Authored)"
    }

    private var contextDisqualificationHeadline: String? {
        if isLegacySession {
            return "Keep Authored Baseline (Legacy Session — Re-Run on v2)"
        }
        if isSimulator {
            return "Keep Authored Baseline (Simulator Cannot Qualify Model)"
        }
        if !modelAvailability.isAvailable {
            return "Keep Authored Baseline (On-Device Model Unavailable)"
        }
        if unblindedEarly {
            return "Keep Authored Baseline (Unblinded Early Before Rating All Cases)"
        }
        return nil
    }
}

nonisolated struct CoachingEvaluationSession: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let id: UUID
    let evaluationSchemaVersion: Int
    let task: CoachingTaskKind
    let datasetVersion: String
    let promptVersion: String
    let createdAt: Date
    var updatedAt: Date
    var environment: CoachingDeviceEnvironment
    let modelAvailability: CoachingModelAvailability
    var isUnblinded: Bool
    var unblindedEarly: Bool
    let coldLatencyStatus: ColdLatencyMeasurementStatus
    let coldLatencyMilliseconds: Double?
    let warmLatenciesMilliseconds: [Double]
    let repeatVariationResults: [RepeatVariationResult]
    var entries: [BlindedEvaluationEntry]

    init(
        id: UUID,
        evaluationSchemaVersion: Int = CoachingEvaluationSession.currentSchemaVersion,
        task: CoachingTaskKind,
        datasetVersion: String,
        promptVersion: String,
        createdAt: Date,
        updatedAt: Date,
        environment: CoachingDeviceEnvironment,
        modelAvailability: CoachingModelAvailability,
        isUnblinded: Bool,
        unblindedEarly: Bool = false,
        coldLatencyStatus: ColdLatencyMeasurementStatus = .unknownLegacy,
        coldLatencyMilliseconds: Double?,
        warmLatenciesMilliseconds: [Double],
        repeatVariationResults: [RepeatVariationResult],
        entries: [BlindedEvaluationEntry]
    ) {
        self.id = id
        self.evaluationSchemaVersion = evaluationSchemaVersion
        self.task = task
        self.datasetVersion = datasetVersion
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.environment = environment
        self.modelAvailability = modelAvailability
        self.isUnblinded = isUnblinded
        self.unblindedEarly = unblindedEarly
        self.coldLatencyStatus = coldLatencyStatus
        self.coldLatencyMilliseconds = coldLatencyMilliseconds
        self.warmLatenciesMilliseconds = warmLatenciesMilliseconds
        self.repeatVariationResults = repeatVariationResults
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case id, evaluationSchemaVersion, task, datasetVersion, promptVersion
        case createdAt, updatedAt, environment, modelAvailability, isUnblinded, unblindedEarly
        case coldLatencyStatus, coldLatencyMilliseconds, warmLatenciesMilliseconds
        case repeatVariationResults, entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        evaluationSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .evaluationSchemaVersion) ?? 1
        task = try container.decode(CoachingTaskKind.self, forKey: .task)
        datasetVersion = try container.decode(String.self, forKey: .datasetVersion)
        promptVersion = try container.decode(String.self, forKey: .promptVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        environment = try container.decode(CoachingDeviceEnvironment.self, forKey: .environment)
        modelAvailability = try container.decode(CoachingModelAvailability.self, forKey: .modelAvailability)
        isUnblinded = try container.decode(Bool.self, forKey: .isUnblinded)
        unblindedEarly = try container.decodeIfPresent(Bool.self, forKey: .unblindedEarly) ?? false
        coldLatencyStatus = try container.decodeIfPresent(
            ColdLatencyMeasurementStatus.self,
            forKey: .coldLatencyStatus
        ) ?? .unknownLegacy
        coldLatencyMilliseconds = try container.decodeIfPresent(Double.self, forKey: .coldLatencyMilliseconds)
        warmLatenciesMilliseconds = try container.decode([Double].self, forKey: .warmLatenciesMilliseconds)
        repeatVariationResults = try container.decode([RepeatVariationResult].self, forKey: .repeatVariationResults)
        entries = try container.decode([BlindedEvaluationEntry].self, forKey: .entries)
    }

    var expectedPromptVersion: String {
        task == .preparation
            ? SectionCoachService.preparationPromptVersion
            : SectionCoachService.postTakePromptVersion
    }

    var isLegacySession: Bool {
        evaluationSchemaVersion < Self.currentSchemaVersion || promptVersion != expectedPromptVersion
    }

    func summary() -> CoachingTaskEvaluationSummary {
        var tally = EvaluationTally()
        for entry in entries {
            tally.record(entry)
        }

        let sortedWarm = warmLatenciesMilliseconds.sorted()
        let warmMedian: Double? = sortedWarm.isEmpty ? nil : sortedWarm[sortedWarm.count / 2]
        let validSims = repeatVariationResults.compactMap(\.meanTokenOverlapSimilarity)
        let validAgrees = repeatVariationResults.compactMap(\.techniqueAgreementRate)
        let meanRepeatSim: Double? = validSims.isEmpty
            ? nil
            : validSims.reduce(0, +) / Double(validSims.count)
        let meanRepeatTech: Double? = validAgrees.isEmpty
            ? nil
            : validAgrees.reduce(0, +) / Double(validAgrees.count)

        return CoachingTaskEvaluationSummary(
            task: task,
            totalCases: entries.count,
            ratedCases: tally.rated,
            authoredUsefulCount: tally.authoredUseful,
            modelUsefulCount: tally.modelUseful,
            modelFallbackCount: tally.modelFallbacks,
            modelValidationFailureCount: tally.modelValidationFailures,
            fallbackPreferredCount: tally.fallbackPreferred,
            expectedAbstentionCount: tally.expectedAbstentions,
            modelAbstentionCorrectCount: tally.modelAbstentionCorrect,
            modelMissedAbstentionCount: tally.modelMissedAbstentions,
            modelFalseAbstentionCount: tally.modelFalseAbstentions,
            modelInventedMeasurementCount: tally.inventedMeasurements,
            modelAlteredQuoteCount: tally.alteredQuotes,
            modelUnsupportedSpeakerCount: tally.unsupportedSpeakers,
            modelPreferredCount: tally.modelPreferred,
            authoredPreferredCount: tally.authoredPreferred,
            tieCount: tally.ties,
            neitherCount: tally.neithers,
            coldLatencyStatus: coldLatencyStatus,
            coldLatencyMilliseconds: coldLatencyMilliseconds,
            warmMedianLatencyMilliseconds: warmMedian,
            warmMinLatencyMilliseconds: sortedWarm.first,
            warmMaxLatencyMilliseconds: sortedWarm.last,
            meanRepeatSimilarity: meanRepeatSim,
            meanRepeatTechniqueAgreement: meanRepeatTech,
            isSimulator: environment.isSimulator,
            isLegacySession: isLegacySession,
            unblindedEarly: unblindedEarly,
            modelAvailability: modelAvailability
        )
    }

    func markdownReport() -> String {
        let stats = summary()
        let coldText = stats.coldLatencyMilliseconds.map {
            String(format: "%.0f ms (%@)", $0, stats.coldLatencyStatus.displayLabel)
        } ?? stats.coldLatencyStatus.displayLabel
        let warmMedText = stats.warmMedianLatencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "N/A"
        let repeatSimText = stats.meanRepeatSimilarity.map { String(format: "%.0f%%", $0 * 100) } ?? "N/A"
        let repeatTechText = stats.meanRepeatTechniqueAgreement.map { String(format: "%.0f%%", $0 * 100) } ?? "N/A"
        let deviceKind = environment.isSimulator ? "Simulator" : "Physical Device"
        let safetyLine = "\(stats.totalModelSafetyViolations) " +
            "(invented=\(stats.modelInventedMeasurementCount), " +
            "alteredQuote=\(stats.modelAlteredQuoteCount), " +
            "speaker=\(stats.modelUnsupportedSpeakerCount))"
        let abstentionLine = "\(stats.modelAbstentionCorrectCount)/\(stats.expectedAbstentionCount) expected " +
            "(missed=\(stats.modelMissedAbstentionCount), false=\(stats.modelFalseAbstentionCount))"
        return """
        # Spelum Blinded Coach Evaluation — \(task.displayName)
        - Decision: \(stats.decisionHeadline)
        - Schema: v\(evaluationSchemaVersion) | Dataset: \(datasetVersion) | Prompt: \(promptVersion)
        - Environment: \(environment.osDescription) (\(environment.deviceModel), \(deviceKind))
        - On-Device Model Availability: \(modelAvailability.shortStatusLabel)
        - Rated: \(stats.ratedCases)/\(stats.totalCases) (Unblinded Early: \(stats.unblindedEarly ? "Yes" : "No"))
        - Useful (Non-Fallback Model vs Authored): \(stats.modelUsefulCount)/\(stats.totalCases) vs \(stats.authoredUsefulCount)/\(stats.totalCases)
        - Preferences: On-Device \(stats.modelPreferredCount) | Authored \(stats.authoredPreferredCount) | Fallback \(stats.fallbackPreferredCount) | Tie \(stats.tieCount) | Neither \(stats.neitherCount)
        - Safety Violations (On-Device): \(safetyLine)
        - Abstention Accuracy (Non-Fallback Model): \(abstentionLine)
        - Model Fallbacks to Authored: \(stats.modelFallbackCount)/\(stats.totalCases) (Validation Failures: \(stats.modelValidationFailureCount))
        - Latency: First request after launch \(coldText) | Subsequent median \(warmMedText)
        - Repeated Variation: Technique Agreement \(repeatTechText) | Mean Token Similarity \(repeatSimText)
        """
    }
}

private nonisolated struct EvaluationTally {
    var rated = 0
    var authoredUseful = 0
    var modelUseful = 0
    var modelFallbacks = 0
    var modelValidationFailures = 0
    var fallbackPreferred = 0
    var expectedAbstentions = 0
    var modelAbstentionCorrect = 0
    var modelMissedAbstentions = 0
    var modelFalseAbstentions = 0
    var inventedMeasurements = 0
    var alteredQuotes = 0
    var unsupportedSpeakers = 0
    var modelPreferred = 0
    var authoredPreferred = 0
    var ties = 0
    var neithers = 0

    mutating func record(_ entry: BlindedEvaluationEntry) {
        let modelSuggestion = entry.modelSuggestion
        let isFallback = entry.isModelFallback
        if isFallback {
            modelFallbacks += 1
            if case .validationFailed = modelSuggestion.fallbackReason {
                modelValidationFailures += 1
            }
        }
        recordAbstention(entry: entry, modelSuggestion: modelSuggestion, isFallback: isFallback)

        guard let rating = entry.rating else { return }
        rated += 1
        let modelIsA = entry.optionASource == .onDeviceModel
        let modelSlotUseful = modelIsA ? rating.optionAUseful : rating.optionBUseful
        let authoredSlotUseful = modelIsA ? rating.optionBUseful : rating.optionAUseful
        if authoredSlotUseful { authoredUseful += 1 }
        if !isFallback && modelSlotUseful { modelUseful += 1 }

        recordSafetyIssues(modelIsA ? rating.optionASafetyIssues : rating.optionBSafetyIssues)
        recordPreference(rating.preference, modelIsA: modelIsA, isFallback: isFallback)
    }

    private mutating func recordAbstention(
        entry: BlindedEvaluationEntry,
        modelSuggestion: CoachingSuggestion,
        isFallback: Bool
    ) {
        if entry.expectsAbstention {
            expectedAbstentions += 1
            guard !isFallback else { return }
            if modelSuggestion.isAbstention {
                modelAbstentionCorrect += 1
            } else {
                modelMissedAbstentions += 1
            }
        } else if !isFallback && modelSuggestion.isAbstention {
            modelFalseAbstentions += 1
        }
    }

    private mutating func recordSafetyIssues(_ issues: Set<EvaluationSafetyIssue>) {
        if issues.contains(.inventedMeasurement) { inventedMeasurements += 1 }
        if issues.contains(.alteredQuote) { alteredQuotes += 1 }
        if issues.contains(.unsupportedSpeakerJudgment) { unsupportedSpeakers += 1 }
    }

    private mutating func recordPreference(
        _ preference: BlindedPreference,
        modelIsA: Bool,
        isFallback: Bool
    ) {
        switch preference {
        case .optionA:
            recordSlotWin(pickedModelSlot: modelIsA, isFallback: isFallback)
        case .optionB:
            recordSlotWin(pickedModelSlot: !modelIsA, isFallback: isFallback)
        case .tie:
            ties += 1
        case .neither:
            neithers += 1
        }
    }

    private mutating func recordSlotWin(pickedModelSlot: Bool, isFallback: Bool) {
        if pickedModelSlot {
            if isFallback {
                fallbackPreferred += 1
            } else {
                modelPreferred += 1
            }
        } else {
            authoredPreferred += 1
        }
    }
}
