import Foundation

extension TechniqueLibrary {
    static func authoredPreparationSuggestion(
        for request: PreparationCoachingRequest,
        origin: CoachingCueOrigin = .authoredBaseline,
        fallbackReason: CoachingFallbackReason? = nil,
        now: Date = Date()
    ) -> CoachingSuggestion {
        let optionSet = PreparationCoachingOptionSet.build(for: request)
        if optionSet.mustAbstain, let abstention = optionSet.abstentionOptions.first {
            return makePreparationAbstention(
                request: request,
                origin: origin,
                fallbackReason: fallbackReason,
                abstention: abstention,
                now: now
            )
        }
        if PreparationCoachingOptionSet.isMinimalClosingLine(request),
           let abstention = optionSet.abstentionOptions.first(where: { $0.id == "abstain.prep.minimal-signoff" }) {
            return makePreparationAbstention(
                request: request,
                origin: origin,
                fallbackReason: fallbackReason,
                abstention: abstention,
                now: now
            )
        }

        let technique = selectAuthoredPreparationTechnique(for: request)
        let anchor = selectVerbatimPhrase(
            scriptText: request.scriptText,
            exactPhrase: request.exactPhrase,
            handoffCueText: request.handoffCueText,
            preferHandoff: technique.appliesToHandoff && request.isSpeakerChangeHandoff
        )

        let action = technique.deliveryInstruction
        let rationale = buildAuthoredPreparationRationale(technique: technique, request: request)

        return CoachingSuggestion(
            task: .preparation,
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
            observationID: nil,
            action: action,
            rationale: rationale,
            promptVersion: request.promptVersion,
            sectionRevisionID: request.sectionRevisionID,
            attemptID: nil,
            evidenceVersion: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func makePreparationAbstention(
        request: PreparationCoachingRequest,
        origin: CoachingCueOrigin,
        fallbackReason: CoachingFallbackReason?,
        abstention: CoachingAbstentionOption,
        now: Date
    ) -> CoachingSuggestion {
        CoachingSuggestion(
            task: .preparation,
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
            action: abstention.renderedAction,
            rationale: abstention.renderedRationale,
            promptVersion: request.promptVersion,
            sectionRevisionID: request.sectionRevisionID,
            attemptID: nil,
            evidenceVersion: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    struct PhraseAnchor {
        let phrase: String?
        let fromHandoff: Bool
    }

    static func selectAuthoredPreparationTechnique(for request: PreparationCoachingRequest) -> CoachingTechnique {
        if let selectedID = request.selectedTechniqueID,
           let matched = request.candidateTechniques.first(where: { $0.id == selectedID })
            ?? technique(withID: selectedID) {
            return matched
        }

        let scriptLower = request.scriptText.lowercased()
        if request.isSpeakerChangeHandoff && request.hasHandoffCue {
            if request.purpose == .general || request.purpose == .story {
                return technique(withID: "handoff.echo-bridge") ?? request.candidateTechniques[0]
            }
            if scriptLower.contains("invite") || scriptLower.contains("welcome") {
                return technique(withID: "handoff.name-the-turn") ?? request.candidateTechniques[0]
            }
        }

        return selectTechniqueByPurpose(request: request, scriptLower: scriptLower)
    }

    static func selectVerbatimPhrase(
        scriptText: String,
        exactPhrase: String?,
        handoffCueText: String?,
        preferHandoff: Bool
    ) -> PhraseAnchor {
        if let exact = exactPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
           !exact.isEmpty,
           CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(
               exact,
               in: scriptText,
               allowShortStandalone: true
           ) {
            return PhraseAnchor(phrase: exact, fromHandoff: false)
        }
        if preferHandoff,
           let handoff = handoffCueText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !handoff.isEmpty,
           CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(handoff, in: handoff) {
            return PhraseAnchor(phrase: handoff, fromHandoff: true)
        }
        if let sentence = CoachingPassageExtractor.firstSpokenSentence(in: scriptText) {
            return PhraseAnchor(phrase: sentence, fromHandoff: false)
        }
        return PhraseAnchor(phrase: nil, fromHandoff: false)
    }
}

private extension TechniqueLibrary {
    static func selectTechniqueByPurpose(
        request: PreparationCoachingRequest,
        scriptLower: String
    ) -> CoachingTechnique {
        let fallback = request.candidateTechniques[0]
        switch request.purpose {
        case .reveal:
            return selectRevealTechnique(scriptLower: scriptLower, fallback: fallback)
        case .demonstration:
            return selectDemoTechnique(scriptText: request.scriptText, scriptLower: scriptLower, fallback: fallback)
        case .closing:
            return selectClosingTechnique(scriptText: request.scriptText, scriptLower: scriptLower, fallback: fallback)
        case .story:
            return technique(withID: "story.two-milestone-setup") ?? fallback
        case .general:
            let id = request.hasHandoffCue ? "handoff.clean-beat" : "general.two-axis-frame"
            return technique(withID: id) ?? fallback
        }
    }

    static func selectRevealTechnique(scriptLower: String, fallback: CoachingTechnique) -> CoachingTechnique {
        if scriptLower.contains("three") || scriptLower.contains("not three") {
            return technique(withID: "reveal.three-part-resolution") ?? fallback
        }
        if scriptLower.contains("?") && (scriptLower.contains("no.") || scriptLower.contains("instead")) {
            return technique(withID: "reveal.contrast-before-headline") ?? fallback
        }
        if scriptLower.contains("dollar") || scriptLower.contains("$") || scriptLower.contains("price") {
            return technique(withID: "reveal.anchor-before-number") ?? fallback
        }
        return technique(withID: "reveal.problem-to-short-line") ?? fallback
    }

    static func selectDemoTechnique(
        scriptText: String,
        scriptLower: String,
        fallback: CoachingTechnique
    ) -> CoachingTechnique {
        if scriptText.contains("[") && scriptText.contains("]") {
            return technique(withID: "demo.hold-for-load") ?? fallback
        }
        if scriptLower.contains("how do you") || scriptLower.contains("how do i") {
            return technique(withID: "demo.question-then-show") ?? fallback
        }
        if scriptLower.contains("corner") || scriptLower.contains("top bar") || scriptLower.contains("notice") {
            return technique(withID: "demo.anchor-screen-cue") ?? fallback
        }
        return technique(withID: "demo.narrate-the-gesture") ?? fallback
    }

    static func selectClosingTechnique(
        scriptText: String,
        scriptLower: String,
        fallback: CoachingTechnique
    ) -> CoachingTechnique {
        if scriptLower.contains("years ago") || scriptLower.contains("asked why") {
            return technique(withID: "close.opening-callback") ?? fallback
        }
        if scriptText.count <= 130 {
            return technique(withID: "close.short-final-line") ?? fallback
        }
        return technique(withID: "close.lineup-identity") ?? fallback
    }

    static func buildAuthoredPreparationRationale(
        technique: CoachingTechnique,
        request: PreparationCoachingRequest
    ) -> String {
        if technique.appliesToHandoff && request.isSpeakerChangeHandoff {
            return "Fits a speaker-change handoff into \(request.sectionTitle) while keeping your wording intact."
        }
        return "Matches this \(request.purpose.displayName.lowercased()) section " +
            "from the Macworld 2007 reference (\(technique.sourceTimestamp))."
    }
}
