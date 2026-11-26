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

        let batch: SuiteBatchResult
        switch task {
        case .preparation:
            batch = await runPreparationBatch(
                cases: dataset.preparationCases,
                promptVersion: promptVersion,
                isModelAvailable: availability.isAvailable,
                isFreshProcessLaunchOverride: isFreshProcessLaunch,
                rng: &rng,
                onProgress: onProgress
            )
        case .postTake:
            batch = await runPostTakeBatch(
                cases: dataset.postTakeCases,
                promptVersion: promptVersion,
                isModelAvailable: availability.isAvailable,
                isFreshProcessLaunchOverride: isFreshProcessLaunch,
                rng: &rng,
                onProgress: onProgress
            )
        }

        let latencySummary = resolveLatencySummary(
            batch: batch,
            availability: availability,
            environment: environment
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
        let wasFreshLaunch: Bool
    }

    struct LatencySummary {
        let status: ColdLatencyMeasurementStatus
        let coldMS: Double?
        let warmMS: [Double]
    }

    func resolveLatencySummary(
        batch: SuiteBatchResult,
        availability: CoachingModelAvailability,
        environment: CoachingDeviceEnvironment
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
        if !batch.wasFreshLaunch {
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

    func consumeLaunchOrderIfNeeded(
        didConsume: inout Bool,
        wasFreshLaunch: inout Bool,
        isModelAvailable: Bool,
        override: Bool?
    ) async {
        guard !Task.isCancelled, !didConsume, isModelAvailable else { return }
        didConsume = true
        if let override {
            wasFreshLaunch = override
        } else {
            wasFreshLaunch = await CoachingEvaluationProcessState.shared.consumeFreshLaunchIfAvailable(
                modelAvailable: true
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    func runPreparationBatch(
        cases: [PreparationEvaluationCase],
        promptVersion: String,
        isModelAvailable: Bool,
        isFreshProcessLaunchOverride: Bool?,
        rng: inout SeededRandomGenerator,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async -> SuiteBatchResult {
        var entries: [BlindedEvaluationEntry] = []
        var firstCallLatency: Double?
        var subsequentLatencies: [Double] = []
        var repeatResults: [RepeatVariationResult] = []
        var didConsumeLaunch = false
        var wasFreshLaunch = false
        let total = cases.count

        for (index, evalCase) in cases.enumerated() {
            if Task.isCancelled { break }
            let request = evalCase.makeRequest(promptVersion: promptVersion)
            let authored = await coachService.generatePreparationCue(request: request, mode: .authoredBaseline)
            if Task.isCancelled { break }
            await consumeLaunchOrderIfNeeded(
                didConsume: &didConsumeLaunch,
                wasFreshLaunch: &wasFreshLaunch,
                isModelAvailable: isModelAvailable,
                override: isFreshProcessLaunchOverride
            )
            let (modelCue, elapsedMS) = await timedPreparation(request: request, isModelAvailable: isModelAvailable)
            if index == 0 { firstCallLatency = elapsedMS } else if let elapsedMS {
                subsequentLatencies.append(elapsedMS)
            }
            let entry = EvaluationEntryMetadata(from: evalCase).makeBlindedEntry(
                authored: authored,
                model: modelCue,
                latencyMS: elapsedMS,
                modelFirst: (rng.next() & 1) == 0
            )
            entries.append(entry)
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
            repeatResults: repeatResults,
            wasFreshLaunch: wasFreshLaunch
        )
    }

    // swiftlint:disable:next function_parameter_count
    func runPostTakeBatch(
        cases: [PostTakeEvaluationCase],
        promptVersion: String,
        isModelAvailable: Bool,
        isFreshProcessLaunchOverride: Bool?,
        rng: inout SeededRandomGenerator,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async -> SuiteBatchResult {
        var entries: [BlindedEvaluationEntry] = []
        var firstCallLatency: Double?
        var subsequentLatencies: [Double] = []
        var repeatResults: [RepeatVariationResult] = []
        var didConsumeLaunch = false
        var wasFreshLaunch = false
        let total = cases.count

        for (index, evalCase) in cases.enumerated() {
            if Task.isCancelled { break }
            let request = evalCase.makeRequest(promptVersion: promptVersion)
            let authored = await coachService.generatePostTakeCue(request: request, mode: .authoredBaseline)
            if Task.isCancelled { break }
            await consumeLaunchOrderIfNeeded(
                didConsume: &didConsumeLaunch,
                wasFreshLaunch: &wasFreshLaunch,
                isModelAvailable: isModelAvailable,
                override: isFreshProcessLaunchOverride
            )
            let (modelCue, elapsedMS) = await timedPostTake(request: request, isModelAvailable: isModelAvailable)
            if index == 0 { firstCallLatency = elapsedMS } else if let elapsedMS {
                subsequentLatencies.append(elapsedMS)
            }
            let entry = EvaluationEntryMetadata(from: evalCase).makeBlindedEntry(
                authored: authored,
                model: modelCue,
                latencyMS: elapsedMS,
                modelFirst: (rng.next() & 1) == 0
            )
            entries.append(entry)
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
            repeatResults: repeatResults,
            wasFreshLaunch: wasFreshLaunch
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

    func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return max(0, (seconds + attoseconds) * 1_000.0)
    }
}
