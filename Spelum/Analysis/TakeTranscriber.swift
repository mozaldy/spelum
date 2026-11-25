import AVFoundation
import CoreMedia
import Foundation
import Speech

nonisolated enum SpeechAvailabilityState: Equatable, Sendable {
    case ready(localeIdentifier: String)
    case assetsNotInstalled(localeIdentifier: String)
    case downloadingAssets(localeIdentifier: String, fractionCompleted: Double?)
    case unsupportedDevice(reason: String)
    case unsupportedLocale(reason: String)
    case permissionDenied(reason: String)
}

nonisolated struct SpeechTranscriptionOutput: Equatable, Sendable {
    let localeIdentifier: String
    let segments: [TimedTranscriptSegment]
    let hasUntimedFinalText: Bool
    let untimedFragments: [UntimedTranscriptFragment]

    init(
        localeIdentifier: String,
        segments: [TimedTranscriptSegment],
        hasUntimedFinalText: Bool,
        untimedFragments: [UntimedTranscriptFragment] = []
    ) {
        self.localeIdentifier = localeIdentifier
        self.segments = segments
        self.hasUntimedFinalText = hasUntimedFinalText
        self.untimedFragments = untimedFragments
    }
}

nonisolated enum TakeTranscriptionError: LocalizedError, Equatable, Sendable {
    case audioFileUnavailable
    case unsupportedDevice(String)
    case unsupportedLocale(String)
    case permissionDenied(String)
    case assetsNotInstalled(localeIdentifier: String)
    case assetReservationLimitReached
    case assetDownloadFailed(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioFileUnavailable:
            "The saved audio recording could not be opened for local analysis."
        case .unsupportedDevice(let reason):
            reason
        case .unsupportedLocale(let reason):
            reason
        case .permissionDenied(let reason):
            reason
        case .assetsNotInstalled(let localeIdentifier):
            "On-device English speech assets (\(localeIdentifier)) are not installed yet."
        case .assetReservationLimitReached:
            "This device reached its system limit for reserved on-device speech locales."
        case .assetDownloadFailed(let message):
            message
        case .analysisFailed(let message):
            message
        }
    }
}

nonisolated protocol TakeTranscribing: Sendable {
    func checkAvailability(preferredLocale: Locale) async -> SpeechAvailabilityState
    func installAssets(
        for localeIdentifier: String,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws
    func transcribeAudioFile(
        at url: URL,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptionOutput
}

nonisolated final class AppleSpeechTakeTranscriber: TakeTranscribing, Sendable {
    func checkAvailability(preferredLocale: Locale = .current) async -> SpeechAvailabilityState {
        guard SpeechTranscriber.isAvailable else {
            return .unsupportedDevice(
                reason: "On-device Apple SpeechTranscriber is not available on this device or simulator. " +
                    "Your recording remains playable offline."
            )
        }

        guard let locale = await resolveEnglishLocale(preferredLocale: preferredLocale) else {
            return .unsupportedLocale(
                reason: "No supported on-device English locale was found for SpeechTranscriber."
            )
        }

        let transcriber = makeTranscriber(for: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return .ready(localeIdentifier: locale.identifier)
        case .supported:
            return .assetsNotInstalled(localeIdentifier: locale.identifier)
        case .downloading:
            return .downloadingAssets(localeIdentifier: locale.identifier, fractionCompleted: nil)
        case .unsupported:
            return .unsupportedLocale(
                reason: "On-device English speech assets are not supported on this device."
            )
        @unknown default:
            return .unsupportedDevice(
                reason: "On-device speech asset status could not be determined."
            )
        }
    }

    func installAssets(
        for localeIdentifier: String,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TakeTranscriptionError.unsupportedDevice(
                "On-device Apple SpeechTranscriber is not available on this device."
            )
        }
        guard let locale = await resolveEnglishLocale(preferredLocale: Locale(identifier: localeIdentifier)) else {
            throw TakeTranscriptionError.unsupportedLocale(
                "English on-device speech assets are not supported on this device."
            )
        }

        try await reserveLocaleIfNeeded(locale)
        let transcriber = makeTranscriber(for: locale)

        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                onProgress(1.0)
                return
            }

            let progress = request.progress
            let observerTask = Task {
                while !Task.isCancelled {
                    let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
                    onProgress(fraction)
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { observerTask.cancel() }

            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                progress.cancel()
            }
            observerTask.cancel()
            await observerTask.value
            onProgress(1.0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapAssetInstallError(error)
        }
    }

    func transcribeAudioFile(
        at url: URL,
        localeIdentifier: String
    ) async throws -> SpeechTranscriptionOutput {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TakeTranscriptionError.audioFileUnavailable
        }
        guard SpeechTranscriber.isAvailable else {
            throw TakeTranscriptionError.unsupportedDevice(
                "On-device Apple SpeechTranscriber is not available on this device."
            )
        }
        guard let locale = await resolveEnglishLocale(preferredLocale: Locale(identifier: localeIdentifier)) else {
            throw TakeTranscriptionError.unsupportedLocale(
                "No supported on-device English locale was found."
            )
        }

        let transcriber = makeTranscriber(for: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            throw TakeTranscriptionError.assetsNotInstalled(localeIdentifier: locale.identifier)
        }

        try await reserveLocaleIfNeeded(locale)
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TakeTranscriptionError.audioFileUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let session = AppleFiniteSpeechAnalyzerSession(
            analyzer: analyzer,
            transcriber: transcriber,
            audioFile: audioFile
        )
        return try await Self.runFiniteAnalyzerSession(
            session,
            localeIdentifier: locale.identifier
        )
    }

    private func makeTranscriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private func resolveEnglishLocale(preferredLocale: Locale) async -> Locale? {
        if preferredLocale.language.languageCode?.identifier.lowercased() == "en",
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) {
            return supported
        }
        if let usEnglish = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) {
            return usEnglish
        }
        let allSupported = await SpeechTranscriber.supportedLocales
        return allSupported.first { $0.language.languageCode?.identifier.lowercased() == "en" }
    }

    private func reserveLocaleIfNeeded(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        let alreadyReserved = reserved.contains { existing in
            existing.identifier.lowercased() == locale.identifier.lowercased()
        }
        guard !alreadyReserved else { return }
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch let speechError as SFSpeechError where speechError.code == .tooManyAssetLocalesAllocated {
            throw TakeTranscriptionError.assetReservationLimitReached
        } catch let speechError as SFSpeechError where speechError.code == .cannotAllocateUnsupportedLocale {
            throw TakeTranscriptionError.unsupportedLocale(
                "English on-device speech assets are not supported on this device."
            )
        } catch {
            throw mapAssetInstallError(error)
        }
    }

    private func mapAssetInstallError(_ error: Error) -> TakeTranscriptionError {
        if let typed = error as? TakeTranscriptionError {
            return typed
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .assetDownloadFailed(
                "Could not download English speech assets while offline or disconnected. " +
                    "Your recording stays ready to play offline."
            )
        }
        return .assetDownloadFailed(
            "English speech assets could not be installed: \(error.localizedDescription)"
        )
    }
}
