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
            isMultiSpeakerTalk: request.isMultiSpeakerTalk,
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
        if let mandatory = PostTakeCoachingOptionSet.mandatoryAbstentionOption(for: request) {
            return makeAbstention(
                request: request,
                origin: origin,
                fallbackReason: fallbackReason,
                action: mandatory.renderedAction,
                rationale: mandatory.renderedRationale,
                now: now
            )
        }
        if shouldAbstainForCleanTake(request: request) {
            return makeAbstention(
                request: request,
                origin: origin,
                fallbackReason: fallbackReason,
                action: "No change needed right now — replay the aligned passage once to confirm it sounds right.",
                rationale: "This take finished cleanly with 0 reveals and aligned phrasing, " +
                    "so withholding a correction fits.",
                now: now
            )
        }
        return nil
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
           CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(matched, in: request.scriptText) {
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
            if request.isSpeakerChangeHandoff || request.isMultiSpeakerTalk {
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
