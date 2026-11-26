import Foundation
import Observation

nonisolated final class SectionCoachService: Sendable {
    static let preparationPromptVersion = "prep-v3"
    static let postTakePromptVersion = "review-v3"

    let modelProvider: any CoachingModelProviding
    let policy: CoachingFeaturePolicy

    init(
        modelProvider: any CoachingModelProviding = AppleFoundationModelsCoachProvider(),
        policy: CoachingFeaturePolicy = .default
    ) {
        self.modelProvider = modelProvider
        self.policy = policy
    }

    func modelAvailability() -> CoachingModelAvailability {
        modelProvider.availability()
    }

    func generatePreparationCue(
        request: PreparationCoachingRequest,
        mode: CoachingSourceMode? = nil,
        now: Date = Date()
    ) async -> CoachingSuggestion {
        let effectiveMode = mode ?? policy.defaultMode(for: .preparation)
        if effectiveMode == .authoredBaseline {
            return TechniqueLibrary.authoredPreparationSuggestion(
                for: request,
                origin: .authoredBaseline,
                fallbackReason: nil,
                now: now
            )
        }

        let availability = modelProvider.availability()
        if case .unavailable(let reason) = availability {
            return TechniqueLibrary.authoredPreparationSuggestion(
                for: request,
                origin: .authoredFallback,
                fallbackReason: .modelUnavailable(reason),
                now: now
            )
        }

        do {
            let selection = try await modelProvider.generatePreparation(request)
            let verdict = CoachingOutputValidator.validatePreparation(
                selection: selection,
                request: request,
                now: now
            )
            if let valid = verdict.suggestion {
                return valid
            }
            let failure = verdict.failureReason ?? .incompatibleSelection
            return TechniqueLibrary.authoredPreparationSuggestion(
                for: request,
                origin: .authoredFallback,
                fallbackReason: .validationFailed(failure),
                now: now
            )
        } catch {
            return TechniqueLibrary.authoredPreparationSuggestion(
                for: request,
                origin: .authoredFallback,
                fallbackReason: .generationError(error.localizedDescription),
                now: now
            )
        }
    }

    func generatePostTakeCue(
        request: PostTakeCoachingRequest,
        mode: CoachingSourceMode? = nil,
        now: Date = Date()
    ) async -> CoachingSuggestion {
        let effectiveMode = mode ?? policy.defaultMode(for: .postTake)
        if effectiveMode == .authoredBaseline {
            return TechniqueLibrary.authoredPostTakeSuggestion(
                for: request,
                origin: .authoredBaseline,
                fallbackReason: nil,
                now: now
            )
        }

        let availability = modelProvider.availability()
        if case .unavailable(let reason) = availability {
            return TechniqueLibrary.authoredPostTakeSuggestion(
                for: request,
                origin: .authoredFallback,
                fallbackReason: .modelUnavailable(reason),
                now: now
            )
        }

        do {
            let selection = try await modelProvider.generatePostTake(request)
            let verdict = CoachingOutputValidator.validatePostTake(
                selection: selection,
                request: request,
                now: now
            )
            if let valid = verdict.suggestion {
                return valid
            }
            let failure = verdict.failureReason ?? .incompatibleSelection
            return TechniqueLibrary.authoredPostTakeSuggestion(
                for: request,
                origin: .authoredFallback,
                fallbackReason: .validationFailed(failure),
                now: now
            )
        } catch {
            return TechniqueLibrary.authoredPostTakeSuggestion(
                for: request,
                origin: .authoredFallback,
                fallbackReason: .generationError(error.localizedDescription),
                now: now
            )
        }
    }

    @MainActor
    static func makePreparationRequest(
        section: SectionRevisionRecord,
        talkRevisionID: UUID,
        handoff: HandoffContext?,
        knownSpeakerNames: [String] = [],
        selectedTechniqueID: String? = nil,
        promptVersion: String = SectionCoachService.preparationPromptVersion
    ) -> PreparationCoachingRequest {
        let handoffText = handoff?.effectiveCueText
        let hasHandoff = !(handoffText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let isSpeakerChange = handoff?.isSpeakerChange ?? false
        let isMultiSpeaker = (handoff?.isSingleSpeakerTalk == false) || knownSpeakerNames.count > 1
        let candidates = TechniqueLibrary.candidateTechniques(
            for: section.purpose,
            hasHandoff: hasHandoff
        )
        return PreparationCoachingRequest(
            presentationID: section.presentation?.id,
            sectionRevisionID: section.revisionID,
            talkRevisionID: talkRevisionID,
            sectionTitle: section.title,
            scriptText: section.text,
            exactPhrase: section.exactPhrase,
            cueWords: section.cueWords,
            purpose: section.purpose,
            handoffCueText: handoffText,
            isSpeakerChangeHandoff: isSpeakerChange,
            isMultiSpeakerTalk: isMultiSpeaker,
            knownSpeakerNames: knownSpeakerNames,
            selectedTechniqueID: selectedTechniqueID,
            candidateTechniques: candidates,
            promptVersion: promptVersion
        )
    }

    @MainActor
    static func makePostTakeRequest(
        attempt: AttemptRecord,
        section: SectionRevisionRecord,
        handoff: HandoffContext?,
        knownSpeakerNames: [String],
        timingAnalysis: TimingAnalysisResult?,
        promptVersion: String = SectionCoachService.postTakePromptVersion
    ) -> PostTakeCoachingRequest {
        let handoffText = handoff?.effectiveCueText
        let hasHandoff = !(handoffText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let isSpeakerChange = handoff?.isSpeakerChange ?? false
        let isMultiSpeaker = (handoff?.isSingleSpeakerTalk == false) || knownSpeakerNames.count > 1
        let candidates = TechniqueLibrary.candidateTechniques(
            for: section.purpose,
            hasHandoff: hasHandoff
        )
        return PostTakeCoachingRequest(
            presentationID: attempt.presentationID,
            attemptID: attempt.id,
            talkRevisionID: attempt.talkRevisionID,
            sectionRevisionID: attempt.sectionRevisionID,
            sectionTitle: section.title,
            scriptText: section.text,
            exactPhrase: section.exactPhrase,
            cueWords: section.cueWords,
            purpose: section.purpose,
            handoffCueText: handoffText,
            isSpeakerChangeHandoff: isSpeakerChange,
            isMultiSpeakerTalk: isMultiSpeaker,
            knownSpeakerNames: knownSpeakerNames,
            attemptStatus: attempt.status,
            practiceMode: attempt.practiceMode,
            playableDuration: attempt.playableDuration,
            revealCount: attempt.revealCount,
            markers: attempt.markers,
            timingAnalysis: timingAnalysis,
            candidateTechniques: candidates,
            promptVersion: promptVersion
        )
    }
}
