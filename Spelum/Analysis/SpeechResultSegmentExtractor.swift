import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

nonisolated protocol FiniteSpeechAnalyzerSession: Sendable {
    func collectResults(localeIdentifier: String) async throws -> SpeechTranscriptionOutput
    func analyzeInputFile() async throws -> CMTime?
    func finalizeAndFinish(through time: CMTime) async throws
    func cancelAndFinishNow() async
}

nonisolated enum SpeechResultSegmentExtractor {
    struct ExtractionResult: Equatable, Sendable {
        let segments: [TimedTranscriptSegment]
        let hasUntimedFinalText: Bool
        let untimedFragments: [UntimedTranscriptFragment]

        init(
            segments: [TimedTranscriptSegment],
            hasUntimedFinalText: Bool,
            untimedFragments: [UntimedTranscriptFragment] = []
        ) {
            self.segments = segments
            self.hasUntimedFinalText = hasUntimedFinalText
            self.untimedFragments = untimedFragments
        }
    }

    static func extract(
        from attributedText: AttributedString,
        isFinal: Bool,
        localeIdentifier: String
    ) -> ExtractionResult {
        guard isFinal else {
            return ExtractionResult(segments: [], hasUntimedFinalText: false, untimedFragments: [])
        }

        var segments: [TimedTranscriptSegment] = []
        var untimedFragments: [UntimedTranscriptFragment] = []
        var hasUntimedWords = false

        for run in attributedText.runs {
            let substring = String(attributedText[run.range].characters)
            let tokens = EnglishWordTokenizer.tokenize(substring, localeIdentifier: localeIdentifier)
            guard !tokens.isEmpty else {
                continue
            }
            let trimmedText = substring.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let timeRange = run.audioTimeRange,
                  timeRange.isValid,
                  !timeRange.isIndefinite,
                  !timeRange.isEmpty else {
                hasUntimedWords = true
                untimedFragments.append(
                    UntimedTranscriptFragment(
                        text: trimmedText,
                        insertionIndex: segments.count,
                        localeIdentifier: localeIdentifier
                    )
                )
                continue
            }

            let startSeconds = timeRange.start.seconds
            let endSeconds = timeRange.end.seconds
            guard startSeconds.isFinite,
                  endSeconds.isFinite,
                  startSeconds >= 0,
                  endSeconds > startSeconds else {
                hasUntimedWords = true
                untimedFragments.append(
                    UntimedTranscriptFragment(
                        text: trimmedText,
                        insertionIndex: segments.count,
                        localeIdentifier: localeIdentifier
                    )
                )
                continue
            }

            segments.append(
                TimedTranscriptSegment(
                    text: trimmedText,
                    startTime: startSeconds,
                    endTime: endSeconds,
                    confidence: run.transcriptionConfidence,
                    isFinal: true,
                    localeIdentifier: localeIdentifier
                )
            )
        }

        return ExtractionResult(
            segments: segments,
            hasUntimedFinalText: hasUntimedWords,
            untimedFragments: untimedFragments
        )
    }
}

nonisolated struct SpeechResultStreamAccumulator: Sendable {
    let localeIdentifier: String
    private(set) var segments: [TimedTranscriptSegment] = []
    private(set) var untimedFragments: [UntimedTranscriptFragment] = []
    private(set) var hasUntimedFinalText = false

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    mutating func append(text: AttributedString, isFinal: Bool) {
        let extracted = SpeechResultSegmentExtractor.extract(
            from: text,
            isFinal: isFinal,
            localeIdentifier: localeIdentifier
        )
        let baseOffset = segments.count
        for fragment in extracted.untimedFragments {
            untimedFragments.append(
                UntimedTranscriptFragment(
                    text: fragment.text,
                    insertionIndex: baseOffset + fragment.insertionIndex,
                    localeIdentifier: fragment.localeIdentifier
                )
            )
        }
        segments.append(contentsOf: extracted.segments)
        if extracted.hasUntimedFinalText {
            hasUntimedFinalText = true
        }
    }

    func finish() -> SpeechTranscriptionOutput {
        SpeechTranscriptionOutput(
            localeIdentifier: localeIdentifier,
            segments: segments,
            hasUntimedFinalText: hasUntimedFinalText,
            untimedFragments: untimedFragments
        )
    }
}

