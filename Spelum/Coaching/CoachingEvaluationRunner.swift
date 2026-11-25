import Foundation

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
        isFreshProcessLaunch: Bool? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> CoachingEvaluationSession {
        var rng = SeededRandomGenerator(seed: randomSeed ?? UInt64.random(in: 1...UInt64.max))
        let availability = coachService.modelAvailability()
        let promptVersion = task == .preparation
            ? SectionCoachService.preparationPromptVersion
            : SectionCoachService.postTakePromptVersion
        let freshLaunch: Bool
        if let override = isFreshProcessLaunch {
            freshLaunch = override
        } else {
            freshLaunch = await CoachingEvaluationProcessState.shared.consumeFreshLaunchIfAvailable(
                modelAvailable: availability.isAvailable
            )
        }

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

        let latencySummary = resolveLatencySummary(
            batch: batch,
            availability: availability,
            environment: environment,
            wasFreshLaunch: freshLaunch
        )
        let now = Date()
        return CoachingEvaluationSession(
            id: UUID(),
            evaluationSchemaVersion: CoachingEvaluationSession.currentSchemaVersion,
            task: task,
            datasetVersion: dataset.datasetVersion,
            promptVersion: promptVersion,
            createdAt: now,
            updatedAt: now,
            environment: environment,
            modelAvailability: availability,
            isUnblinded: false,
            unblindedEarly: false,
            coldLatencyStatus: latencySummary.status,
            coldLatencyMilliseconds: latencySummary.coldMS,
            warmLatenciesMilliseconds: latencySummary.warmMS,
            repeatVariationResults: batch.repeatResults,
            entries: batch.entries
        )
    }

    static func tokenJaccardSimilarity(_ lhs: String, _ rhs: String) -> Double {
        CoachingEvaluationRepeatMetrics.tokenJaccardSimilarity(lhs, rhs)
    }
}

private extension CoachingEvaluationRunner {
    struct SuiteBatchResult {
        let entries: [BlindedEvaluationEntry]
        let firstCallLatencyMS: Double?
        let subsequentLatenciesMS: [Double]
        let repeatResults: [RepeatVariationResult]
    }

    struct LatencySummary {
        let status: ColdLatencyMeasurementStatus
        let coldMS: Double?
        let warmMS: [Double]
    }

    func resolveLatencySummary(
        batch: SuiteBatchResult,
        availability: CoachingModelAvailability,
        environment: CoachingDeviceEnvironment,
        wasFreshLaunch: Bool
    ) -> LatencySummary {
        guard availability.isAvailable else {
            return LatencySummary(status: .modelUnavailable, coldMS: nil, warmMS: [])
        }
        guard let firstLatency = batch.firstCallLatencyMS else {
            return LatencySummary(
                status: .firstCallFailed,
                coldMS: nil,
                warmMS: batch.subsequentLatenciesMS
            )
        }
        if environment.isSimulator {
            return LatencySummary(
                status: .simulatorNotPhysical,
                coldMS: nil,
                warmMS: [firstLatency] + batch.subsequentLatenciesMS
            )
        }
        if !wasFreshLaunch {
            return LatencySummary(
                status: .processAlreadyWarmed,
                coldMS: nil,
                warmMS: [firstLatency] + batch.subsequentLatenciesMS
            )
        }
        return LatencySummary(
            status: .verifiedColdLaunch,
            coldMS: firstLatency,
            warmMS: batch.subsequentLatenciesMS
        )
    }

    func runPreparationBatch(
        cases: [PreparationEvaluationCase],
        promptVersion: String,
        isModelAvailable: Bool,
        rng: inout SeededRandomGenerator,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async -> SuiteBatchResult {
        var entries: [BlindedEvaluationEntry] = []
        var firstCallLatency: Double?
        var subsequentLatencies: [Double] = []
        var repeatResults: [RepeatVariationResult] = []
        let total = cases.count

        for (index, evalCase) in cases.enumerated() {
            if Task.isCancelled { break }
            let request = evalCase.makeRequest(promptVersion: promptVersion)
            let authored = await coachService.generatePreparationCue(request: request, mode: .authoredBaseline)
            let (modelCue, elapsedMS) = await timedPreparation(
                request: request,
                isModelAvailable: isModelAvailable
            )
            if index == 0 {
                firstCallLatency = elapsedMS
            } else if let elapsedMS {
                subsequentLatencies.append(elapsedMS)
            }
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
                    contextSummary: "Purpose: \(evalCase.purpose.displayName)",
                    authored: authored,
                    model: modelCue,
                    latencyMS: elapsedMS,
                    rng: &rng
                )
            )
            onProgress?(index + 1, total)
        }

