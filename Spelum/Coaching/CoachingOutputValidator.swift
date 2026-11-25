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
    static let maxActionLength = 320
    static let maxRationaleLength = 260

    static func validatePreparation(
        raw: RawModelCoachingSuggestion,
        request: PreparationCoachingRequest,
        now: Date = Date()
    ) -> CoachingValidationVerdict {
        guard let text = validateBaseText(
            raw: raw,
            knownSpeakerNames: request.knownSpeakerNames,
            isMultiSpeaker: request.isSpeakerChangeHandoff,
            allowedNumbers: allowedPreparationNumbers()
        ) else {
            return .invalid(
                baseTextFailure(
                    raw: raw,
                    knownSpeakerNames: request.knownSpeakerNames,
                    isMultiSpeaker: request.isSpeakerChangeHandoff,
                    allowedNumbers: allowedPreparationNumbers()
                )
            )
        }

        if raw.shouldAbstain {
            return .valid(
                makeAbstentionSuggestion(
                    task: .preparation,
                    action: text.action,
                    rationale: text.rationale,
                    promptVersion: request.promptVersion,
                    sectionRevisionID: request.sectionRevisionID,
                    attemptID: nil,
                    evidenceVersion: nil,
                    now: now
                )
            )
        }

        return buildPreparationSuggestion(raw: raw, request: request, text: text, now: now)
    }

    static func validatePostTake(
        raw: RawModelCoachingSuggestion,
        request: PostTakeCoachingRequest,
        now: Date = Date()
    ) -> CoachingValidationVerdict {
        let allowed = allowedPostTakeNumbers(for: request)
        guard let text = validateBaseText(
            raw: raw,
            knownSpeakerNames: request.knownSpeakerNames,
            isMultiSpeaker: request.isSpeakerChangeHandoff,
            allowedNumbers: allowed
        ) else {
            return .invalid(
                baseTextFailure(
                    raw: raw,
                    knownSpeakerNames: request.knownSpeakerNames,
                    isMultiSpeaker: request.isSpeakerChangeHandoff,
                    allowedNumbers: allowed
                )
            )
        }

        let resolvedObservationID: UUID?
        do {
            resolvedObservationID = try resolveObservationID(raw.observationID, request: request)
        } catch {
            return .invalid(.unknownObservationID)
        }

        if raw.shouldAbstain {
            guard resolvedObservationID == nil else {
                return .invalid(.unknownObservationID)
            }
            return .valid(
                makeAbstentionSuggestion(
                    task: .postTake,
                    action: text.action,
                    rationale: text.rationale,
                    promptVersion: request.promptVersion,
                    sectionRevisionID: request.sectionRevisionID,
                    attemptID: request.attemptID,
                    evidenceVersion: request.evidenceVersion,
                    now: now
                )
            )
        }

        return buildPostTakeSuggestion(
            raw: raw,
            request: request,
            text: text,
            observationID: resolvedObservationID,
            now: now
        )
    }
}

private extension CoachingOutputValidator {
    struct ValidatedText {
        let action: String
        let rationale: String
    }

    static func validateBaseText(
        raw: RawModelCoachingSuggestion,
        knownSpeakerNames: [String],
        isMultiSpeaker: Bool,
        allowedNumbers: CoachingAllowedNumbers
    ) -> ValidatedText? {
        let action = raw.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let rationale = raw.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, action.count <= maxActionLength,
              !rationale.isEmpty, rationale.count <= maxRationaleLength else {
            return nil
        }
        let combined = "\(action) \(rationale)"
        guard !containsDisallowedClaim(in: combined),
              !containsUnsupportedSpeakerJudgment(
                  in: combined,
                  knownSpeakerNames: knownSpeakerNames,
                  isMultiSpeaker: isMultiSpeaker
              ),
              !containsInventedMeasurement(in: combined, allowedNumbers: allowedNumbers) else {
            return nil
        }
        return ValidatedText(action: action, rationale: rationale)
    }