nonisolated final class AppleFiniteSpeechAnalyzerSession: FiniteSpeechAnalyzerSession, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let audioFile: AVAudioFile

    init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        audioFile: AVAudioFile
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.audioFile = audioFile
    }

    func collectResults(localeIdentifier: String) async throws -> SpeechTranscriptionOutput {
        var accumulator = SpeechResultStreamAccumulator(localeIdentifier: localeIdentifier)
        for try await result in transcriber.results {
            try Task.checkCancellation()
            accumulator.append(text: result.text, isFinal: result.isFinal)
        }
        return accumulator.finish()
    }

    func analyzeInputFile() async throws -> CMTime? {
        try await analyzer.analyzeSequence(from: audioFile)
    }

    func finalizeAndFinish(through time: CMTime) async throws {
        try await analyzer.finalizeAndFinish(through: time)
    }

    func cancelAndFinishNow() async {
        await analyzer.cancelAndFinishNow()
    }
}

nonisolated extension AppleSpeechTakeTranscriber {
    static func runFiniteAnalyzerSession(
        _ session: any FiniteSpeechAnalyzerSession,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptionOutput {
        try Task.checkCancellation()
        let emptyInputCancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: SpeechTranscriptionOutput?.self) { group in
                group.addTask {
                    try await session.collectResults(localeIdentifier: localeIdentifier)
                }
                group.addTask {
                    try await driveFiniteSessionInput(session, emptyInputCancelled: emptyInputCancelled)
                    return nil
                }
                var finalOutput: SpeechTranscriptionOutput?
                do {
                    for try await partial in group {
                        if let output = partial {
                            finalOutput = output
                        }
                    }
                } catch is CancellationError {
                    let wasEmptyInput = emptyInputCancelled.withLock { $0 }
                    group.cancelAll()
                    await session.cancelAndFinishNow()
                    if wasEmptyInput && !Task.isCancelled {
                        return emptyOutput(localeIdentifier: localeIdentifier)
                    }
                    throw CancellationError()
                } catch {
                    group.cancelAll()
                    await session.cancelAndFinishNow()
                    throw mapSpeechAnalysisError(error, localeIdentifier: localeIdentifier)
                }
                return finalOutput ?? emptyOutput(localeIdentifier: localeIdentifier)
            }
        } onCancel: {
            Task {
                await session.cancelAndFinishNow()
            }
        }
    }

    private static func driveFiniteSessionInput(
        _ session: any FiniteSpeechAnalyzerSession,
        emptyInputCancelled: OSAllocatedUnfairLock<Bool>
    ) async throws {
        do {
            let lastSampleTime = try await session.analyzeInputFile()
            if let lastSampleTime,
               lastSampleTime.isNumeric,
               lastSampleTime.seconds >= 0 {
                try await session.finalizeAndFinish(through: lastSampleTime)
            } else {
                emptyInputCancelled.withLock { $0 = true }
                await session.cancelAndFinishNow()
            }
        } catch {
            await session.cancelAndFinishNow()
            throw error
        }
    }

    private static func emptyOutput(localeIdentifier: String) -> SpeechTranscriptionOutput {
        SpeechTranscriptionOutput(
            localeIdentifier: localeIdentifier,
            segments: [],
            hasUntimedFinalText: false,
            untimedFragments: []
        )
    }

    private static func mapSpeechAnalysisError(
        _ error: Error,
        localeIdentifier: String
    ) -> TakeTranscriptionError {
        if let typed = error as? TakeTranscriptionError {
            return typed
        }
        if let speechError = error as? SFSpeechError {
            switch speechError.code {
            case .noModel, .assetLocaleNotAllocated:
                return .assetsNotInstalled(localeIdentifier: localeIdentifier)
            case .cannotAllocateUnsupportedLocale:
                return .unsupportedLocale("The selected English locale is unsupported on this device.")
            case .tooManyAssetLocalesAllocated:
                return .assetReservationLimitReached
            default:
                break
            }
        }
        return .analysisFailed("On-device transcription could not complete: \(error.localizedDescription)")
    }
}
