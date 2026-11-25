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
        let notes = request.timingAnalysis?.ambiguousNotes ?? []
        return notes.contains { note in
            switch note.reason {
            case .emptyTranscript, .overlappingRanges, .incompleteTimingCoverage,
                 .repeatedPhrase, .paraphrasedOrMissingWords:
                true
            case .stageDirectionSilence, .multiSpeakerBoundary:
                false
            }
        }
    }

    static func mandatoryAbstentionOption(for request: PostTakeCoachingRequest) -> CoachingAbstentionOption? {
        if request.attemptStatus == .silentCompleted || request.playableDuration <= 0 {
            return CoachingAbstentionOption(
                id: "abstain.post.silent-recall",
                summaryForModel: "Silent recall has no audio or timing observations.",
                renderedAction:
                    "No timing cue offered for silent recall. Record an audio take when ready to review delivery.",
                renderedRationale:
                    "Silent recall captures time and script reveals only, without audio timing evidence."
            )
        }
        let observations = request.timingAnalysis?.observations ?? []
        if request.attemptStatus == .interrupted && observations.isEmpty {
            return CoachingAbstentionOption(
                id: "abstain.post.interrupted-partial",
                summaryForModel: "Interrupted partial take with no validated timing observations.",
                renderedAction:
                    "Replay your partial audio or retry the section before picking a delivery adjustment.",
                renderedRationale:
                    "This take was interrupted before full timing evidence was available."
            )
        }
        if request.timingAnalysis?.outcome == .declined {
            return CoachingAbstentionOption(
                id: "abstain.post.analysis-declined",
                summaryForModel: "On-device speech timing analysis was declined for this take.",
                renderedAction:
                    "Withholding an automated timing cue — replay the take and add a manual marker to adjust.",
                renderedRationale:
                    "Speech timing analysis was skipped for this take, so playback and marking are more reliable."
            )
        }
        if observations.isEmpty && hasBlockingAmbiguity(in: request) {
            return CoachingAbstentionOption(
                id: "abstain.post.uncertain-alignment",
                summaryForModel: "Transcript was empty, paraphrased, repeated, or had overlapping/incomplete ranges.",
                renderedAction:
                    "Withholding an automated timing cue — replay the take and add a manual marker to adjust.",
                renderedRationale:
                    "Speech alignment was uncertain, silent, or incomplete, so playback and marking are more reliable."
            )
        }
        return nil
    }
}

private extension PostTakeCoachingOptionSet {
    static func buildOptionalAbstentionOptions(
        for request: PostTakeCoachingRequest,
        hasEvidence: Bool
    ) -> [CoachingAbstentionOption] {
        if !hasEvidence {
            return [
                CoachingAbstentionOption(
                    id: "abstain.post.no-timing-evidence",
                    summaryForModel: "No validated timing observations, reveals, or markers to anchor a suggestion.",
                    renderedAction:
                        "Withholding an automated timing cue — replay the take and add a manual marker to adjust.",
                    renderedRationale:
                        "No validated timing observations or recorded rehearsal flags were present on this take."
                )
            ]
        }
        return [
            CoachingAbstentionOption(
                id: "abstain.post.clean-take",
                summaryForModel: "Take finished cleanly with aligned phrasing and no change needed right now.",
                renderedAction:
                    "No change needed right now — replay the aligned passage once to confirm it sounds right.",
                renderedRationale:
                    "This take finished cleanly with \(request.revealCount) reveals and aligned phrasing, " +
                    "so withholding a correction fits."
            )
        ]
    }

    static func buildEvidenceOptions(
        for request: PostTakeCoachingRequest,
        observations: [TimingObservation],
        passages: [CoachingPassageOption]
    ) -> [CoachingEvidenceOption] {
        let scriptPassageIDs = Set(passages.filter { !$0.fromHandoff }.map(\.id))
        let allTechIDs = Set(request.candidateTechniques.map(\.id))
        guard !scriptPassageIDs.isEmpty, !allTechIDs.isEmpty else { return [] }

        var options: [CoachingEvidenceOption] = []
        let primaryAligned = observations.first {
            $0.kind == .alignedExactPhrase || $0.kind == .alignedCuePhrase || $0.kind == .alignedScriptPhrase
        }

        for obs in observations {
            if let option = makeObservationEvidence(obs: obs, passages: passages, allTechIDs: allTechIDs) {
                options.append(option)
            }
        }

        appendPaceEvidence(
            for: request,
            observations: observations,
            primaryAligned: primaryAligned,
            passages: passages,
            scriptPassageIDs: scriptPassageIDs,
            allTechIDs: allTechIDs,
            to: &options
        )
        appendFactEvidence(
            for: request,
            primaryAligned: primaryAligned,
            scriptPassageIDs: scriptPassageIDs,
            allTechIDs: allTechIDs,
            to: &options
        )
        return options
    }

