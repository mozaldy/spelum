import SwiftUI

struct FullRunHeaderCard: View {
    let presentationTitle: String
    let snapshot: FullRunSnapshot
    let currentRunIndex: Int
    let isOlderRevision: Bool
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentationTitle)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.scopeTitle)
                    Text("Revision \(snapshot.talkRevisionNumber)")
                    Text(progressText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text("\(snapshot.scopeTitle) · Revision \(snapshot.talkRevisionNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(progressText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if isOlderRevision {
                Label(
                    "Rehearsing snapshotted Revision \(snapshot.talkRevisionNumber)",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("fullRunOlderRevisionBadge")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullRunHeaderCard")
    }

    private var progressText: String {
        let clampedCurrent = min(max(currentRunIndex + 1, 1), max(snapshot.sections.count, 1))
        return "Section \(clampedCurrent) of \(snapshot.sections.count) in this run"
    }
}

struct FullRunControlsCard: View {
    let session: RecordingSession
    let isAccessibilitySize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            timerHeader

            if session.isActiveTake {
                activeRunButtons
            } else {
                idleRunButtons
            }

            if !session.fullRunTransitions.isEmpty {
                transitionsSummary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("fullRunControlsCard")
    }

    private var timerHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    phaseLabel
                    elapsedLabel
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    phaseLabel
                    Spacer()
                    elapsedLabel
                }
            }
            if session.isActiveTake {
                let secTime = RehearsalTimeFormatter.clockString(for: session.currentSectionElapsedDuration)
                Text("Current section: \(secTime) · One continuous offline recording")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("One continuous offline recording across all snapshotted sections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var elapsedLabel: some View {
        Text(RehearsalTimeFormatter.clockString(for: session.elapsedDuration))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .accessibilityLabel("Total run elapsed time")
            .accessibilityValue(
                RehearsalTimeFormatter.accessibleDurationString(for: session.elapsedDuration)
            )
            .accessibilityIdentifier("fullRunTimerLabel")
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch session.phase {
        case .recording:
            Label("Recording Full Run", systemImage: "record.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
        case .silentRecall:
            Label("Silent Full Run", systemImage: "mic.slash.circle.fill")
                .font(.headline)
                .foregroundStyle(.blue)
        case .requestingPermission:
            Label("Checking Microphone…", systemImage: "mic")
                .font(.headline)
                .foregroundStyle(.secondary)
        case .finalizing:
            Label("Saving Full Run…", systemImage: "arrow.down.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
        default:
            Label("Ready for Full Run", systemImage: "waveform")
                .font(.headline)
        }
    }

    private var activeRunButtons: some View {
        let isSilent = session.phase == .silentRecall
        return VStack(spacing: 10) {
            if let nextSlide = session.nextSlideInCurrentSection,
               let activeSection = session.currentFullRunSection {
                Button {
                    _ = session.advanceFullRunStep()
                } label: {
                    VStack(spacing: 2) {
                        Label("Next Slide: \(nextSlide.slideTitle)", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                        Text("\(nextSlide.positionLabel) · \(activeSection.title)")
                            .font(.caption)
                            .opacity(0.9)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Advance to \(nextSlide.slideTitle), \(nextSlide.positionLabel)")
                .accessibilityHint("Moves to the next slide within the current section while recording continues.")
                .accessibilityIdentifier("advanceFullRunSectionButton")
            } else if let nextSection = session.nextFullRunSection {
                Button {
                    _ = session.advanceFullRunStep()
                } label: {
                    VStack(spacing: 2) {
                        Label("Next Section: \(nextSection.title)", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                        Text(nextSection.speakerSummary)
                            .font(.caption)
                            .opacity(0.9)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Advance to \(nextSection.title), speaker \(nextSection.speaker)")
                .accessibilityHint("Records the current audio timestamp and moves to the next section.")
                .accessibilityIdentifier("advanceFullRunSectionButton")
            }

            AdaptiveActionStack(isAccessibilitySize: isAccessibilitySize) {
                Button {
                    session.addManualMarker()
                } label: {
                    Label("Add Marker", systemImage: "flag.fill")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Add Marker")
                .accessibilityValue(
                    session.markers.count == 1 ? "1 marker" : "\(session.markers.count) markers"
                )
                .accessibilityIdentifier("fullRunAddMarkerButton")

                Button(role: .destructive) {
                    _ = session.isOnFinalFullRunSection
                        ? session.stopRecording()
                        : session.finishFullRunEarly()
                } label: {
                    Label(stopButtonTitle(isSilent: isSilent), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(isSilent ? .blue : .red)
                .accessibilityLabel(stopButtonTitle(isSilent: isSilent))
                .accessibilityHint(
                    session.isOnFinalFullRunSection
                        ? "Finishes and saves the full run."
                        : "Stops early and saves all sections completed so far."
                )
                .accessibilityIdentifier("fullRunStopButton")
            }
        }
    }

    private func stopButtonTitle(isSilent: Bool) -> String {
        if session.isOnFinalFullRunSection {
            return isSilent ? "Finish Silent Run" : "Finish & Save"
        }
        return "Finish Early & Save"
    }

    private var idleRunButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await session.startRecording() }
            } label: {
                Label("Start Full Run", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!session.canStartNewTake)
            .accessibilityLabel("Start Full Run")
            .accessibilityHint("Starts one continuous offline recording for this talk.")
            .accessibilityIdentifier("startFullRunButton")

            Button {
                session.startSilentRecall()
            } label: {
                Label("Silent Full Run (No Audio)", systemImage: "mic.slash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!session.canStartNewTake)
            .accessibilityLabel("Start Silent Full Run")
            .accessibilityHint("Rehearses section transitions with timer and reveals without recording audio.")
            .accessibilityIdentifier("startSilentFullRunButton")
        }
    }

    private var transitionsSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorded Section Timeline (\(session.fullRunTransitions.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(session.fullRunTransitions) { transition in
                let clock = RehearsalTimeFormatter.clockString(for: transition.startTime)
                Text("• \(transition.sectionTitle) (\(transition.speaker)) — \(clock)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("fullRunActiveTimelineSummary")
    }
}

struct FullRunRecentHistoryCard: View {
    let fullRuns: [AttemptRecord]
    let currentTalkRevisionID: UUID?
    let errorMessage: String?
    let isAccessibilitySize: Bool
    let onOpenReview: (UUID) -> Void
    let onOpenCompare: () -> Void
    let onRequestDelete: (AttemptRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved Full Runs (\(fullRuns.count))", systemImage: "clock")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if fullRuns.count >= 2 {
                    Button("Compare", action: onOpenCompare)
                        .font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("compareFullRunsFromPracticeButton")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if fullRuns.isEmpty {
                Text("Completed, early-finished, interrupted, and silent full runs appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(fullRuns, id: \.id) { run in
                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            onOpenReview(run.id)
                        } label: {
                            AttemptHistoryRowContent(
                                attempt: run,
                                isOlderRevision: currentTalkRevisionID != nil
                                    && run.talkRevisionID != currentTalkRevisionID,
                                isAccessibilitySize: isAccessibilitySize
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("fullRunHistoryRow_\(run.id.uuidString)")

                        Button(role: .destructive) {
                            onRequestDelete(run)
                        } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            "Delete full run from \(run.startedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .accessibilityIdentifier("deleteFullRunButton_\(run.id.uuidString)")
                    }
                    if run.id != fullRuns.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("fullRunHistoryCard")
    }
}
