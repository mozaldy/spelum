import Foundation

nonisolated enum CoachingEvidenceKind: Equatable, Hashable, Sendable {
    case phraseGap(observationID: UUID, gapSeconds: TimeInterval, startTime: TimeInterval, endTime: TimeInterval)
    case alignedPhrase(observationID: UUID, kind: TimingObservationKind, startTime: TimeInterval, endTime: TimeInterval)
    case fastPace(estimatedWPM: Int, anchorObservationID: UUID?)
    case slowPace(estimatedWPM: Int, anchorObservationID: UUID?)
    case scriptReveals(count: Int, anchorObservationID: UUID?)
    case manualMarker(timestamp: TimeInterval, label: String, anchorObservationID: UUID?)
}

nonisolated struct CoachingEvidenceOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let kind: CoachingEvidenceKind
    let observationID: UUID?
    let summaryForModel: String
    let compatiblePassageIDs: Set<String>
    let compatibleTechniqueIDs: Set<String>
}

nonisolated enum PostTakeActionTemplate: String, Codable, Equatable, Hashable, Sendable {
    case gapHoldBeat = "post.gap.hold-beat"
    case gapTightenTransition = "post.gap.tighten-transition"
    case gapSyncDemoWait = "post.gap.sync-demo-wait"
    case paceBreathBeforePayoff = "post.pace.breath-before-payoff"
    case paceSeparateSetupBeats = "post.pace.separate-setup-beats"
    case paceSlowFinalLanding = "post.pace.slow-final-landing"
    case paceSteadyMomentum = "post.pace.steady-momentum"
    case revealsAnchorRecall = "post.reveals.anchor-recall"
    case revealsBridgeTransition = "post.reveals.bridge-transition"
    case markerRehearseAfterMark = "post.marker.rehearse-after-mark"
    case markerCompareLeadIn = "post.marker.compare-lead-in"
    case alignedVerifyPayoff = "post.aligned.verify-payoff"
    case alignedTechniqueFocus = "post.aligned.technique-focus"
}

nonisolated struct CoachingPostTakeActionOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let template: PostTakeActionTemplate
    let compatibleEvidenceIDs: Set<String>
    let compatibleTechniqueIDs: Set<String>
    let summaryForModel: String
}

