import Foundation

nonisolated struct SeededRandomGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var zValue = state
        zValue = (zValue ^ (zValue >> 30)) &* 0xBF58_476D_1CE4_E5B9
        zValue = (zValue ^ (zValue >> 27)) &* 0x94D0_49BB_1331_11EB
        return zValue ^ (zValue >> 31)
    }
}

nonisolated final class CoachingEvaluationRunner: Sendable {
    let coachService: SectionCoachService
    let repeatTrialsPerCase: Int

    init(
        coachService: SectionCoachService = SectionCoachService(),
        repeatTrialsPerCase: Int = 3
    ) {
        self.coachService = coachService
        self.repeatTrialsPerCase = max(2, repeatTrialsPerCase)
    }

    func runSuite(
        task: CoachingTaskKind,
        dataset: CoachingEvaluationDataset,
        environment: CoachingDeviceEnvironment,
        randomSeed: UInt64? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> CoachingEvaluationSession {
        var rng = SeededRandomGenerator(seed: randomSeed ?? UInt64.random(in: 1...UInt64.max))
        let availability = coachService.modelAvailability()
        let promptVersion = task == .preparation
            ? SectionCoachService.preparationPromptVersion
            : SectionCoachService.postTakePromptVersion

        let batch: SuiteBatchResult
        switch task {
        case .preparation:
            batch = await runPreparationBatch(
                cases: dataset.preparationCases,
                promptVersion: promptVersion,
                isModelAvailable: availability.isAvailable,
                rng: &rng,
                onProgress: onProgress
            )
        case .postTake:
            batch = await runPostTakeBatch(
                cases: dataset.postTakeCases,
                promptVersion: promptVersion,
                isModelAvailable: availability.isAvailable,
                rng: &rng,
                onProgress: onProgress
            )
        }

        let coldLatency = batch.latencies.first
        let warmLatencies = batch.latencies.count > 1 ? Array(batch.latencies.dropFirst()) : []
        let now = Date()
        return CoachingEvaluationSession(
            id: UUID(),
            task: task,
            datasetVersion: dataset.datasetVersion,
            promptVersion: promptVersion,
            createdAt: now,
            updatedAt: now,
            environment: environment,
            modelAvailability: availability,
            isUnblinded: false,
            coldLatencyMilliseconds: coldLatency,
            warmLatenciesMilliseconds: warmLatencies,
            repeatVariationResults: batch.repeatResults,
            entries: batch.entries
        )
    }

    static func tokenJaccardSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = normalizedTokens(lhs)
        let rhsTokens = normalizedTokens(rhs)
        if lhsTokens.isEmpty && rhsTokens.isEmpty {
            return 1.0
        }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }
}

private extension CoachingEvaluationRunner {
    struct SuiteBatchResult {
        let entries: [BlindedEvaluationEntry]
        let latencies: [Double]
        let repeatResults: [RepeatVariationResult]
    }

