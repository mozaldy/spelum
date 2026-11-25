import Foundation
import Observation

struct TakeAnalysisRequestContext: Equatable, Sendable {
    let attemptID: UUID
    let talkRevisionID: UUID
    let sectionRevisionID: UUID
    let relativeAudioPath: String?
    let audioURL: URL?
    let elapsedAudioDuration: TimeInterval
    let hasPlayableAudio: Bool
    let isSilentRecall: Bool
    let scriptText: String
    let exactPhrase: String?
    let cueWords: [String]
    let hasMultipleSpeakersOrHandoff: Bool
}

enum TakeAnalysisUnavailableKind: Equatable, Sendable {
    case noAudio
    case unsupportedDevice
    case unsupportedLocale
    case permissionDenied
}

enum TakeAnalysisPhase: Equatable, Sendable {
    case idle
    case checkingAvailability
    case analyzing(localeIdentifier: String, previousResult: TimingAnalysisResult?)
    case installingAssets(localeIdentifier: String, fractionCompleted: Double?)
    case completed(TimingAnalysisResult)
    case declined
    case assetsNotInstalled(localeIdentifier: String)
    case unavailable(kind: TakeAnalysisUnavailableKind, reason: String)
    case cancelled(previousResult: TimingAnalysisResult?)
    case failed(message: String, canRetry: Bool, previousResult: TimingAnalysisResult?)

    var isBusy: Bool {
        switch self {
        case .checkingAvailability, .analyzing, .installingAssets: true
        default: false
        }
    }

    var displayedResult: TimingAnalysisResult? {
        switch self {
        case .completed(let result): result
        case .analyzing(_, let previous), .cancelled(let previous), .failed(_, _, let previous): previous
        default: nil
        }
    }
}

@Observable
@MainActor
final class TakeAnalysisCoordinator {
    let transcriber: any TakeTranscribing
    let preferredLocaleProvider: () -> Locale
    let nowProvider: () -> Date

    var phase: TakeAnalysisPhase = .idle
    var boundAttemptID: UUID?
    var activeRunID: UUID?
    var activeTask: Task<Void, Never>?

    init(
        transcriber: (any TakeTranscribing)? = nil,
        preferredLocaleProvider: @escaping () -> Locale = { Locale.current },
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.transcriber = transcriber ?? AppleSpeechTakeTranscriber()
        self.preferredLocaleProvider = preferredLocaleProvider
        self.nowProvider = nowProvider
    }

    func loadOrAnalyzeIfReady(
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore
    ) {
        if boundAttemptID == context.attemptID, activeTask != nil, phase.isBusy {
            return
        }
        if boundAttemptID != context.attemptID {
            cancelActiveTaskSilently()
            boundAttemptID = context.attemptID
        }

        guard context.hasPlayableAudio, context.audioURL != nil else {
            let reason = context.isSilentRecall
                ? "Silent recall take — local audio transcription requires a recorded take."
                : "No playable audio file is available for local transcription."
            phase = .unavailable(kind: .noAudio, reason: reason)
            return
        }

        if let existing = (try? attemptStore.attempt(withID: context.attemptID))?.timingAnalysis {
            switch existing.outcome {
            case .completed:
                phase = .completed(existing)
                return
            case .declined:
                phase = .declined
                return
            }
        }

        startAnalysisRun(context: context, attemptStore: attemptStore, previousResult: nil)
    }

    func reanalyze(
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore
    ) {
        boundAttemptID = context.attemptID
        guard context.hasPlayableAudio, context.audioURL != nil else {
            let reason = context.isSilentRecall
                ? "Silent recall take — local audio transcription requires a recorded take."
                : "No playable audio file is available for local transcription."
            phase = .unavailable(kind: .noAudio, reason: reason)
            return
        }

        let persisted = (try? attemptStore.attempt(withID: context.attemptID))?.timingAnalysis
        let previousCompleted = (persisted?.outcome == .completed) ? persisted : nil
        startAnalysisRun(context: context, attemptStore: attemptStore, previousResult: previousCompleted)
    }