nonisolated struct PostTakeCoachingOptionSet: Equatable, Sendable {
    let candidateTechniques: [CoachingTechnique]
    let passageOptions: [CoachingPassageOption]
    let evidenceOptions: [CoachingEvidenceOption]
    let actionOptions: [CoachingPostTakeActionOption]
    let abstentionOptions: [CoachingAbstentionOption]
    let mustAbstain: Bool

    static func build(for request: PostTakeCoachingRequest) -> PostTakeCoachingOptionSet {
        if let mandatory = mandatoryAbstentionOption(for: request) {
            return PostTakeCoachingOptionSet(
                candidateTechniques: request.candidateTechniques,
                passageOptions: [],
                evidenceOptions: [],
                actionOptions: [],
                abstentionOptions: [mandatory],
                mustAbstain: true
            )
        }

        let validatedObservations = (request.timingAnalysis?.outcome == .completed)
            ? (request.timingAnalysis?.observations ?? [])
            : []
        let passages = CoachingPassageExtractor.extractPassages(
            scriptText: request.scriptText,
            exactPhrase: request.exactPhrase,
            handoffCueText: request.handoffCueText,
            observations: validatedObservations
        )
        let evidence = buildEvidenceOptions(
            for: request,
            observations: validatedObservations,
            passages: passages
        )
        let actions = buildActionOptions(
            for: request,
            evidenceOptions: evidence
        )
        let abstentions = buildOptionalAbstentionOptions(
            for: request,
            hasEvidence: !evidence.isEmpty && !passages.isEmpty && !actions.isEmpty
        )
        let mustAbstain = passages.isEmpty || evidence.isEmpty || actions.isEmpty

        return PostTakeCoachingOptionSet(
            candidateTechniques: request.candidateTechniques,
            passageOptions: mustAbstain ? [] : passages,
            evidenceOptions: mustAbstain ? [] : evidence,
            actionOptions: mustAbstain ? [] : actions,
            abstentionOptions: abstentions,
            mustAbstain: mustAbstain
        )
    }

    static func hasBlockingAmbiguity(in request: PostTakeCoachingRequest) -> Bool {
        !blockingAmbiguityReasons(in: request).isEmpty
    }

    static func blockingAmbiguityReasons(in request: PostTakeCoachingRequest) -> [AmbiguousEvidenceReason] {
        let notes = request.timingAnalysis?.ambiguousNotes ?? []
        var seen: Set<AmbiguousEvidenceReason> = []
        var ordered: [AmbiguousEvidenceReason] = []
        for note in notes where note.reason.isBlockingTimingAmbiguity && seen.insert(note.reason).inserted {
            ordered.append(note.reason)
        }
        return ordered
    }

    static func hasStageDirectionSilence(in request: PostTakeCoachingRequest) -> Bool {
        (request.timingAnalysis?.ambiguousNotes ?? []).contains { $0.reason == .stageDirectionSilence }
    }

    static func reliableEstimatedWPM(for request: PostTakeCoachingRequest) -> Double? {
        guard request.timingAnalysis?.outcome == .completed,
              !hasBlockingAmbiguity(in: request),
              let observations = request.timingAnalysis?.observations,
              !observations.isEmpty,
              let wpm = request.timingAnalysis?.estimatedWordsPerMinute,
              wpm.isFinite,
              wpm > 0 else {
            return nil
        }
        return wpm
    }

    static func isFastPace(for request: PostTakeCoachingRequest) -> Bool {
        guard let wpm = reliableEstimatedWPM(for: request) else { return false }
        return wpm >= 165
    }

    static func isSlowPace(for request: PostTakeCoachingRequest) -> Bool {
        guard !hasStageDirectionSilence(in: request),
              let wpm = reliableEstimatedWPM(for: request) else {
            return false
        }
        return wpm <= 85
    }

    static func isSupportedCleanTake(for request: PostTakeCoachingRequest) -> Bool {
        guard request.attemptStatus == .ready,
              request.playableDuration > 0,
              request.revealCount == 0,
              request.markers.isEmpty,
              request.timingAnalysis?.outcome == .completed,
              !hasBlockingAmbiguity(in: request),
              !isFastPace(for: request),
              !isSlowPace(for: request) else {
            return false
        }
        let observations = request.timingAnalysis?.observations ?? []
        let hasGap = observations.contains { $0.kind == .phraseGap }
        let hasAlignedPhrase = observations.contains {
            $0.kind == .alignedExactPhrase || $0.kind == .alignedCuePhrase
        }
        return !hasGap && hasAlignedPhrase
    }

    static func mandatoryAbstentionOption(for request: PostTakeCoachingRequest) -> CoachingAbstentionOption? {
        if request.attemptStatus == .silentCompleted || request.playableDuration <= 0 {
            let revealNote = request.revealCount == 0
                ? "Silent recall captures time and script reveals only, without audio timing evidence."
                : "Silent recall recorded \(revealPhrase(request.revealCount)) without audio, " +
                    "so no audio timing cue is offered."
            return CoachingAbstentionOption(
                id: "abstain.post.silent-recall",
                summaryForModel: "Silent recall has no audio or timing observations.",
                renderedAction:
                    "No audio timing cue offered for silent recall. " +
                    "Record an audio take when ready to review delivery.",
                renderedRationale: revealNote
            )
        }
        let observations = request.timingAnalysis?.observations ?? []
        if request.attemptStatus == .interrupted && observations.isEmpty {
            let duration = String(format: "%.1fs", request.playableDuration)
            return CoachingAbstentionOption(
                id: "abstain.post.interrupted-partial",
                summaryForModel: "Interrupted partial take (\(duration)) with no validated timing observations.",
                renderedAction:
                    "Replay your partial audio or retry the section before picking a delivery adjustment.",
                renderedRationale:
                    "This take was interrupted after \(duration) before full timing evidence was available."
            )
        }
        if request.timingAnalysis?.outcome == .declined {
            return CoachingAbstentionOption(
                id: "abstain.post.analysis-declined",
                summaryForModel: "On-device speech timing analysis was declined for this take.",
                renderedAction:
                    "Withholding an automated timing cue — replay the take and add a manual marker " +
                    "if you want to adjust.",
                renderedRationale:
                    "Speech timing analysis was skipped for this take, " +
                    "so listening back and marking directly is more reliable."
            )
        }
        if observations.isEmpty && hasBlockingAmbiguity(in: request)
            && request.revealCount == 0 && request.markers.isEmpty {
            let reasonSummary = formattedBlockingReasons(for: request)
            return CoachingAbstentionOption(
                id: "abstain.post.uncertain-alignment",
                summaryForModel: "Speech timing unavailable due to \(reasonSummary).",
                renderedAction:
                    "Withholding an automated timing cue — replay the take and add a manual marker " +
                    "to test an adjustment.",
                renderedRationale:
                    "Speech timing was withheld because of \(reasonSummary), " +
                    "so listening back and marking directly is more reliable."
            )
        }
        return nil
    }
}

