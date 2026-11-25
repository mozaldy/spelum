import Foundation

extension TechniqueLibrary {
    static func authoredPostTakeSuggestion(
        for request: PostTakeCoachingRequest,
        origin: CoachingCueOrigin = .authoredBaseline,
        fallbackReason: CoachingFallbackReason? = nil,
        now: Date = Date()
    ) -> CoachingSuggestion {
        if let abstention = authoredPostTakeAbstentionIfAppropriate(
            for: request,
            origin: origin,
            fallbackReason: fallbackReason,
            now: now
        ) {
            return abstention
        }

        let technique = selectAuthoredPostTakeTechnique(for: request)
        let groundedObservation = selectPrimaryObservation(for: request)
        let anchor = selectPostTakeVerbatimPhrase(request: request, observation: groundedObservation)
        let action = buildAuthoredPostTakeAction(
            technique: technique,
            request: request,
            observation: groundedObservation
        )
        let rationale = buildAuthoredPostTakeRationale(
            request: request,
            observation: groundedObservation
        )

        return CoachingSuggestion(
            task: .postTake,
            origin: origin,
            fallbackReason: fallbackReason,
            isAbstention: false,
            techniqueID: technique.id,
            techniqueTitle: technique.title,
            sourceWork: technique.sourceWork,
            sourceTimestamp: technique.sourceTimestamp,
            sourcePassageSummary: technique.sourcePassageSummary,
            exactPhrase: anchor.phrase,
            exactPhraseFromHandoff: anchor.fromHandoff,
            observationID: groundedObservation?.id,
            action: action,
            rationale: rationale,
            promptVersion: request.promptVersion,
            sectionRevisionID: request.sectionRevisionID,
            attemptID: request.attemptID,
            evidenceVersion: request.evidenceVersion,
            createdAt: now,
            updatedAt: now
        )
    }
}

private extension TechniqueLibrary {
    static func selectAuthoredPostTakeTechnique(for request: PostTakeCoachingRequest) -> CoachingTechnique {
        let prepLike = PreparationCoachingRequest(
            sectionRevisionID: request.sectionRevisionID,
            talkRevisionID: request.talkRevisionID,
            sectionTitle: request.sectionTitle,
            scriptText: request.scriptText,
            exactPhrase: request.exactPhrase,
            cueWords: request.cueWords,
            purpose: request.purpose,
            handoffCueText: request.handoffCueText,
            isSpeakerChangeHandoff: request.isSpeakerChangeHandoff,
            knownSpeakerNames: request.knownSpeakerNames,
            selectedTechniqueID: nil,
            candidateTechniques: request.candidateTechniques,
            promptVersion: request.promptVersion
        )
        return selectAuthoredPreparationTechnique(for: prepLike)
    }

    static func authoredPostTakeAbstentionIfAppropriate(
        for request: PostTakeCoachingRequest,
        origin: CoachingCueOrigin,
        fallbackReason: CoachingFallbackReason?,
        now: Date
    ) -> CoachingSuggestion? {
        let pair: (action: String, rationale: String)?
        if request.attemptStatus == .silentCompleted || request.playableDuration <= 0 {
            pair = (
                "No timing cue offered for silent recall. Record an audio take when ready to review delivery.",
                "Silent recall captures time and script reveals only, without audio timing evidence."
            )
        } else if request.attemptStatus == .interrupted && (request.timingAnalysis?.observations.isEmpty ?? true) {
            pair = (
                "Replay your partial audio or retry the section before picking a delivery adjustment.",
                "This take was interrupted before full timing evidence was available."
            )
        } else if shouldAbstainForUncertainty(request: request) {
            pair = (
                "Withholding an automated timing cue — replay the take and add a manual marker to adjust.",
                "Speech alignment was uncertain, silent, or skipped, so playback and marking are more reliable."
            )
        } else if shouldAbstainForCleanTake(request: request) {
            pair = (
                "No change needed right now — replay the aligned passage once to confirm it sounds right.",
                "This take finished cleanly with 0 reveals and aligned phrasing, so withholding a correction fits."
            )
        } else {
            pair = nil
        }
        guard let pair else { return nil }
        return makeAbstention(
            request: request,
            origin: origin,
            fallbackReason: fallbackReason,
            action: pair.action,
            rationale: pair.rationale,
            now: now
        )
    }

    static func shouldAbstainForUncertainty(request: PostTakeCoachingRequest) -> Bool {
        let observations = request.timingAnalysis?.observations ?? []
        let ambiguousNotes = request.timingAnalysis?.ambiguousNotes ?? []
        let hasBlockingAmbiguity = ambiguousNotes.contains { note in
            switch note.reason {
            case .emptyTranscript, .overlappingRanges, .incompleteTimingCoverage,
                 .repeatedPhrase, .paraphrasedOrMissingWords:
                true
            case .stageDirectionSilence, .multiSpeakerBoundary:
                false
            }
        }
        return observations.isEmpty && (hasBlockingAmbiguity || request.timingAnalysis?.outcome == .declined)
    }

