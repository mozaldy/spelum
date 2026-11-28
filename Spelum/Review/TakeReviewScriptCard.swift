import SwiftUI

struct TakeReviewScriptCard: View {
    let section: SectionRevisionRecord
    let revisionNumber: Int
    let storageRootURL: URL

    init(
        section: SectionRevisionRecord,
        revisionNumber: Int,
        storageRootURL: URL = SlideDeckStorage.defaultStorageRootURL()
    ) {
        self.section = section
        self.revisionNumber = revisionNumber
        self.storageRootURL = storageRootURL
    }

    var body: some View {
        let slides = RehearsalSlideResolver.resolveSlides(for: section)
        VStack(alignment: .leading, spacing: 10) {
            Label("Snapshotted Script (Revision \(revisionNumber))", systemImage: "doc.text")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if slides.contains(where: \.hasSlideArtwork) || slides.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(slides) { slide in
                            VStack(alignment: .leading, spacing: 4) {
                                if let pdfURL = slide.resolvedDeckURL(storageRootURL: storageRootURL),
                                   let pageIndex = slide.pdfPageIndex {
                                    SlideThumbnailView(
                                        pdfURL: pdfURL,
                                        pageIndex: pageIndex,
                                        aspectRatio: slide.aspectRatio,
                                        targetWidth: 112
                                    )
                                }
                                Text(slide.slideTitle)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: 112, alignment: .leading)
                            }
                            .accessibilityIdentifier("reviewSnapshottedSlide_\(slide.slideIndex)")
                        }
                    }
                }
            }

            if let exactPhrase = section.exactPhrase,
               !exactPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Exact Phrase", systemImage: "quote.opening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(exactPhrase)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }

            Text(section.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reviewSnapshottedScriptText")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TakeReviewDisplaySnapshot {
    let presentationTitle: String?
    let sectionRevision: SectionRevisionRecord?
    let fullRunPayload: FullRunAttemptPayload?
    let handoff: HandoffContext?
    let isOlderRevision: Bool
    let totalDuration: TimeInterval
    let analysisContext: TakeAnalysisRequestContext
    let currentTimingAnalysis: TimingAnalysisResult?
    let currentObservations: [TimingObservation]
}

enum TakeReviewContextBuilder {
    @MainActor
    static func buildSnapshot(
        for attempt: AttemptRecord,
        presentationStore: PresentationStore,
        attemptStore: AttemptStore,
        playerDuration: TimeInterval,
        analysisPhase: TakeAnalysisPhase
    ) -> TakeReviewDisplaySnapshot {
        let presentation = try? presentationStore.presentation(withID: attempt.presentationID)
        let talkRevision = try? presentationStore.talkRevision(withID: attempt.talkRevisionID)
        let sectionRevision = try? presentationStore.sectionRevision(withID: attempt.sectionRevisionID)
        let fullRunPayload = attempt.fullRunPayload
        let handoff = talkRevision.flatMap {
            presentationStore.handoffContext(forSectionID: attempt.sectionID, in: $0)
        }
        let isOlderRevision = presentation?.currentRevisionID != nil
            && presentation?.currentRevisionID != attempt.talkRevisionID
        let totalDuration = max(playerDuration, attempt.playableDuration)

        let analysisContext: TakeAnalysisRequestContext
        if let fullRunPayload {
            analysisContext = fullRunAnalysisContext(
                for: attempt,
                payload: fullRunPayload,
                attemptStore: attemptStore,
                playerDuration: playerDuration
            )
        } else {
            analysisContext = sectionAnalysisContext(
                for: attempt,
                presentationStore: presentationStore,
                attemptStore: attemptStore,
                playerDuration: playerDuration
            )
        }

        let currentTiming = analysisPhase.displayedResult ?? attempt.timingAnalysis
        return TakeReviewDisplaySnapshot(
            presentationTitle: presentation?.title ?? fullRunPayload?.snapshot.presentationTitle,
            sectionRevision: sectionRevision,
            fullRunPayload: fullRunPayload,
            handoff: handoff,
            isOlderRevision: isOlderRevision,
            totalDuration: totalDuration,
            analysisContext: analysisContext,
            currentTimingAnalysis: currentTiming,
            currentObservations: currentTiming?.observations ?? []
        )
    }