    func installAssetsAndAnalyze(
        localeIdentifier: String,
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore
    ) {
        boundAttemptID = context.attemptID
        guard context.hasPlayableAudio, context.audioURL != nil else {
            phase = .unavailable(kind: .noAudio, reason: "No playable audio file is available.")
            return
        }

        cancelActiveTaskSilently()
        let runID = UUID()
        activeRunID = runID
        let persisted = (try? attemptStore.attempt(withID: context.attemptID))?.timingAnalysis
        let previousCompleted = (persisted?.outcome == .completed) ? persisted : nil
        phase = .installingAssets(localeIdentifier: localeIdentifier, fractionCompleted: nil)

        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.performInstallAndAnalyze(
                localeIdentifier: localeIdentifier,
                context: context,
                attemptStore: attemptStore,
                previousCompleted: previousCompleted,
                runID: runID
            )
        }
    }

    func decline(
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore
    ) {
        cancelActiveTaskSilently()
        boundAttemptID = context.attemptID

        let existingAnalysis = (try? attemptStore.attempt(withID: context.attemptID))?.timingAnalysis
        let previousVersion = existingAnalysis?.analysisVersion ?? 0
        let declinedResult = TimingAnalysisResult.declined(
            attemptID: context.attemptID,
            talkRevisionID: context.talkRevisionID,
            sectionRevisionID: context.sectionRevisionID,
            elapsedAudioDuration: context.elapsedAudioDuration,
            previousVersion: previousVersion,
            at: nowProvider()
        )
        _ = try? attemptStore.saveTimingAnalysis(
            declinedResult,
            forAttemptID: context.attemptID,
            expectedRelativeAudioPath: context.relativeAudioPath,
            expectedTalkRevisionID: context.talkRevisionID,
            expectedSectionRevisionID: context.sectionRevisionID
        )
        phase = .declined
    }

    func cancelActiveOperation() {
        let previous = phase.displayedResult
        cancelActiveTaskSilently()
        phase = previous.map { .completed($0) } ?? .cancelled(previousResult: nil)
    }

    func invalidateForDeletion() {
        cancelActiveTaskSilently()
        boundAttemptID = nil
        phase = .idle
    }

    func handleViewDisappear() {
        let previous = phase.displayedResult
        let wasBusy = phase.isBusy
        cancelActiveTaskSilently()
        if wasBusy {
            phase = previous.map { .completed($0) } ?? .idle
        }
    }

    func waitForActiveTask() async {
        await activeTask?.value
    }
}