    static func shouldAbstainForCleanTake(request: PostTakeCoachingRequest) -> Bool {
        let observations = request.timingAnalysis?.observations ?? []
        let hasGap = observations.contains { $0.kind == .phraseGap }
        let estimatedWPM = request.timingAnalysis?.estimatedWordsPerMinute
        let isFastPace = (estimatedWPM ?? 0) >= 165
        let isSlowPace = (estimatedWPM ?? 120) <= 85 && estimatedWPM != nil
        let hasAlignedPhrase = observations.contains {
            $0.kind == .alignedExactPhrase || $0.kind == .alignedCuePhrase
        }
        return request.attemptStatus == .ready
            && request.revealCount == 0
            && request.markers.isEmpty
            && !hasGap
            && !isFastPace
            && !isSlowPace
            && hasAlignedPhrase
    }

    // swiftlint:disable:next function_parameter_count
    static func makeAbstention(
        request: PostTakeCoachingRequest,
        origin: CoachingCueOrigin,
        fallbackReason: CoachingFallbackReason?,
        action: String,
        rationale: String,
        now: Date
    ) -> CoachingSuggestion {
        CoachingSuggestion(
            task: .postTake,
            origin: origin,
            fallbackReason: fallbackReason,
            isAbstention: true,
            techniqueID: nil,
            techniqueTitle: nil,
            sourceWork: nil,
            sourceTimestamp: nil,
            sourcePassageSummary: nil,
            exactPhrase: nil,
            exactPhraseFromHandoff: false,
            observationID: nil,
            action: action,
            rationale: rationale,
            promptVersion: request.promptVersion,
            sectionRevisionID: request.sectionRevisionID,
            attemptID: request.attemptID,
            evidenceVersion: request.evidenceVersion,
            createdAt: now,
            updatedAt: now
        )
    }

    static func selectPrimaryObservation(for request: PostTakeCoachingRequest) -> TimingObservation? {
        let observations = request.timingAnalysis?.observations ?? []
        if let gap = observations.first(where: { $0.kind == .phraseGap }) {
            return gap
        }
        if let exact = observations.first(where: { $0.kind == .alignedExactPhrase }) {
            return exact
        }
        return observations.first
    }

    static func selectPostTakeVerbatimPhrase(
        request: PostTakeCoachingRequest,
        observation: TimingObservation?
    ) -> PhraseAnchor {
        if let matched = observation?.matchedPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
           !matched.isEmpty,
           request.scriptText.contains(matched) {
            return PhraseAnchor(phrase: matched, fromHandoff: false)
        }
        return selectVerbatimPhrase(
            scriptText: request.scriptText,
            exactPhrase: request.exactPhrase,
            handoffCueText: request.handoffCueText,
            preferHandoff: false
        )
    }

    static func buildAuthoredPostTakeAction(
        technique: CoachingTechnique,
        request: PostTakeCoachingRequest,
        observation: TimingObservation?
    ) -> String {
        if let observation, observation.kind == .phraseGap, let gap = observation.gapDuration {
            let formatted = String(format: "%.1f", gap)
            return "Replay around the estimated \(formatted)s gap and test whether holding " +
                "or tightening that beat makes the next line land cleaner."
        }
        if let wpm = request.timingAnalysis?.estimatedWordsPerMinute, wpm >= 165 {
            let rounded = Int(wpm.rounded())
            return "Pace was estimated near \(rounded) WPM; replay the highlighted line " +
                "and try adding one clear breath right before it."
        }
        if request.revealCount > 0 {
            let revealWord = request.revealCount == 1
                ? "1 script reveal"
                : "\(request.revealCount) script reveals"
            return "You used \(revealWord) on this take; replay the highlighted line once, " +
                "then retry focusing on that single anchor."
        }
        if !request.markers.isEmpty {
            return "Jump to your manual marker in playback and try one clean retry focused on the line after it."
        }
        return technique.postTakeFocus
    }

    static func buildAuthoredPostTakeRationale(
        request: PostTakeCoachingRequest,
        observation: TimingObservation?
    ) -> String {
        if observation?.kind == .phraseGap {
            if request.isSpeakerChangeHandoff {
                return "Grounded in the bounded estimated gap without attributing the pause to a speaker."
            }
            return "Grounded directly in the bounded estimated phrase gap from on-device speech timing."
        }
        if observation != nil {
            return "Anchored to the aligned passage timestamp so you can hear the exact moment on replay."
        }
        return "Based on recorded take facts (reveals and markers) so you can decide by listening back."
    }
}
