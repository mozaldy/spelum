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
    let knownSpeakerNames: [String]
    let hasMultipleSpeakersOrHandoff: Bool

    init(
        attemptID: UUID,
        talkRevisionID: UUID,
        sectionRevisionID: UUID,
        relativeAudioPath: String?,
        audioURL: URL?,
        elapsedAudioDuration: TimeInterval,
        hasPlayableAudio: Bool,
        isSilentRecall: Bool,
        scriptText: String,
        exactPhrase: String?,
        cueWords: [String],
        knownSpeakerNames: [String] = [],
        hasMultipleSpeakersOrHandoff: Bool
    ) {
        self.attemptID = attemptID
        self.talkRevisionID = talkRevisionID
        self.sectionRevisionID = sectionRevisionID
        self.relativeAudioPath = relativeAudioPath
        self.audioURL = audioURL
        self.elapsedAudioDuration = elapsedAudioDuration
        self.hasPlayableAudio = hasPlayableAudio
        self.isSilentRecall = isSilentRecall
        self.scriptText = scriptText
        self.exactPhrase = exactPhrase
        self.cueWords = cueWords
        self.knownSpeakerNames = knownSpeakerNames
        self.hasMultipleSpeakersOrHandoff = hasMultipleSpeakersOrHandoff
    }
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
    struct DeletionRecoveryToken {
        fileprivate let attemptID: UUID
        fileprivate let previousPhase: TakeAnalysisPhase
        fileprivate let wasBusy: Bool
    }

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

    func prepareForDeletion(attemptID: UUID) -> DeletionRecoveryToken {
        let token = DeletionRecoveryToken(
            attemptID: attemptID,
            previousPhase: phase,
            wasBusy: phase.isBusy
        )
        invalidateForDeletion()
        return token
    }

    func restoreAfterFailedDeletion(
        _ token: DeletionRecoveryToken,
        persistedAnalysis: TimingAnalysisResult? = nil
    ) {
        boundAttemptID = token.attemptID
        if token.wasBusy {
            let previousResult = token.previousPhase.displayedResult
                ?? (persistedAnalysis?.outcome == .completed ? persistedAnalysis : nil)
            phase = .cancelled(previousResult: previousResult)
            return
        }
        if case .idle = token.previousPhase, let persistedAnalysis {
            switch persistedAnalysis.outcome {
            case .completed:
                phase = .completed(persistedAnalysis)
            case .declined:
                phase = .declined
            }
            return
        }
        phase = token.previousPhase
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