private extension TakeAnalysisCoordinator {
    func performInstallAndAnalyze(
        localeIdentifier: String,
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore,
        previousCompleted: TimingAnalysisResult?,
        runID: UUID
    ) async {
        do {
            try await transcriber.installAssets(for: localeIdentifier) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.activeRunID == runID else { return }
                    self.phase = .installingAssets(
                        localeIdentifier: localeIdentifier,
                        fractionCompleted: fraction
                    )
                }
            }
            guard isRunCurrent(runID, for: context.attemptID) else { return }
            await executeTranscription(
                localeIdentifier: localeIdentifier,
                context: context,
                attemptStore: attemptStore,
                previousResult: previousCompleted,
                runID: runID
            )
        } catch is CancellationError {
            guard isRunCurrent(runID, for: context.attemptID) else { return }
            finishCancellation(previousResult: previousCompleted)
        } catch {
            guard isRunCurrent(runID, for: context.attemptID) else { return }
            finishFailure(error: error, previousResult: previousCompleted)
        }
    }

    func startAnalysisRun(
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore,
        previousResult: TimingAnalysisResult?
    ) {
        cancelActiveTaskSilently()
        let runID = UUID()
        activeRunID = runID
        phase = .checkingAvailability

        activeTask = Task { [weak self] in
            guard let self else { return }
            let availability = await self.transcriber.checkAvailability(
                preferredLocale: self.preferredLocaleProvider()
            )
            guard self.isRunCurrent(runID, for: context.attemptID) else { return }
            await self.handleAvailability(
                availability,
                context: context,
                attemptStore: attemptStore,
                previousResult: previousResult,
                runID: runID
            )
        }
    }

    func handleAvailability(
        _ availability: SpeechAvailabilityState,
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore,
        previousResult: TimingAnalysisResult?,
        runID: UUID
    ) async {
        switch availability {
        case .ready(let localeIdentifier):
            await executeTranscription(
                localeIdentifier: localeIdentifier,
                context: context,
                attemptStore: attemptStore,
                previousResult: previousResult,
                runID: runID
            )
            return
        case .assetsNotInstalled(let localeIdentifier):
            phase = .assetsNotInstalled(localeIdentifier: localeIdentifier)
        case .downloadingAssets(let localeIdentifier, _):
            phase = .failed(
                message: "English speech assets (\(localeIdentifier)) are downloading in iOS. " +
                    "Retry once the download finishes.",
                canRetry: true,
                previousResult: previousResult
            )
        case .unsupportedDevice(let reason):
            phase = .unavailable(kind: .unsupportedDevice, reason: reason)
        case .unsupportedLocale(let reason):
            phase = .unavailable(kind: .unsupportedLocale, reason: reason)
        case .permissionDenied(let reason):
            phase = .unavailable(kind: .permissionDenied, reason: reason)
        }
        activeRunID = nil
    }

    func executeTranscription(
        localeIdentifier: String,
        context: TakeAnalysisRequestContext,
        attemptStore: AttemptStore,
        previousResult: TimingAnalysisResult?,
        runID: UUID
    ) async {
        guard let audioURL = context.audioURL else {
            activeRunID = nil
            phase = .unavailable(kind: .noAudio, reason: "No playable audio file is available.")
            return
        }

        phase = .analyzing(localeIdentifier: localeIdentifier, previousResult: previousResult)

        do {
            let output = try await transcriber.transcribeAudioFile(at: audioURL, localeIdentifier: localeIdentifier)
            guard isRunCurrent(runID, for: context.attemptID) else { return }

            let result = TimingObservationsEngine.analyze(
                TimingAnalysisInput(
                    attemptID: context.attemptID,
                    talkRevisionID: context.talkRevisionID,
                    sectionRevisionID: context.sectionRevisionID,
                    elapsedAudioDuration: context.elapsedAudioDuration,
                    scriptText: context.scriptText,
                    exactPhrase: context.exactPhrase,
                    cueWords: context.cueWords,
                    hasMultipleSpeakersOrHandoff: context.hasMultipleSpeakersOrHandoff,
                    segments: output.segments,
                    localeIdentifier: output.localeIdentifier,
                    hasUntimedFinalText: output.hasUntimedFinalText,
                    analysisVersion: max(1, (previousResult?.analysisVersion ?? 0) + 1),
                    analyzedAt: nowProvider()
                )
            )

            let saved = try attemptStore.saveTimingAnalysis(
                result,
                forAttemptID: context.attemptID,
                expectedRelativeAudioPath: context.relativeAudioPath,
                expectedTalkRevisionID: context.talkRevisionID,
                expectedSectionRevisionID: context.sectionRevisionID
            )
            guard isRunCurrent(runID, for: context.attemptID) else { return }

            activeRunID = nil
            phase = saved ? .completed(result) : .idle
        } catch is CancellationError {
            guard isRunCurrent(runID, for: context.attemptID) else { return }
            finishCancellation(previousResult: previousResult)
        } catch {
            guard isRunCurrent(runID, for: context.attemptID) else { return }
            finishFailure(error: error, previousResult: previousResult)
        }
    }

    func isRunCurrent(_ runID: UUID, for attemptID: UUID) -> Bool {
        !Task.isCancelled && activeRunID == runID && boundAttemptID == attemptID
    }

    func finishCancellation(previousResult: TimingAnalysisResult?) {
        activeRunID = nil
        phase = previousResult.map { .completed($0) } ?? .cancelled(previousResult: nil)
    }

    func finishFailure(error: Error, previousResult: TimingAnalysisResult?) {
        activeRunID = nil
        guard let typed = error as? TakeTranscriptionError else {
            phase = .failed(message: error.localizedDescription, canRetry: true, previousResult: previousResult)
            return
        }
        switch typed {
        case .assetsNotInstalled(let localeID):
            phase = .assetsNotInstalled(localeIdentifier: localeID)
        case .unsupportedDevice(let reason):
            phase = .unavailable(kind: .unsupportedDevice, reason: reason)
        case .unsupportedLocale(let reason):
            phase = .unavailable(kind: .unsupportedLocale, reason: reason)
        case .permissionDenied(let reason):
            phase = .unavailable(kind: .permissionDenied, reason: reason)
        case .audioFileUnavailable, .assetReservationLimitReached, .assetDownloadFailed, .analysisFailed:
            phase = .failed(message: typed.localizedDescription, canRetry: true, previousResult: previousResult)
        }
    }

    func cancelActiveTaskSilently() {
        activeRunID = nil
        activeTask?.cancel()
        activeTask = nil
    }
}
