import Foundation

nonisolated struct CoachingValidationVerdict: Equatable, Sendable {
    let suggestion: CoachingSuggestion?
    let failureReason: CoachingValidationFailure?

    var isValid: Bool { suggestion != nil && failureReason == nil }

    static func valid(_ suggestion: CoachingSuggestion) -> CoachingValidationVerdict {
        CoachingValidationVerdict(suggestion: suggestion, failureReason: nil)
    }

    static func invalid(_ reason: CoachingValidationFailure) -> CoachingValidationVerdict {
        CoachingValidationVerdict(suggestion: nil, failureReason: reason)
    }
}

nonisolated enum CoachingOutputValidator {
    static func validatePreparation(
        selection: RawModelPreparationSelection,
        request: PreparationCoachingRequest,
        now: Date = Date()
    ) -> CoachingValidationVerdict {
        let optionSet = PreparationCoachingOptionSet.build(for: request)

        if selection.shouldAbstain {
            return validatePreparationAbstention(
                selection: selection,
                optionSet: optionSet,
                request: request,
                now: now
            )
        }

        guard !optionSet.mustAbstain else {
            return .invalid(.invalidAbstentionState)
        }
        guard normalizedOptionalID(selection.abstentionReasonID) == nil else {
            return .invalid(.invalidAbstentionState)
        }

        return buildPreparationSuggestion(
            selection: selection,
            optionSet: optionSet,
            request: request,
            now: now
        )
    }

    static func validatePostTake(
        selection: RawModelPostTakeSelection,
        request: PostTakeCoachingRequest,
        now: Date = Date()
    ) -> CoachingValidationVerdict {
        let optionSet = PostTakeCoachingOptionSet.build(for: request)

        if selection.shouldAbstain {
            return validatePostTakeAbstention(
                selection: selection,
                optionSet: optionSet,
                request: request,
                now: now
            )
        }

        guard !optionSet.mustAbstain else {
            return .invalid(.invalidAbstentionState)
        }
        guard normalizedOptionalID(selection.abstentionReasonID) == nil else {
            return .invalid(.invalidAbstentionState)
        }

        return buildPostTakeSuggestion(
            selection: selection,
            optionSet: optionSet,
            request: request,
            now: now
        )
    }
}

