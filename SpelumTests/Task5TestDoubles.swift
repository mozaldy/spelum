import Foundation
import SwiftData
@testable import Spelum

struct TimingFixtureBundle: Decodable {
    struct Segment: Decodable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let isFinal: Bool
    }

    struct Case: Decodable {
        let id: String
        let description: String
        let elapsedAudioDuration: TimeInterval
        let localeIdentifier: String
        let scriptText: String
        let exactPhrase: String?
        let cueWords: [String]
        let hasMultipleSpeakersOrHandoff: Bool
        let segments: [Segment]
    }

    let fixtures: [Case]
}

private final class TimingFixtureBundleLocator {}

enum TimingFixtureLoader {
    static func fixture(id: String) throws -> TimingFixtureBundle.Case {
        let bundle = Bundle(for: TimingFixtureBundleLocator.self)
        let candidateURLs: [URL?] = [
            bundle.url(forResource: "TimingFixtureSet", withExtension: "json", subdirectory: "Fixtures"),
            bundle.url(forResource: "TimingFixtureSet", withExtension: "json")
        ]
        guard let url = candidateURLs.compactMap({ $0 }).first else {
            throw NSError(domain: "TimingFixtureLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing TimingFixtureSet.json in test bundle."
            ])
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(TimingFixtureBundle.self, from: data)
        guard let matched = decoded.fixtures.first(where: { $0.id == id }) else {
            throw NSError(domain: "TimingFixtureLoader", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Fixture '\(id)' not found."
            ])
        }
        return matched
    }

    static func makeInput(from fixture: TimingFixtureBundle.Case) -> TimingAnalysisInput {
        TimingAnalysisInput(
            attemptID: UUID(),
            talkRevisionID: UUID(),
            sectionRevisionID: UUID(),
            elapsedAudioDuration: fixture.elapsedAudioDuration,
            scriptText: fixture.scriptText,
            exactPhrase: fixture.exactPhrase,
            cueWords: fixture.cueWords,
            hasMultipleSpeakersOrHandoff: fixture.hasMultipleSpeakersOrHandoff,
            segments: fixture.segments.map { segment in
                TimedTranscriptSegment(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    confidence: 0.95,
                    isFinal: segment.isFinal,
                    localeIdentifier: fixture.localeIdentifier
                )
            },
            localeIdentifier: fixture.localeIdentifier,
            hasUntimedFinalText: false
        )
    }
}

actor ControlledTakeTranscriber: TakeTranscribing {
    typealias InstallHandler = @Sendable (@escaping @Sendable (Double?) -> Void) async throws -> Void
    typealias TranscribeHandler = @Sendable (URL, String) async throws -> SpeechTranscriptionOutput

    var availability: SpeechAvailabilityState
    var installBehavior: InstallHandler
    var transcribeBehavior: TranscribeHandler

    private(set) var availabilityCallCount = 0
    private(set) var installCallCount = 0
    private(set) var transcribeCallCount = 0

    init(
        availability: SpeechAvailabilityState = .ready(localeIdentifier: "en_US"),
        installBehavior: @escaping InstallHandler = { progress in progress(1.0) },
        transcribeBehavior: @escaping TranscribeHandler = { _, locale in
            SpeechTranscriptionOutput(localeIdentifier: locale, segments: [], hasUntimedFinalText: false)
        }
    ) {
        self.availability = availability
        self.installBehavior = installBehavior
        self.transcribeBehavior = transcribeBehavior
    }

    func setAvailability(_ newValue: SpeechAvailabilityState) {
        availability = newValue
    }

    func setInstallBehavior(_ newBehavior: @escaping InstallHandler) {
        installBehavior = newBehavior
    }

    func setTranscribeBehavior(_ newBehavior: @escaping TranscribeHandler) {
        transcribeBehavior = newBehavior
    }

    func checkAvailability(preferredLocale: Locale) async -> SpeechAvailabilityState {
        availabilityCallCount += 1
        return availability
    }

    func installAssets(
        for localeIdentifier: String,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        installCallCount += 1
        try await installBehavior(onProgress)
    }

    func transcribeAudioFile(at url: URL, localeIdentifier: String) async throws -> SpeechTranscriptionOutput {
        transcribeCallCount += 1
        return try await transcribeBehavior(url, localeIdentifier)
    }
}

actor TranscriptionGate {
    private var continuations: [CheckedContinuation<SpeechTranscriptionOutput, Error>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivedCount = 0

    func waitForOutput() async throws -> SpeechTranscriptionOutput {
        arrivedCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func waitUntilStarted(count expectedCount: Int = 1) async {
        if arrivedCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeNext(with result: Result<SpeechTranscriptionOutput, Error>) {
        guard !continuations.isEmpty else { return }
        let next = continuations.removeFirst()
        next.resume(with: result)
    }

    func cancelAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
struct SeededAudioTake {
    let container: ModelContainer
    let seeded: SeededSectionFixture
    let attemptStore: AttemptStore
    let attempt: AttemptRecord
    let audioURL: URL
}

@MainActor
enum Task5TestHelpers {
    static func seedAudioTake(
        in workspace: PracticeTestWorkspace,
        duration: Double
    ) throws -> SeededAudioTake {
        let container = try PresentationStore.makeModelContainer(storeURL: workspace.storeURL)
        let library = PresentationStore(modelContext: container.mainContext)
        let seeded = try PracticeTestFixtures.seedPresentation(in: library)
        let attemptStore = AttemptStore(
            modelContext: container.mainContext,
            storageRootURL: workspace.storageRoot
        )
        let saved = try PracticeTestFixtures.saveSyntheticTake(
            in: attemptStore,
            snapshot: seeded.snapshot,
            mode: .cueWords,
            durationSeconds: duration
        )
        return SeededAudioTake(
            container: container,
            seeded: seeded,
            attemptStore: attemptStore,
            attempt: saved.attempt,
            audioURL: saved.audioURL
        )
    }

    static func makeContext(
        attempt: AttemptRecord,
        audioURL: URL,
        section: SectionRevisionRecord
    ) -> TakeAnalysisRequestContext {
        TakeAnalysisRequestContext(
            attemptID: attempt.id,
            talkRevisionID: attempt.talkRevisionID,
            sectionRevisionID: attempt.sectionRevisionID,
            relativeAudioPath: attempt.relativeAudioPath,
            audioURL: audioURL,
            elapsedAudioDuration: attempt.playableDuration,
            hasPlayableAudio: attempt.hasPlayableAudio,
            isSilentRecall: attempt.isSilentRecall,
            scriptText: section.text,
            exactPhrase: section.exactPhrase,
            cueWords: section.cueWords,
            hasMultipleSpeakersOrHandoff: false
        )
    }

    nonisolated static func fiveWordSampleSegments() -> [TimedTranscriptSegment] {
        [
            TimedTranscriptSegment(text: "Today", startTime: 0.4, endTime: 0.8),
            TimedTranscriptSegment(text: "we", startTime: 0.85, endTime: 1.0),
            TimedTranscriptSegment(text: "unveil", startTime: 1.05, endTime: 1.4),
            TimedTranscriptSegment(text: "Spelum", startTime: 1.45, endTime: 1.9),
            TimedTranscriptSegment(text: "offline.", startTime: 1.95, endTime: 2.4)
        ]
    }
}