    static func makeObservationEvidence(
        obs: TimingObservation,
        passages: [CoachingPassageOption],
        allTechIDs: Set<String>
    ) -> CoachingEvidenceOption? {
        let matchedPassages = semanticallyMatchingPassageIDs(for: obs, in: passages)
        guard !matchedPassages.isEmpty else { return nil }

        let obsKey = "obs.\(obs.id.uuidString.lowercased())"
        switch obs.kind {
        case .phraseGap:
            guard let gap = obs.gapDuration else { return nil }
            let formatted = String(format: "%.1f", gap)
            return CoachingEvidenceOption(
                id: obsKey,
                kind: .phraseGap(
                    observationID: obs.id,
                    gapSeconds: gap,
                    startTime: obs.startTime,
                    endTime: obs.endTime
                ),
                observationID: obs.id,
                summaryForModel:
                    "Estimated \(formatted)s phrase gap (\(String(format: "%.1f", obs.startTime))s-" +
                    "\(String(format: "%.1f", obs.endTime))s)",
                compatiblePassageIDs: matchedPassages,
                compatibleTechniqueIDs: allTechIDs
            )
        case .alignedExactPhrase, .alignedCuePhrase, .alignedScriptPhrase:
            let clock = RehearsalTimeFormatter.clockString(for: obs.startTime)
            return CoachingEvidenceOption(
                id: obsKey,
                kind: .alignedPhrase(
                    observationID: obs.id,
                    kind: obs.kind,
                    startTime: obs.startTime,
                    endTime: obs.endTime
                ),
                observationID: obs.id,
                summaryForModel: "Aligned passage at \(clock) (\(obs.kind.rawValue))",
                compatiblePassageIDs: matchedPassages,
                compatibleTechniqueIDs: allTechIDs
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func appendPaceEvidence(
        for request: PostTakeCoachingRequest,
        observations: [TimingObservation],
        primaryAligned: TimingObservation?,
        passages: [CoachingPassageOption],
        scriptPassageIDs: Set<String>,
        allTechIDs: Set<String>,
        to options: inout [CoachingEvidenceOption]
    ) {
        guard request.timingAnalysis?.outcome == .completed,
              !hasBlockingAmbiguity(in: request),
              !observations.isEmpty,
              let wpm = request.timingAnalysis?.estimatedWordsPerMinute else {
            return
        }
        let rounded = Int(wpm.rounded())
        let alignedIDs = primaryAligned.map { semanticallyMatchingPassageIDs(for: $0, in: passages) } ?? []
        let compatiblePassages = alignedIDs.isEmpty ? scriptPassageIDs : alignedIDs

        if wpm >= 165 {
            options.append(
                CoachingEvidenceOption(
                    id: "fact.pace.fast",
                    kind: .fastPace(estimatedWPM: rounded, anchorObservationID: primaryAligned?.id),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Estimated fast speaking pace near \(rounded) WPM",
                    compatiblePassageIDs: compatiblePassages,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        } else if wpm <= 85 {
            options.append(
                CoachingEvidenceOption(
                    id: "fact.pace.slow",
                    kind: .slowPace(estimatedWPM: rounded, anchorObservationID: primaryAligned?.id),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Estimated slow speaking pace near \(rounded) WPM",
                    compatiblePassageIDs: compatiblePassages,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        }
    }

    static func appendFactEvidence(
        for request: PostTakeCoachingRequest,
        primaryAligned: TimingObservation?,
        scriptPassageIDs: Set<String>,
        allTechIDs: Set<String>,
        to options: inout [CoachingEvidenceOption]
    ) {
        if request.revealCount > 0 {
            options.append(
                CoachingEvidenceOption(
                    id: "fact.reveals",
                    kind: .scriptReveals(count: request.revealCount, anchorObservationID: primaryAligned?.id),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Recorded \(request.revealCount) script reveal(s) during take",
                    compatiblePassageIDs: scriptPassageIDs,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        }
        for (idx, marker) in request.markers.prefix(3).enumerated() {
            let clock = RehearsalTimeFormatter.clockString(for: marker.timestamp)
            options.append(
                CoachingEvidenceOption(
                    id: "fact.marker.\(idx)",
                    kind: .manualMarker(
                        timestamp: marker.timestamp,
                        label: marker.label,
                        anchorObservationID: primaryAligned?.id
                    ),
                    observationID: primaryAligned?.id,
                    summaryForModel: "Manual marker at \(clock) (\(marker.label))",
                    compatiblePassageIDs: scriptPassageIDs,
                    compatibleTechniqueIDs: allTechIDs
                )
            )
        }
    }

    static func semanticallyMatchingPassageIDs(
        for observation: TimingObservation,
        in passages: [CoachingPassageOption]
    ) -> Set<String> {
        let scriptPassages = passages.filter { !$0.fromHandoff }
        let contextSnippets: [String]
        switch observation.kind {
        case .phraseGap:
            contextSnippets = [observation.followingContext, observation.precedingContext]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .alignedExactPhrase, .alignedCuePhrase, .alignedScriptPhrase:
            contextSnippets = [observation.matchedPhrase]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard !contextSnippets.isEmpty else { return [] }

        var matched: Set<String> = []
        for passage in scriptPassages {
            let passageWords = CoachingPassageExtractor.normalizedWords(in: passage.phrase)
            guard !passageWords.isEmpty else { continue }
            for snippet in contextSnippets {
                let snippetWords = CoachingPassageExtractor.normalizedWords(in: snippet)
                guard !snippetWords.isEmpty else { continue }
                if containsContiguousSubsequence(snippetWords, in: passageWords)
                    || containsContiguousSubsequence(passageWords, in: snippetWords) {
                    matched.insert(passage.id)
                    break
                }
            }
        }
        return matched
    }

    static func containsContiguousSubsequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let limit = haystack.count - needle.count
        for start in 0...limit where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
