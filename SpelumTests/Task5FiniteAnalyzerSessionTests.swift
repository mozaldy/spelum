import CoreMedia
import Foundation
import Speech
import Testing
@testable import Spelum

@Suite("Task 5 Review Regressions — Finite SpeechAnalyzer Session Lifetime")
@MainActor
struct Task5FiniteAnalyzerSessionTests {
    @Test("Finding 6: finite session finalizes through last-sample CMTime and preserves cross-batch barriers")
    func finiteAnalyzerFinalizesThroughLastSampleTimeAndPreservesBarriers() async throws {
        let lastTime = CMTime(seconds: 4.0, preferredTimescale: 44_100)
        let session = MockFiniteSpeechAnalyzerSession(
            batches: [
                (makeTimedWord("Today ", start: 0.5, end: 1.0), true),
                (AttributedString("slowly "), true),
                (makeTimedWord("unveil", start: 2.0, end: 2.5), true)
            ],
            analyzeOutcome: .returnTime(lastTime)
        )

        let output = try await AppleSpeechTakeTranscriber.runFiniteAnalyzerSession(
            session,
            localeIdentifier: "en_US"
        )
        let snapshot = await session.snapshot()
        #expect(snapshot.finalizedThrough == lastTime)
        #expect(snapshot.cancelCount == 0)
        #expect(snapshot.consumerExited)
        #expect(output.segments.map(\.text) == ["Today", "unveil"])
        #expect(output.hasUntimedFinalText)
        #expect(output.untimedFragments.count == 1)
        #expect(output.untimedFragments[0].text == "slowly")
        #expect(output.untimedFragments[0].insertionIndex == 1)
    }

    @Test("Finding 6: nil or non-numeric CMTime calls cancelAndFinishNow and terminates consumer cleanly")
    func finiteAnalyzerCancelsCleanlyOnNilOrInvalidLastSampleTime() async throws {
        let nonFinalizableTimes: [CMTime?] = [
            nil,
            .indefinite,
            .invalid,
            .positiveInfinity,
            CMTime(seconds: -0.5, preferredTimescale: 600)
        ]

        for candidate in nonFinalizableTimes {
            for throwCancelOnAbort in [false, true] {
                let session = MockFiniteSpeechAnalyzerSession(
                    batches: [],
                    analyzeOutcome: .returnTime(candidate),
                    throwCancellationOnAbort: throwCancelOnAbort
                )
                let output = try await AppleSpeechTakeTranscriber.runFiniteAnalyzerSession(
                    session,
                    localeIdentifier: "en_US"
                )
                let snapshot = await session.snapshot()
                #expect(snapshot.finalizedThrough == nil)
                #expect(snapshot.cancelCount >= 1)
                #expect(snapshot.consumerExited)
                #expect(output.segments.isEmpty)
                #expect(!output.hasUntimedFinalText)
            }
        }
    }

    @Test("Finding 6: errors and external cancellation cancel session and terminate consumer without hanging")
    func finiteAnalyzerTerminatesConsumerOnErrorsAndExternalCancellation() async throws {
        struct SyntheticFailure: Error {}

        let analyzeFail = MockFiniteSpeechAnalyzerSession(
            batches: [],
            analyzeOutcome: .throwError(SyntheticFailure())
        )
        await #expect(throws: TakeTranscriptionError.self) {
            _ = try await AppleSpeechTakeTranscriber.runFiniteAnalyzerSession(
                analyzeFail,
                localeIdentifier: "en_US"
            )
        }
        let analyzeSnap = await analyzeFail.snapshot()
        #expect(analyzeSnap.cancelCount >= 1)
        #expect(analyzeSnap.consumerExited)

        let finalizeFail = MockFiniteSpeechAnalyzerSession(
            batches: [],
            analyzeOutcome: .returnTime(CMTime(seconds: 2.0, preferredTimescale: 600)),
            finalizeError: SyntheticFailure()
        )
        await #expect(throws: TakeTranscriptionError.self) {
            _ = try await AppleSpeechTakeTranscriber.runFiniteAnalyzerSession(
                finalizeFail,
                localeIdentifier: "en_US"
            )
        }
        let finalizeSnap = await finalizeFail.snapshot()
        #expect(finalizeSnap.cancelCount >= 1)
        #expect(finalizeSnap.consumerExited)

        let consumerFail = MockFiniteSpeechAnalyzerSession(
            batches: [],
            analyzeOutcome: .suspendUntilCancelled,
            consumerError: SyntheticFailure()
        )
        await #expect(throws: TakeTranscriptionError.self) {
            _ = try await AppleSpeechTakeTranscriber.runFiniteAnalyzerSession(
                consumerFail,
                localeIdentifier: "en_US"
            )
        }
        let consumerSnap = await consumerFail.snapshot()
        #expect(consumerSnap.cancelCount >= 1)
        #expect(consumerSnap.consumerExited)

        let externalCancel = MockFiniteSpeechAnalyzerSession(
            batches: [],
            analyzeOutcome: .suspendUntilCancelled
        )
        let runningTask = Task {
            try await AppleSpeechTakeTranscriber.runFiniteAnalyzerSession(
                externalCancel,
                localeIdentifier: "en_US"
            )
        }
        await externalCancel.waitUntilBothStarted()
        runningTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await runningTask.value
        }
        let cancelSnap = await externalCancel.snapshot()
        #expect(cancelSnap.cancelCount >= 1)
        #expect(cancelSnap.consumerExited)
    }

    private func makeTimedWord(_ text: String, start: TimeInterval, end: TimeInterval) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        return attributed
    }
}

