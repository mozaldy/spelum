import Foundation

@MainActor
extension TakeAnalysisCoordinator {
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
                    guard let self,
                          self.activeRunID == runID,
                          self.boundAttemptID == context.attemptID,
                          case .installingAssets(let activeLocale, _) = self.phase,
                          activeLocale == localeIdentifier else {
                        return
                    }
                    let sanitizedFraction = fraction.flatMap { value in
                        value.isFinite ? min(max(value, 0), 1) : nil
                    }
                    self.phase = .installingAssets(
                        localeIdentifier: localeIdentifier,
                        fractionCompleted: sanitizedFraction
                    )
                }
            }
            guard isRunCurrent(runID, for: context.attemptID),
                  case .installingAssets(let activeLocale, _) = phase,
                  activeLocale == localeIdentifier else {
                return
            }
            await executeTranscription(
                localeIdentifier: localeIdentifier,
                context: context,
                attemptStore: attemptStore,
                previousResult: previousCompleted,
                runID: runID
            )
        } catch is CancellationError {
            guard isRunCurrent(runID, for: context.attemptID),
                  case .installingAssets = phase else {
                return
            }
            finishCancellation(previousResult: previousCompleted)
        } catch {
            guard isRunCurrent(runID, for: context.attemptID),
                  case .installingAssets = phase else {
                return
            }
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
            guard self.isRunCurrent(runID, for: context.attemptID),
                  case .checkingAvailability = self.phase else {
                return
            }
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
            guard isRunCurrent(runID, for: context.attemptID),
                  case .analyzing = phase else {
                return
            }

            let result = TimingObservationsEngine.analyze(
                TimingAnalysisInput(
                    attemptID: context.attemptID,
                    talkRevisionID: context.talkRevisionID,
                    sectionRevisionID: context.sectionRevisionID,
                    elapsedAudioDuration: context.elapsedAudioDuration,
                    scriptText: context.scriptText,
                    exactPhrase: context.exactPhrase,
                    cueWords: context.cueWords,
                    knownSpeakerNames: context.knownSpeakerNames,
                    hasMultipleSpeakersOrHandoff: context.hasMultipleSpeakersOrHandoff,
                    segments: output.segments,
                    localeIdentifier: output.localeIdentifier,
                    hasUntimedFinalText: output.hasUntimedFinalText,
                    untimedFragments: output.untimedFragments,
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
            guard isRunCurrent(runID, for: context.attemptID),
                  case .analyzing = phase else {
                return
            }

            activeRunID = nil
            phase = saved ? .completed(result) : .idle
        } catch is CancellationError {
            guard isRunCurrent(runID, for: context.attemptID),
                  case .analyzing = phase else {
                return
            }
            finishCancellation(previousResult: previousResult)
        } catch {
            guard isRunCurrent(runID, for: context.attemptID),
                  case .analyzing = phase else {
                return
            }
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