    static func baseTextFailure(
        raw: RawModelCoachingSuggestion,
        knownSpeakerNames: [String],
        isMultiSpeaker: Bool,
        allowedNumbers: CoachingAllowedNumbers
    ) -> CoachingValidationFailure {
        let action = raw.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let rationale = raw.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, action.count <= maxActionLength,
              !rationale.isEmpty, rationale.count <= maxRationaleLength else {
            return .emptyOrInvalidAction
        }
        let combined = "\(action) \(rationale)"
        if containsDisallowedClaim(in: combined) {
            return .disallowedCoachingClaim
        }
        if containsUnsupportedSpeakerJudgment(
            in: combined,
            knownSpeakerNames: knownSpeakerNames,
            isMultiSpeaker: isMultiSpeaker
        ) {
            return .unsupportedSpeakerJudgment
        }
        return .inventedMeasurement
    }

    // swiftlint:disable:next function_parameter_count
    static func makeAbstentionSuggestion(
        task: CoachingTaskKind,
        action: String,
        rationale: String,
        promptVersion: String,
        sectionRevisionID: UUID,
        attemptID: UUID?,
        evidenceVersion: String?,
        now: Date
    ) -> CoachingSuggestion {
        CoachingSuggestion(
            task: task,
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
            action: action,
            rationale: rationale,
            promptVersion: promptVersion,
            sectionRevisionID: sectionRevisionID,
            attemptID: attemptID,
            evidenceVersion: evidenceVersion,
            createdAt: now,
            updatedAt: now
        )
    }

    static func buildPreparationSuggestion(
        raw: RawModelCoachingSuggestion,
        request: PreparationCoachingRequest,
        text: ValidatedText,
        now: Date
    ) -> CoachingValidationVerdict {
        guard let technique = resolveTechnique(
            id: raw.techniqueID,
            candidates: request.candidateTechniques,
            pinnedTechniqueID: request.selectedTechniqueID
        ) else {
            return .invalid(.unknownTechniqueID)
        }
        guard let matchedPhrase = verifyVerbatimPhrase(
            raw.exactPhrase,
            scriptText: request.scriptText,
            handoffCueText: request.handoffCueText
        ) else {
            return .invalid(.alteredOrInventedQuote)
        }
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
                exactPhrase: matchedPhrase.phrase,
                exactPhraseFromHandoff: matchedPhrase.fromHandoff,
                observationID: nil,
                action: text.action,
                rationale: text.rationale,
                promptVersion: request.promptVersion,
                sectionRevisionID: request.sectionRevisionID,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    static func buildPostTakeSuggestion(
        raw: RawModelCoachingSuggestion,
        request: PostTakeCoachingRequest,
        text: ValidatedText,
        observationID: UUID?,
        now: Date
    ) -> CoachingValidationVerdict {
        guard let technique = resolveTechnique(
            id: raw.techniqueID,
            candidates: request.candidateTechniques,
            pinnedTechniqueID: nil
        ) else {
            return .invalid(.unknownTechniqueID)
        }
        guard let matchedPhrase = verifyVerbatimPhrase(
            raw.exactPhrase,
            scriptText: request.scriptText,
            handoffCueText: request.handoffCueText
        ) else {
            return .invalid(.alteredOrInventedQuote)
        }
        return .valid(
            CoachingSuggestion(
                task: .postTake,
                origin: .onDeviceModel,
                isAbstention: false,
                techniqueID: technique.id,
                techniqueTitle: technique.title,
                sourceWork: technique.sourceWork,
                sourceTimestamp: technique.sourceTimestamp,
                sourcePassageSummary: technique.sourcePassageSummary,
                exactPhrase: matchedPhrase.phrase,
                exactPhraseFromHandoff: matchedPhrase.fromHandoff,
                observationID: observationID,
                action: text.action,
                rationale: text.rationale,
                promptVersion: request.promptVersion,
                sectionRevisionID: request.sectionRevisionID,
                attemptID: request.attemptID,
                evidenceVersion: request.evidenceVersion,
                createdAt: now,
                updatedAt: now
            )
        )
    }
}