        for evalCase in cases where evalCase.includeInRepeatCheck {
            if Task.isCancelled { break }
            let item = await measurePreparationRepeatVariation(
                evalCase: evalCase,
                promptVersion: promptVersion,
                isModelAvailable: isModelAvailable
            )
            repeatResults.append(item)
        }
        return SuiteBatchResult(
            entries: entries,
            firstCallLatencyMS: firstCallLatency,
            subsequentLatenciesMS: subsequentLatencies,
            repeatResults: repeatResults
        )
    }

    func runPostTakeBatch(
        cases: [PostTakeEvaluationCase],
        promptVersion: String,
        isModelAvailable: Bool,
        rng: inout SeededRandomGenerator,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async -> SuiteBatchResult {
        var entries: [BlindedEvaluationEntry] = []
        var firstCallLatency: Double?
        var subsequentLatencies: [Double] = []
        var repeatResults: [RepeatVariationResult] = []
        let total = cases.count

        for (index, evalCase) in cases.enumerated() {
            if Task.isCancelled { break }
            let request = evalCase.makeRequest(promptVersion: promptVersion)
            let authored = await coachService.generatePostTakeCue(request: request, mode: .authoredBaseline)
            let (modelCue, elapsedMS) = await timedPostTake(
                request: request,
                isModelAvailable: isModelAvailable
            )
            if index == 0 {
                firstCallLatency = elapsedMS
            } else if let elapsedMS {
                subsequentLatencies.append(elapsedMS)
            }
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
            if Task.isCancelled { break }
            let item = await measurePostTakeRepeatVariation(
                evalCase: evalCase,
                promptVersion: promptVersion,
                isModelAvailable: isModelAvailable
            )
            repeatResults.append(item)
        }
        return SuiteBatchResult(
            entries: entries,
            firstCallLatencyMS: firstCallLatency,
            subsequentLatenciesMS: subsequentLatencies,
            repeatResults: repeatResults
        )
    }

    func timedPreparation(
        request: PreparationCoachingRequest,
        isModelAvailable: Bool
    ) async -> (CoachingSuggestion, Double?) {
        let clock = ContinuousClock()
        let start = clock.now
        let cue = await coachService.generatePreparationCue(request: request, mode: .onDeviceModel)
        let elapsedMS = durationMilliseconds(start.duration(to: clock.now))
        let measured = (isModelAvailable && cue.origin == .onDeviceModel) ? elapsedMS : nil
        return (cue, measured)
    }

    func timedPostTake(
        request: PostTakeCoachingRequest,
        isModelAvailable: Bool
    ) async -> (CoachingSuggestion, Double?) {
        let clock = ContinuousClock()
        let start = clock.now
        let cue = await coachService.generatePostTakeCue(request: request, mode: .onDeviceModel)
        let elapsedMS = durationMilliseconds(start.duration(to: clock.now))
        let measured = (isModelAvailable && cue.origin == .onDeviceModel) ? elapsedMS : nil
        return (cue, measured)
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
            if Task.isCancelled { break }
            let (cue, elapsedMS) = await timedPreparation(request: request, isModelAvailable: isModelAvailable)
            suggestions.append(cue)
            if let elapsedMS { trialLatencies.append(elapsedMS) }
        }
        return CoachingEvaluationRepeatMetrics.summarize(
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
            if Task.isCancelled { break }
            let (cue, elapsedMS) = await timedPostTake(request: request, isModelAvailable: isModelAvailable)
            suggestions.append(cue)
            if let elapsedMS { trialLatencies.append(elapsedMS) }
        }
        return CoachingEvaluationRepeatMetrics.summarize(
            id: evalCase.id,
            caseTitle: evalCase.title,
            suggestions: suggestions,
            latencies: trialLatencies
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
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return max(0, (seconds + attoseconds) * 1_000.0)
    }
}