private extension PostTakeCoachingOptionSet {
    static func revealPhrase(_ count: Int) -> String {
        count == 1 ? "1 script reveal" : "\(count) script reveals"
    }

    static func formattedBlockingReasons(for request: PostTakeCoachingRequest) -> String {
        let reasons = blockingAmbiguityReasons(in: request)
        guard !reasons.isEmpty else { return "uncertain speech timing" }
        return reasons.map { $0.neutralDisplayLabel.lowercased() }.joined(separator: " and ")
    }

    static func buildOptionalAbstentionOptions(
        for request: PostTakeCoachingRequest,
        hasEvidence: Bool
    ) -> [CoachingAbstentionOption] {
        if !hasEvidence {
            return [noTimingEvidenceAbstention()]
        }
        if isSupportedCleanTake(for: request) {
            return [cleanTakeAbstention()]
        }
        if request.attemptStatus == .interrupted {
            return [interruptedPartialAbstention(duration: request.playableDuration)]
        }
        if hasBlockingAmbiguity(in: request) {
            return [uncertainTimingAbstention(reasonSummary: formattedBlockingReasons(for: request))]
        }
        if hasStageDirectionSilence(in: request)
            && request.revealCount == 0
            && request.markers.isEmpty
            && !isFastPace(for: request) {
            return [demoSilenceAbstention()]
        }
        return []
    }

    static func noTimingEvidenceAbstention() -> CoachingAbstentionOption {
        CoachingAbstentionOption(
            id: "abstain.post.no-timing-evidence",
            summaryForModel: "No validated timing observations, reveals, or markers to anchor a suggestion.",
            renderedAction:
                "Withholding an automated timing cue — replay the take and add a manual marker to adjust.",
            renderedRationale:
                "No validated timing observations or recorded rehearsal markers were present on this take."
        )
    }

    static func cleanTakeAbstention() -> CoachingAbstentionOption {
        CoachingAbstentionOption(
            id: "abstain.post.clean-take",
            summaryForModel:
                "Take finished cleanly with 0 reveals, 0 markers, steady pace, and aligned phrasing.",
            renderedAction:
                "No change needed right now — replay the aligned passage once to confirm it sounds right.",
            renderedRationale:
                "This take finished cleanly with 0 reveals, no manual markers, and aligned phrasing, " +
                "so withholding a correction fits."
        )
    }

    static func interruptedPartialAbstention(duration: TimeInterval) -> CoachingAbstentionOption {
        let formatted = String(format: "%.1fs", duration)
        return CoachingAbstentionOption(
            id: "abstain.post.interrupted-partial",
            summaryForModel: "Take was interrupted after \(formatted); withholding an adjustment is reasonable.",
            renderedAction:
                "Replay your partial audio or retry the full section before picking a delivery adjustment.",
            renderedRationale:
                "This take was interrupted after \(formatted), so withholding a cue until a full pass fits."
        )
    }

    static func uncertainTimingAbstention(reasonSummary: String) -> CoachingAbstentionOption {
        CoachingAbstentionOption(
            id: "abstain.post.uncertain-timing",
            summaryForModel: "Timing had \(reasonSummary); withholding automated advice fits.",
            renderedAction:
                "Withholding an automated cue — replay the take and decide by ear " +
                "whether anything needs adjustment.",
            renderedRationale:
                "Speech timing noted \(reasonSummary), so reviewing playback directly fits this take."
        )
    }

    static func demoSilenceAbstention() -> CoachingAbstentionOption {
        CoachingAbstentionOption(
            id: "abstain.post.demo-silence-ok",
            summaryForModel:
                "Scripted stage-direction demo pause may already feel intentional; no change required.",
            renderedAction:
                "No change needed right now — replay the silent demo beat once " +
                "to confirm the wait feels intentional.",
            renderedRationale:
                "This section includes a scripted stage-direction pause, " +
                "so a silent beat during the demo is expected."
        )
    }
}
