import SwiftUI

struct TakeReviewScriptCard: View {
    let section: SectionRevisionRecord
    let revisionNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Snapshotted Script (Revision \(revisionNumber))", systemImage: "doc.text")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

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
        let handoff = talkRevision.flatMap {
            presentationStore.handoffContext(forSectionID: attempt.sectionID, in: $0)
        }
        let isOlderRevision = presentation?.currentRevisionID != nil
            && presentation?.currentRevisionID != attempt.talkRevisionID
        let totalDuration = max(playerDuration, attempt.playableDuration)
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
        let analysisContext = TakeAnalysisRequestContext(
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
        let currentTiming = analysisPhase.displayedResult ?? attempt.timingAnalysis
        return TakeReviewDisplaySnapshot(
            presentationTitle: presentation?.title,
            sectionRevision: sectionRevision,
            handoff: handoff,
            isOlderRevision: isOlderRevision,
            totalDuration: totalDuration,
            analysisContext: analysisContext,
            currentTimingAnalysis: currentTiming,
            currentObservations: currentTiming?.observations ?? []
        )
    }
}