private extension CoachingOutputValidator {
    static func normalizedOptionalID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "none" || trimmed.lowercased() == "null" {
            return nil
        }
        return trimmed
    }

    static func validatePreparationAbstention(
        selection: RawModelPreparationSelection,
        optionSet: PreparationCoachingOptionSet,
        request: PreparationCoachingRequest,
        now: Date
    ) -> CoachingValidationVerdict {
        guard normalizedOptionalID(selection.techniqueID) == nil,
              normalizedOptionalID(selection.passageID) == nil,
              normalizedOptionalID(selection.actionID) == nil else {
            return .invalid(.invalidAbstentionState)
        }
        guard let reasonID = normalizedOptionalID(selection.abstentionReasonID),
              let abstention = optionSet.abstentionOptions.first(where: { $0.id == reasonID }) else {
            return .invalid(.invalidAbstentionState)
        }
        return .valid(
            CoachingSuggestion(
                task: .preparation,
                origin: .onDeviceModel,
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
                createdAt: now,
                updatedAt: now
            )
        )
    }

    static func validatePostTakeAbstention(
        selection: RawModelPostTakeSelection,
        optionSet: PostTakeCoachingOptionSet,
        request: PostTakeCoachingRequest,
        now: Date
    ) -> CoachingValidationVerdict {
        guard normalizedOptionalID(selection.techniqueID) == nil,
              normalizedOptionalID(selection.passageID) == nil,
              normalizedOptionalID(selection.evidenceID) == nil,
              normalizedOptionalID(selection.actionID) == nil else {
            return .invalid(.invalidAbstentionState)
        }
        guard let reasonID = normalizedOptionalID(selection.abstentionReasonID),
              let abstention = optionSet.abstentionOptions.first(where: { $0.id == reasonID }) else {
            return .invalid(.invalidAbstentionState)
        }
        return .valid(
            CoachingSuggestion(
                task: .postTake,
                origin: .onDeviceModel,
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
                attemptID: request.attemptID,
                evidenceVersion: request.evidenceVersion,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    static func buildPreparationSuggestion(
        selection: RawModelPreparationSelection,
        optionSet: PreparationCoachingOptionSet,
        request: PreparationCoachingRequest,
        now: Date
    ) -> CoachingValidationVerdict {
        guard let techniqueID = normalizedOptionalID(selection.techniqueID),
              let technique = optionSet.candidateTechniques.first(where: { $0.id == techniqueID }) else {
            return .invalid(.unknownTechniqueID)
        }
        guard let passageID = normalizedOptionalID(selection.passageID),
              let passage = optionSet.passageOptions.first(where: { $0.id == passageID }) else {
            return .invalid(.unknownPassageID)
        }
        guard verifyPassageSource(
            passage,
            scriptText: request.scriptText,
            handoffCueText: request.handoffCueText
        ) else {
            return .invalid(.alteredOrInventedQuote)
        }
        guard let actionID = normalizedOptionalID(selection.actionID),
              let action = optionSet.actionOptions.first(where: { $0.id == actionID }) else {
            return .invalid(.unknownActionID)
        }
        let passageCompatible = passage.fromHandoff
            ? (action.allowsHandoffPassage && technique.appliesToHandoff)
            : action.allowsScriptPassage
        guard action.techniqueID == technique.id, passageCompatible else {
            return .invalid(.incompatibleSelection)
        }

        let rationale = optionSet.renderRationale(
            technique: technique,
            passage: passage,
            request: request
        )
        return .valid(
            CoachingSuggestion(
                task: .preparation,
                origin: .onDeviceModel,
                isAbstention: false,
                techniqueID: technique.id,
                techniqueTitle: technique.title,
                sourceWork: technique.sourceWork,
                sourceTimestamp: technique.sourceTimestamp,
                sourcePassageSummary: technique.sourcePassageSummary,
                exactPhrase: passage.phrase,
                exactPhraseFromHandoff: passage.fromHandoff,
                observationID: nil,
                action: action.renderedAction,
                rationale: rationale,
                promptVersion: request.promptVersion,
                sectionRevisionID: request.sectionRevisionID,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    static func buildPostTakeSuggestion(
        selection: RawModelPostTakeSelection,
        optionSet: PostTakeCoachingOptionSet,
        request: PostTakeCoachingRequest,
        now: Date
    ) -> CoachingValidationVerdict {
        guard let techniqueID = normalizedOptionalID(selection.techniqueID),
              let technique = optionSet.candidateTechniques.first(where: { $0.id == techniqueID }) else {
            return .invalid(.unknownTechniqueID)
        }
        guard let evidenceID = normalizedOptionalID(selection.evidenceID),
              let evidence = optionSet.evidenceOptions.first(where: { $0.id == evidenceID }) else {
            let reason: CoachingValidationFailure = evidenceIDLooksLikeObservation(selection.evidenceID)
                ? .unknownObservationID
                : .unknownEvidenceID
            return .invalid(reason)
        }
        guard let passageID = normalizedOptionalID(selection.passageID),
              let passage = optionSet.passageOptions.first(where: { $0.id == passageID }) else {
            return .invalid(.unknownPassageID)
        }
        guard verifyPassageSource(
            passage,
            scriptText: request.scriptText,
            handoffCueText: request.handoffCueText
        ) else {
            return .invalid(.alteredOrInventedQuote)
        }
        guard let actionID = normalizedOptionalID(selection.actionID),
              let action = optionSet.actionOptions.first(where: { $0.id == actionID }) else {
            return .invalid(.unknownActionID)
        }

        guard isPostTakeCombinationValid(
            technique: technique,
            evidence: evidence,
            passage: passage,
            action: action
        ) else {
            return .invalid(.incompatibleSelection)
        }
        guard isObservationBacked(evidence: evidence, in: request) else {
            return .invalid(.unknownObservationID)
        }

        return .valid(
            renderPostTakeSuggestion(
                technique: technique,
                evidence: evidence,
                passage: passage,
                action: action,
                optionSet: optionSet,
                request: request,
                now: now
            )
        )
    }

    static func isPostTakeCombinationValid(
        technique: CoachingTechnique,
        evidence: CoachingEvidenceOption,
        passage: CoachingPassageOption,
        action: CoachingPostTakeActionOption
    ) -> Bool {
        evidence.compatiblePassageIDs.contains(passage.id)
            && evidence.compatibleTechniqueIDs.contains(technique.id)
            && action.compatibleEvidenceIDs.contains(evidence.id)
            && action.compatibleTechniqueIDs.contains(technique.id)
    }

    static func isObservationBacked(
        evidence: CoachingEvidenceOption,
        in request: PostTakeCoachingRequest
    ) -> Bool {
        guard let obsID = evidence.observationID else { return true }
        return request.timingAnalysis?.outcome == .completed
            && request.timingAnalysis?.observations.contains(where: { $0.id == obsID }) == true
    }

    // swiftlint:disable:next function_parameter_count
    static func renderPostTakeSuggestion(
        technique: CoachingTechnique,
        evidence: CoachingEvidenceOption,
        passage: CoachingPassageOption,
        action: CoachingPostTakeActionOption,
        optionSet: PostTakeCoachingOptionSet,
        request: PostTakeCoachingRequest,
        now: Date
    ) -> CoachingSuggestion {
        let renderedAction = optionSet.renderAction(
            template: action.template,
            evidence: evidence,
            technique: technique
        )
        let renderedRationale = optionSet.renderRationale(
            evidence: evidence,
            technique: technique,
            request: request
        )
        return CoachingSuggestion(
            task: .postTake,
            origin: .onDeviceModel,
            isAbstention: false,
            techniqueID: technique.id,
            techniqueTitle: technique.title,
            sourceWork: technique.sourceWork,
            sourceTimestamp: technique.sourceTimestamp,
            sourcePassageSummary: technique.sourcePassageSummary,
            exactPhrase: passage.phrase,
            exactPhraseFromHandoff: passage.fromHandoff,
            observationID: evidence.observationID,
            action: renderedAction,
            rationale: renderedRationale,
            promptVersion: request.promptVersion,
            sectionRevisionID: request.sectionRevisionID,
            attemptID: request.attemptID,
            evidenceVersion: request.evidenceVersion,
            createdAt: now,
            updatedAt: now
        )
    }

    static func verifyPassageSource(
        _ passage: CoachingPassageOption,
        scriptText: String,
        handoffCueText: String?
    ) -> Bool {
        let allowShort = passage.role == .markedExactPhrase
        if passage.fromHandoff {
            guard let handoffCueText else { return false }
            return CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(
                passage.phrase,
                in: handoffCueText,
                allowShortStandalone: allowShort
            )
        }
        return CoachingPassageExtractor.isVerifiedSpokenVerbatimMatch(
            passage.phrase,
            in: scriptText,
            allowShortStandalone: allowShort
        )
    }

    static func evidenceIDLooksLikeObservation(_ rawID: String?) -> Bool {
        guard let trimmed = normalizedOptionalID(rawID) else { return false }
        return trimmed.hasPrefix("obs.") || UUID(uuidString: trimmed) != nil
    }
}