private actor MockFiniteSpeechAnalyzerSession: FiniteSpeechAnalyzerSession {
    enum AnalyzeOutcome: Sendable {
        case returnTime(CMTime?)
        case throwError(any Error)
        case suspendUntilCancelled
    }

    struct Snapshot: Sendable {
        let finalizedThrough: CMTime?
        let cancelCount: Int
        let consumerExited: Bool
    }

    private let batches: [(AttributedString, Bool)]
    private let analyzeOutcome: AnalyzeOutcome
    private let finalizeError: (any Error)?
    private let consumerError: (any Error)?
    private let throwCancellationOnAbort: Bool

    private var consumerStarted = false
    private var driverStarted = false
    private var hasYieldedBatches = false
    private var consumerExited = false
    private var finalizedThrough: CMTime?
    private var cancelCount = 0
    private var streamContinuation: AsyncThrowingStream<(AttributedString, Bool), Error>.Continuation?
    private var driverContinuation: CheckedContinuation<CMTime?, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStreamClosed = false

    init(
        batches: [(AttributedString, Bool)],
        analyzeOutcome: AnalyzeOutcome,
        finalizeError: (any Error)? = nil,
        consumerError: (any Error)? = nil,
        throwCancellationOnAbort: Bool = false
    ) {
        self.batches = batches
        self.analyzeOutcome = analyzeOutcome
        self.finalizeError = finalizeError
        self.consumerError = consumerError
        self.throwCancellationOnAbort = throwCancellationOnAbort
    }

    func collectResults(localeIdentifier: String) async throws -> SpeechTranscriptionOutput {
        defer { consumerExited = true }
        consumerStarted = true
        notifyIfBothStarted()

        if let consumerError {
            throw consumerError
        }

        let stream = makeResultStream()
        var accumulator = SpeechResultStreamAccumulator(localeIdentifier: localeIdentifier)
        for try await (text, isFinal) in stream {
            try Task.checkCancellation()
            accumulator.append(text: text, isFinal: isFinal)
        }
        return accumulator.finish()
    }

    func analyzeInputFile() async throws -> CMTime? {
        driverStarted = true
        notifyIfBothStarted()
        yieldBatchesIfNeeded()

        switch analyzeOutcome {
        case .returnTime(let time):
            return time
        case .throwError(let error):
            throw error
        case .suspendUntilCancelled:
            if cancelCount > 0 {
                throw CancellationError()
            }
            return try await withCheckedThrowingContinuation { continuation in
                driverContinuation = continuation
            }
        }
    }

    func finalizeAndFinish(through time: CMTime) async throws {
        finalizedThrough = time
        if let finalizeError {
            throw finalizeError
        }
        yieldBatchesIfNeeded()
        closeStream(error: nil)
    }

    func cancelAndFinishNow() async {
        cancelCount += 1
        let abortError: (any Error)? = throwCancellationOnAbort ? CancellationError() : nil
        closeStream(error: abortError)
        driverContinuation?.resume(throwing: CancellationError())
        driverContinuation = nil
    }

    func waitUntilBothStarted() async {
        if consumerStarted && driverStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            finalizedThrough: finalizedThrough,
            cancelCount: cancelCount,
            consumerExited: consumerExited
        )
    }

    private func makeResultStream() -> AsyncThrowingStream<(AttributedString, Bool), Error> {
        let alreadyClosed = isStreamClosed
        let shouldReplay = !hasYieldedBatches && finalizedThrough != nil
        let bufferedBatches = batches
        return AsyncThrowingStream { continuation in
            if alreadyClosed {
                if shouldReplay {
                    hasYieldedBatches = true
                    for batch in bufferedBatches {
                        continuation.yield(batch)
                    }
                }
                if cancelCount > 0 && throwCancellationOnAbort {
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.finish()
                }
                return
            }
            streamContinuation = continuation
            if driverStarted {
                yieldBatchesIfNeeded()
            }
        }
    }

    private func yieldBatchesIfNeeded() {
        guard !hasYieldedBatches, !isStreamClosed, let streamContinuation else { return }
        hasYieldedBatches = true
        for batch in batches {
            streamContinuation.yield(batch)
        }
    }

    private func closeStream(error: (any Error)?) {
        guard !isStreamClosed else { return }
        isStreamClosed = true
        if let error {
            streamContinuation?.finish(throwing: error)
        } else {
            streamContinuation?.finish()
        }
        streamContinuation = nil
    }

    private func notifyIfBothStarted() {
        guard consumerStarted && driverStarted else { return }
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
