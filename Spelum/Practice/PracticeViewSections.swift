import SwiftUI

struct PracticeHeaderCard: View {
    let presentationTitle: String
    let section: SectionRevisionRecord
    let talkRevisionNumber: Int
    let isOlderRevision: Bool
    let hasUnsavedEditorDraft: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentationTitle)
                    Text("Revision \(talkRevisionNumber)")
                    Label(section.speaker, systemImage: section.speakerRole.symbolName)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text("\(presentationTitle) · Revision \(talkRevisionNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(section.speaker, systemImage: section.speakerRole.symbolName)
                    Label(section.purpose.displayName, systemImage: section.purpose.symbolName)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if isOlderRevision {
                Label("Practicing snapshotted Revision \(talkRevisionNumber)", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            if hasUnsavedEditorDraft {
                Label(
                    "Rehearsing saved Revision \(talkRevisionNumber). Unsaved edits in the script editor remain intact.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("unsavedDraftPreservedNotice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct PracticeModeCard: View {
    let selectedMode: PracticeMode
    let isEnabled: Bool
    let isAccessibilitySize: Bool
    let onSelectMode: (PracticeMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Practice Mode")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(PracticeMode.allCases) { mode in
                        Button {
                            onSelectMode(mode)
                        } label: {
                            HStack {
                                Label(mode.displayName, systemImage: mode.symbolName)
                                Spacer()
                                if selectedMode == mode {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(
                                selectedMode == mode
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(.tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEnabled)
                        .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                        .accessibilityIdentifier("practiceMode_\(mode.rawValue)")
                    }
                }
            } else {
                Picker(
                    "Practice Mode",
                    selection: Binding(
                        get: { selectedMode },
                        set: { onSelectMode($0) }
                    )
                ) {
                    ForEach(PracticeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!isEnabled)
                .accessibilityLabel("Practice Mode")
                .accessibilityIdentifier("practiceModePicker")
            }

            Text(selectedMode.guidanceText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PracticeHandoffCueCard: View {
    let handoff: HandoffContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HandoffAttributionView(context: handoff)

            if let cueText = handoff.effectiveCueText, !cueText.isEmpty {
                Text("“\(cueText)”")
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("practiceHandoffCueText")
            } else {
                Text("Opening section — begin directly with your first line.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PracticePromptCard: View {
    let section: SectionRevisionRecord
    let slides: [ResolvedRehearsalSlide]
    let activeSlideIndex: Int
    let sectionPositionLabel: String?
    let practiceMode: PracticeMode
    let isScriptRevealed: Bool
    let revealCount: Int
    let isActiveTake: Bool
    let isAccessibilitySize: Bool
    let storageRootURL: URL
    let onSelectSlideIndex: ((Int) -> Void)?
    let onToggleReveal: () -> Void

    init(
        section: SectionRevisionRecord,
        slides: [ResolvedRehearsalSlide]? = nil,
        activeSlideIndex: Int = 0,
        sectionPositionLabel: String? = nil,
        practiceMode: PracticeMode,
        isScriptRevealed: Bool,
        revealCount: Int,
        isActiveTake: Bool,
        isAccessibilitySize: Bool = false,
        storageRootURL: URL = SlideDeckStorage.defaultStorageRootURL(),
        onSelectSlideIndex: ((Int) -> Void)? = nil,
        onToggleReveal: @escaping () -> Void
    ) {
        self.section = section
        self.slides = slides ?? RehearsalSlideResolver.resolveSlides(for: section)
        self.activeSlideIndex = activeSlideIndex
        self.sectionPositionLabel = sectionPositionLabel
        self.practiceMode = practiceMode
        self.isScriptRevealed = isScriptRevealed
        self.revealCount = revealCount
        self.isActiveTake = isActiveTake
        self.isAccessibilitySize = isAccessibilitySize
        self.storageRootURL = storageRootURL
        self.onSelectSlideIndex = onSelectSlideIndex
        self.onToggleReveal = onToggleReveal
    }

    private var clampedSlideIndex: Int {
        guard !slides.isEmpty else { return 0 }
        return min(max(activeSlideIndex, 0), slides.count - 1)
    }

    var rehearsalView: AnnotatedSlideRehearsalView {
        AnnotatedSlideRehearsalView(
            slides: slides,
            activeSlideIndex: clampedSlideIndex,
            sectionPositionLabel: sectionPositionLabel,
            sectionTitle: section.title,
            exactPhrase: section.exactPhrase,
            cueWords: section.cueWords,
            practiceMode: practiceMode,
            isScriptRevealed: isScriptRevealed,
            revealCount: revealCount,
            isActiveTake: isActiveTake,
            isAccessibilitySize: isAccessibilitySize,
            theme: .standard,
            storageRootURL: storageRootURL,
            fillsAvailableHeight: false,
            scriptScrollMaxHeight: 340,
            scriptAccessibilityIdentifier: "practiceRevealedScriptText",
            revealButtonAccessibilityIdentifier: "revealScriptButton",
            canGoPrevious: clampedSlideIndex > 0,
            previousButtonLabel: "Previous Slide",
            onPrevious: slides.count > 1 && onSelectSlideIndex != nil
                ? { onSelectSlideIndex?(clampedSlideIndex - 1) }
                : nil,
            canGoNext: clampedSlideIndex + 1 < slides.count,
            nextButtonLabel: "Next Slide",
            onNext: slides.count > 1 && onSelectSlideIndex != nil
                ? { onSelectSlideIndex?(clampedSlideIndex + 1) }
                : nil,
            onSelectSlideIndex: onSelectSlideIndex,
            onToggleReveal: onToggleReveal
        )
    }

    var visiblePromptState: RehearsalVisiblePromptState {
        rehearsalView.visiblePromptState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            rehearsalView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(practiceMode.displayName, systemImage: practiceMode.symbolName)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if practiceMode.supportsReveal && (isActiveTake || revealCount > 0) {
                Text(revealCount == 1 ? "1 reveal" : "\(revealCount) reveals")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("practiceRevealCountLabel")
            }
        }
    }
}

struct PracticeHistoryRow: View {
    let attempt: AttemptRecord
    let isCurrentSectionRevision: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerLayout

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(durationLabel)
                    Text(attempt.practiceMode.displayName)
                    Text(revealSummary)
                    if !attempt.markers.isEmpty {
                        Text(markerSummary)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(compactSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !isCurrentSectionRevision {
                Label("Revision \(attempt.talkRevisionNumber) (older)", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens saved take review and playback.")
    }

    @ViewBuilder
    private var headerLayout: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                statusBadge
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
                statusBadge
            }
        }
    }

    private var statusBadge: some View {
        Label(attempt.status.displayName, systemImage: attempt.status.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch attempt.status {
        case .ready: .green
        case .interrupted: .orange
        case .silentCompleted: .blue
        case .inProgress: .secondary
        }
    }

    private var durationLabel: String {
        if attempt.hasPlayableAudio {
            return RehearsalTimeFormatter.clockString(for: attempt.playableDuration)
        }
        if attempt.isSilentRecall {
            return "\(RehearsalTimeFormatter.clockString(for: attempt.elapsedDuration)) silent"
        }
        return "No audio"
    }

    private var revealSummary: String {
        attempt.revealCount == 1 ? "1 reveal" : "\(attempt.revealCount) reveals"
    }

    private var markerSummary: String {
        attempt.markers.count == 1 ? "1 marker" : "\(attempt.markers.count) markers"
    }

    private var compactSummary: String {
        var parts = [durationLabel, attempt.practiceMode.displayName, revealSummary]
        if !attempt.markers.isEmpty {
            parts.append(markerSummary)
        }
        return parts.joined(separator: " · ")
    }
}