    @MainActor
    private static func fullRunAnalysisContext(
        for attempt: AttemptRecord,
        payload: FullRunAttemptPayload,
        attemptStore: AttemptStore,
        playerDuration: TimeInterval
    ) -> TakeAnalysisRequestContext {
        let reachedIDs = Set(payload.transitions.map(\.sectionRevisionID))
        let coveredSections = payload.snapshot.sections.filter {
            reachedIDs.isEmpty || reachedIDs.contains($0.sectionRevisionID)
        }
        let joinedText = coveredSections.map(\.text).joined(separator: "\n\n")
        let speakers = Array(
            Set(
                payload.snapshot.sections
                    .map { $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        return TakeAnalysisRequestContext(
            attemptID: attempt.id,
            talkRevisionID: attempt.talkRevisionID,
            sectionRevisionID: attempt.sectionRevisionID,
            relativeAudioPath: attempt.relativeAudioPath,
            audioURL: attemptStore.resolvedAudioURL(for: attempt),
            elapsedAudioDuration: attempt.playableDuration > 0 ? attempt.playableDuration : playerDuration,
            hasPlayableAudio: attempt.hasPlayableAudio,
            isSilentRecall: attempt.isSilentRecall,
            scriptText: joinedText,
            exactPhrase: nil,
            cueWords: coveredSections.flatMap(\.cueWords),
            knownSpeakerNames: speakers,
            hasMultipleSpeakersOrHandoff: payload.snapshot.hasMultipleSpeakers
        )
    }

    @MainActor
    private static func sectionAnalysisContext(
        for attempt: AttemptRecord,
        presentationStore: PresentationStore,
        attemptStore: AttemptStore,
        playerDuration: TimeInterval
    ) -> TakeAnalysisRequestContext {
        let talkRevision = try? presentationStore.talkRevision(withID: attempt.talkRevisionID)
        let sectionRevision = try? presentationStore.sectionRevision(withID: attempt.sectionRevisionID)
        let handoff = talkRevision.flatMap {
            presentationStore.handoffContext(forSectionID: attempt.sectionID, in: $0)
        }
        let isMultiSpeakerOrHandoff = (handoff?.isSpeakerChange == true)
            || (handoff?.isSingleSpeakerTalk == false)
        var rawSpeakers: [String] = []
        if let talkRevision {
            rawSpeakers.append(contentsOf: presentationStore.orderedSections(in: talkRevision).map(\.speaker))
        } else if let sectionRevision {
            rawSpeakers.append(sectionRevision.speaker)
        }
        let knownSpeakerNames = Array(
            Set(rawSpeakers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        )
        return TakeAnalysisRequestContext(
            attemptID: attempt.id,
            talkRevisionID: attempt.talkRevisionID,
            sectionRevisionID: attempt.sectionRevisionID,
            relativeAudioPath: attempt.relativeAudioPath,
            audioURL: attemptStore.resolvedAudioURL(for: attempt),
            elapsedAudioDuration: attempt.playableDuration > 0 ? attempt.playableDuration : playerDuration,
            hasPlayableAudio: attempt.hasPlayableAudio,
            isSilentRecall: attempt.isSilentRecall,
            scriptText: sectionRevision?.text ?? "",
            exactPhrase: sectionRevision?.exactPhrase,
            cueWords: sectionRevision?.cueWords ?? [],
            knownSpeakerNames: knownSpeakerNames,
            hasMultipleSpeakersOrHandoff: isMultiSpeakerOrHandoff
        )
    }
}

struct TakeReviewCompareButton: View {
    let isFullRun: Bool
    let onCompare: () -> Void

    var body: some View {
        let title = isFullRun ? "Compare with Another Run" : "Compare with Another Take"
        Button(action: onCompare) {
            Label(title, systemImage: "arrow.left.arrow.right")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
        .accessibilityHint("Opens side-by-side comparison defaulting to a matching revision and scope.")
        .accessibilityIdentifier("compareFromReviewButton")
    }
}

struct TakeReviewRetryButton: View {
    let isFullRun: Bool
    let practiceModeName: String
    let onRetry: () -> Void

    var body: some View {
        let title = isFullRun
            ? "Retry Full Run (\(practiceModeName))"
            : "Retry Section (\(practiceModeName))"
        let accessibilityLabel = isFullRun
            ? "Retry Full Run in \(practiceModeName) mode"
            : "Retry Section in \(practiceModeName) mode"
        let hint = isFullRun
            ? "Starts a fresh full run with the same talk revision, scope, and practice mode."
            : "Starts a fresh rehearsal attempt on the same section revision and practice mode."
        let identifier = isFullRun ? "retryFullRunFromReviewButton" : "retrySectionFromReviewButton"

        Button(action: onRetry) {
            Label(title, systemImage: "arrow.counterclockwise")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

extension TakeReview {
    static func performDeletion(
        attempt: AttemptRecord,
        attemptStore: AttemptStore,
        player: TakeAudioPlayer,
        analysisCoordinator: TakeAnalysisCoordinator? = nil,
        coachCoordinator: PostTakeCoachCoordinator? = nil
    ) throws {
        let recoveryToken = analysisCoordinator?.prepareForDeletion(attemptID: attempt.id)
        let coachRecoveryToken = coachCoordinator?.prepareForDeletion(attemptID: attempt.id)
        player.pause()
        do {
            try attemptStore.deleteAttempt(attempt)
            player.stop()
        } catch {
            if !player.isLoaded,
               attempt.hasPlayableAudio,
               let url = attemptStore.resolvedAudioURL(for: attempt) {
                player.load(url: url)
            }
            if let recoveryToken {
                let persisted = (try? attemptStore.attempt(withID: attempt.id))?.timingAnalysis
                analysisCoordinator?.restoreAfterFailedDeletion(
                    recoveryToken,
                    persistedAnalysis: persisted
                )
            }
            if let coachRecoveryToken {
                coachCoordinator?.restoreAfterFailedDeletion(coachRecoveryToken)
            }
            throw error
        }
    }

    static func makeFullRunRetryTarget(
        for attempt: AttemptRecord,
        payload: FullRunAttemptPayload
    ) -> FullRunTarget {
        FullRunTarget(
            presentationID: attempt.presentationID,
            talkRevisionID: attempt.talkRevisionID,
            startKind: payload.snapshot.startKind,
            startingSectionID: payload.snapshot.startingSection?.sectionID,
            initialMode: attempt.practiceMode,
            retryToken: UUID()
        )
    }

    static func makeSectionRetryTarget(for attempt: AttemptRecord) -> PracticeTarget {
        PracticeTarget(
            presentationID: attempt.presentationID,
            sectionID: attempt.sectionID,
            talkRevisionID: attempt.talkRevisionID,
            sectionRevisionID: attempt.sectionRevisionID,
            initialMode: attempt.practiceMode,
            hasUnsavedEditorDraft: false,
            retryToken: UUID()
        )
    }
}
