import SwiftUI

struct TakeReviewAnalysisCard: View {
    let phase: TakeAnalysisPhase
    let isAudioLoaded: Bool
    let currentPlaybackTime: TimeInterval
    let totalDuration: TimeInterval
    let isAccessibilitySize: Bool
    let onSeekObservation: (TimingObservation) -> Void
    let onAddManualMarker: (String) -> Void
    let onInstallAssets: (String) -> Void
    let onReanalyze: () -> Void
    let onDecline: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            statusAndContentSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("timingObservationsCard")
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Timing Observations (Estimates)", systemImage: "waveform.badge.magnifyingglass")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Derived from on-device English speech timing. Replay audio to judge delivery.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusAndContentSection: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .checkingAvailability:
            busyRow(message: "Checking on-device English speech availability…", progress: nil)
        case .analyzing(let locale, let previousResult):
            busyRow(message: "Analyzing take locally (\(locale))…", progress: nil)
            if let previousResult {
                Divider()
                resultView(previousResult, showReanalyzeAction: false)
            }
        case .installingAssets(let locale, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                busyRow(
                    message: "Installing on-device English speech assets (\(locale))…",
                    progress: fraction
                )
                Text("Your recording remains playable offline while assets install.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .assetsNotInstalled(let locale):
            assetsNotInstalledView(localeIdentifier: locale)
        case .unavailable(let kind, let reason):
            unavailableView(kind: kind, reason: reason)
        case .declined:
            declinedView
        case .cancelled(let previousResult):
            cancelledView(previousResult: previousResult)
        case .failed(let message, let canRetry, let previousResult):
            failedView(message: message, canRetry: canRetry, previousResult: previousResult)
        case .completed(let result):
            resultView(result, showReanalyzeAction: true)
        }
    }

    private func resultView(_ result: TimingAnalysisResult, showReanalyzeAction: Bool) -> some View {
        TakeReviewAnalysisResultContent(
            result: result,
            isAudioLoaded: isAudioLoaded,
            currentPlaybackTime: currentPlaybackTime,
            totalDuration: totalDuration,
            isAccessibilitySize: isAccessibilitySize,
            showReanalyzeAction: showReanalyzeAction,
            onSeekObservation: onSeekObservation,
            onAddManualMarker: onAddManualMarker,
            onReanalyze: onReanalyze
        )
    }

    private func busyRow(message: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1)) {
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(role: .cancel, action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("cancelAnalysisButton")
        }
    }

    private func assetsNotInstalledView(localeIdentifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("English Speech Assets Not Installed", systemImage: "icloud.and.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(
                "On-device English speech assets (\(localeIdentifier)) aren’t installed yet. " +
                "Playback and manual markers stay available offline. Install assets when online to " +
                "generate local timing observations."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("assetsNotInstalledMessage")

            TakeReviewActionPair(
                isAccessibilitySize: isAccessibilitySize,
                primary: .init(
                    title: "Install English Assets",
                    symbol: "arrow.down.circle",
                    id: "installSpeechAssetsButton",
                    action: { onInstallAssets(localeIdentifier) }
                ),
                secondary: .init(
                    title: "Skip for This Take",
                    symbol: "forward.end",
                    id: "skipAnalysisButton",
                    action: onDecline
                )
            )
        }
    }

    private func unavailableView(kind: TakeAnalysisUnavailableKind, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(kind.displayTitle, systemImage: kind.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("analysisUnavailableReason")

            if kind != .noAudio {
                Button(action: onReanalyze) {
                    Label("Check Availability Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("recheckSpeechAvailabilityButton")
            }
        }
    }

    private var declinedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local Analysis Skipped", systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Local transcription was skipped for this take. Playback and manual markers remain available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("analysisDeclinedMessage")

            Button(action: onReanalyze) {
                Label("Run Local Analysis", systemImage: "waveform.badge.magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("runLocalAnalysisButton")
        }
    }

    private func cancelledView(previousResult: TimingAnalysisResult?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Analysis Cancelled", systemImage: "xmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Local transcription stopped before finishing. Your saved recording is unchanged.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onReanalyze) {
                Label("Retry Analysis", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("retryAnalysisButton")

            if let previousResult {
                Divider()
                resultView(previousResult, showReanalyzeAction: false)
            }
        }
    }

    private func failedView(
        message: String,
        canRetry: Bool,
        previousResult: TimingAnalysisResult?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Analysis Could Not Finish", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("analysisFailureMessage")

            if canRetry {
                if previousResult == nil {
                    TakeReviewActionPair(
                        isAccessibilitySize: isAccessibilitySize,
                        primary: .init(
                            title: "Retry Analysis",
                            symbol: "arrow.clockwise",
                            id: "retryAnalysisButton",
                            action: onReanalyze
                        ),
                        secondary: .init(
                            title: "Skip for This Take",
                            symbol: "forward.end",
                            id: "skipAnalysisButton",
                            action: onDecline
                        )
                    )
                } else {
                    Button(action: onReanalyze) {
                        Label("Retry Analysis", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("retryAnalysisButton")
                }
            }

            if let previousResult {
                Divider()
                resultView(previousResult, showReanalyzeAction: false)
            }
        }
    }

}

private extension TakeAnalysisUnavailableKind {
    var displayTitle: String {
        switch self {
        case .noAudio: "Audio Required for Timing"
        case .unsupportedDevice: "On-Device Speech Unavailable"
        case .unsupportedLocale: "English Speech Locale Unsupported"
        case .permissionDenied: "Speech Access Unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .noAudio: "waveform.slash"
        case .unsupportedDevice: "cpu"
        case .unsupportedLocale: "globe"
        case .permissionDenied: "hand.raised.slash"
        }
    }
}

private struct TakeReviewActionPair: View {
    struct ActionItem {
        let title: String
        let symbol: String
        let id: String
        let action: () -> Void
    }

    let isAccessibilitySize: Bool
    let primary: ActionItem
    let secondary: ActionItem

    var body: some View {
        if isAccessibilitySize {
            VStack(spacing: 8) {
                primaryButton
                secondaryButton
            }
        } else {
            HStack(spacing: 10) {
                primaryButton
                secondaryButton
            }
        }
    }

    private var primaryButton: some View {
        Button(action: primary.action) {
            Label(primary.title, systemImage: primary.symbol)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(primary.id)
    }

    private var secondaryButton: some View {
        Button(action: secondary.action) {
            Label(secondary.title, systemImage: secondary.symbol)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(secondary.id)
    }
}