    func runPreparationBatch(
        cases: [PreparationEvaluationCase],
        promptVersion: String,
        isModelAvailable: Bool,
        rng: inout SeededRandomGenerator,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async -> SuiteBatchResult {
        var entries: [BlindedEvaluationEntry] = []
        var latencies: [Double] = []
        var repeatResults: [RepeatVariationResult] = []
        let total = cases.count

        for (index, evalCase) in cases.enumerated() {
            let request = evalCase.makeRequest(promptVersion: promptVersion)
            let authored = await coachService.generatePreparationCue(request: request, mode: .authoredBaseline)
            let (modelCue, elapsedMS) = await timedPreparation(
                request: request,
                isModelAvailable: isModelAvailable
            )
            if let elapsedMS { latencies.append(elapsedMS) }
            entries.append(
                makeBlindedEntry(
                    id: evalCase.id,
                    category: evalCase.category,
                    title: evalCase.title,
                    sectionTitle: evalCase.sectionTitle,
                    scriptText: evalCase.scriptText,
                    handoffCueText: evalCase.handoffCueText,
                    tags: evalCase.tags,
                    expectsAbstention: evalCase.expectsAbstention,
                    contextSummary: "Purpose: \(evalCase.purpose.displayName) · \(evalCase.notes)",
                    authored: authored,
                    model: modelCue,
                    latencyMS: elapsedMS,
                    rng: &rng
                )
            )
            onProgress?(index + 1, total)
        }

        for evalCase in cases where evalCase.includeInRepeatCheck {
            let item = await measurePreparationRepeatVariation(
                evalCase: evalCase,
                promptVersion: promptVersion,
                isModelAvailable: isModelAvailable
            )
            repeatResults.append(item)
        }
        return SuiteBatchResult(entries: entries, latencies: latencies, repeatResults: repeatResults)
    }

    func runPostTakeBatch(
        cases: [PostTakeEvaluationCase],
        promptVersion: String,
        isModelAvailable: Bool,
        rng: inout SeededRandomGenerator,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async -> SuiteBatchResult {
        var entries: [BlindedEvaluationEntry] = []
        var latencies: [Double] = []
        var repeatResults: [RepeatVariationResult] = []
        let total = cases.count

        for (index, evalCase) in cases.enumerated() {
            let request = evalCase.makeRequest(promptVersion: promptVersion)
            let authored = await coachService.generatePostTakeCue(request: request, mode: .authoredBaseline)
            let (modelCue, elapsedMS) = await timedPostTake(
                request: request,
                isModelAvailable: isModelAvailable
            )
            if let elapsedMS { latencies.append(elapsedMS) }
            entries.append(
                makeBlindedEntry(
                    id: evalCase.id,
                    category: evalCase.category,
                    title: evalCase.title,
                    sectionTitle: evalCase.sectionTitle,
                    scriptText: evalCase.scriptText,
                    handoffCueText: evalCase.handoffCueText,
                    tags: evalCase.tags,
                    expectsAbstention: evalCase.expectsAbstention,
                    contextSummary: postTakeContextSummary(for: evalCase),
                    authored: authored,
                    model: modelCue,
                    latencyMS: elapsedMS,
                    rng: &rng
                )
            )
            onProgress?(index + 1, total)
        }

        for evalCase in cases where evalCase.includeInRepeatCheck {
            let item = await measurePostTakeRepeatVariation(
                evalCase: evalCase,
                promptVersion: promptVersion,
                isModelAvailable: isModelAvailable
            )
            repeatResults.append(item)
        }
        return SuiteBatchResult(entries: entries, latencies: latencies, repeatResults: repeatResults)
    }

    func timedPreparation(
        request: PreparationCoachingRequest,
        isModelAvailable: Bool
    ) async -> (CoachingSuggestion, Double?) {
        let clock = ContinuousClock()
        let start = clock.now
        let cue = await coachService.generatePreparationCue(request: request, mode: .onDeviceModel)
        let elapsedMS = durationMilliseconds(start.duration(to: clock.now))
        return (cue, isModelAvailable ? elapsedMS : nil)
    }

    func timedPostTake(
        request: PostTakeCoachingRequest,
        isModelAvailable: Bool
    ) async -> (CoachingSuggestion, Double?) {
        let clock = ContinuousClock()
        let start = clock.now
        let cue = await coachService.generatePostTakeCue(request: request, mode: .onDeviceModel)
        let elapsedMS = durationMilliseconds(start.duration(to: clock.now))
        return (cue, isModelAvailable ? elapsedMS : nil)
    }

    func measurePreparationRepeatVariation(
        evalCase: PreparationEvaluationCase,
        promptVersion: String,
        isModelAvailable: Bool
    ) async -> RepeatVariationResult {
        let request = evalCase.makeRequest(promptVersion: promptVersion)
        var suggestions: [CoachingSuggestion] = []
        var trialLatencies: [Double] = []
        for _ in 0..<repeatTrialsPerCase {
            let (cue, elapsedMS) = await timedPreparation(request: request, isModelAvailable: isModelAvailable)
            suggestions.append(cue)
            if let elapsedMS { trialLatencies.append(elapsedMS) }
        }
        return summarizeRepeatTrials(
            id: evalCase.id,
            caseTitle: evalCase.title,
            suggestions: suggestions,
            latencies: trialLatencies
        )
    }

    func measurePostTakeRepeatVariation(
        evalCase: PostTakeEvaluationCase,
        promptVersion: String,
        isModelAvailable: Bool
    ) async -> RepeatVariationResult {
        let request = evalCase.makeRequest(promptVersion: promptVersion)
        var suggestions: [CoachingSuggestion] = []
        var trialLatencies: [Double] = []
        for _ in 0..<repeatTrialsPerCase {
            let (cue, elapsedMS) = await timedPostTake(request: request, isModelAvailable: isModelAvailable)
            suggestions.append(cue)
            if let elapsedMS { trialLatencies.append(elapsedMS) }
        }
        return summarizeRepeatTrials(
            id: evalCase.id,
            caseTitle: evalCase.title,
            suggestions: suggestions,
            latencies: trialLatencies
        )
    }

    func summarizeRepeatTrials(
        id: String,
        caseTitle: String,
        suggestions: [CoachingSuggestion],
        latencies: [Double]
    ) -> RepeatVariationResult {
        let normalizedActions = suggestions.map {
            $0.displayedAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let uniqueActions = Set(normalizedActions).count
        let fallbackCount = suggestions.filter { $0.origin == .authoredFallback }.count

        let techKeys = suggestions.map { $0.isAbstention ? "abstain" : ($0.techniqueID ?? "none") }
        let grouped = Dictionary(grouping: techKeys, by: { $0 }).values.map(\.count)
        let dominantCount = grouped.max() ?? 0
        let agreementRate = suggestions.isEmpty
            ? 1.0
            : Double(dominantCount) / Double(suggestions.count)

        var pairwiseSimilarities: [Double] = []
        for idxA in 0..<suggestions.count {
            for idxB in (idxA + 1)..<suggestions.count {
                pairwiseSimilarities.append(
                    Self.tokenJaccardSimilarity(
                        suggestions[idxA].displayedAction,
                        suggestions[idxB].displayedAction
                    )
                )
            }
        }
        let meanSimilarity = pairwiseSimilarities.isEmpty
            ? 1.0
            : pairwiseSimilarities.reduce(0, +) / Double(pairwiseSimilarities.count)

        return RepeatVariationResult(
            id: id,
            caseTitle: caseTitle,
            trialCount: suggestions.count,
            uniqueActionCount: uniqueActions,
            techniqueAgreementRate: agreementRate,
            meanTokenOverlapSimilarity: meanSimilarity,
            trialLatenciesMilliseconds: latencies,
            fallbackCount: fallbackCount
        )
    }

    // swiftlint:disable:next function_parameter_count
    func makeBlindedEntry(
        id: String,
        category: CoachingCategory,
        title: String,
        sectionTitle: String,
        scriptText: String,
        handoffCueText: String?,
        tags: [String],
        expectsAbstention: Bool,
        contextSummary: String,
        authored: CoachingSuggestion,
        model: CoachingSuggestion,
        latencyMS: Double?,
        rng: inout SeededRandomGenerator
    ) -> BlindedEvaluationEntry {
        let modelFirst = (rng.next() & 1) == 0
        return BlindedEvaluationEntry(
            id: id,
            category: category,
            title: title,
            sectionTitle: sectionTitle,
            scriptText: scriptText,
            handoffCueText: handoffCueText,
            tags: tags,
            expectsAbstention: expectsAbstention,
            contextSummary: contextSummary,
            optionASource: modelFirst ? .onDeviceModel : .authoredBaseline,
            optionBSource: modelFirst ? .authoredBaseline : .onDeviceModel,
            optionASuggestion: modelFirst ? model : authored,
            optionBSuggestion: modelFirst ? authored : model,
            modelLatencyMilliseconds: latencyMS,
            modelFellBackToAuthored: model.origin == .authoredFallback,
            modelFallbackSummary: model.fallbackReason?.userSummary,
            rating: nil
        )
    }

    func postTakeContextSummary(for evalCase: PostTakeEvaluationCase) -> String {
        var parts: [String] = [
            "Status: \(evalCase.attemptStatus.displayName)",
            "Mode: \(evalCase.practiceMode.displayName)",
            "Duration: \(String(format: "%.1fs", evalCase.playableDuration))",
            "Reveals: \(evalCase.revealCount)"
        ]
        if let wpm = evalCase.estimatedWordsPerMinute {
            parts.append("Est. Pace: \(Int(wpm.rounded())) WPM")
        }
        if !evalCase.observations.isEmpty {
            parts.append("Observations: \(evalCase.observations.count)")
        }
        if !evalCase.ambiguousNotes.isEmpty {
            parts.append("Ambiguous notes: \(evalCase.ambiguousNotes.count)")
        }
        return parts.joined(separator: " · ")
    }

    func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
    }

    static func normalizedTokens(_ text: String) -> Set<String> {
        let parts = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}
