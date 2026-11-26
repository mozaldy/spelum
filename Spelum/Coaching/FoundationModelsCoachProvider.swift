import Foundation
import FoundationModels

nonisolated protocol CoachingModelProviding: Sendable {
    func availability() -> CoachingModelAvailability
    func generatePreparation(_ request: PreparationCoachingRequest) async throws -> RawModelPreparationSelection
    func generatePostTake(_ request: PostTakeCoachingRequest) async throws -> RawModelPostTakeSelection
}

@Generable
nonisolated struct GeneratedPreparationSelection: Sendable {
    @Guide(description: "Set true only if an allowed abstentionReasonID applies. Otherwise false.")
    let shouldAbstain: Bool

    @Guide(description: "Exact ID from Allowed Abstention Options when shouldAbstain is true; else empty.")
    let abstentionReasonID: String

    @Guide(description: "Exact ID from Allowed Candidate Techniques when shouldAbstain is false; else empty.")
    let techniqueID: String

    @Guide(description: "Exact ID from Allowed Verbatim Passages when shouldAbstain is false; else empty.")
    let passageID: String

    @Guide(description: "Exact ID from Allowed Action Options matching techniqueID; empty when abstaining.")
    let actionID: String
}

@Generable
nonisolated struct GeneratedPostTakeSelection: Sendable {
    @Guide(description: "Set true when an allowed abstentionReasonID fits best or abstention is required.")
    let shouldAbstain: Bool

    @Guide(description: "Exact ID from Allowed Abstention Options when shouldAbstain is true; else empty.")
    let abstentionReasonID: String

    @Guide(description: "Exact ID from Allowed Candidate Techniques when shouldAbstain is false; else empty.")
    let techniqueID: String

    @Guide(description: "Exact ID from Allowed Verbatim Passages compatible with evidenceID; else empty.")
    let passageID: String

    @Guide(description: "Exact ID from Allowed Evidence Options when shouldAbstain is false; else empty.")
    let evidenceID: String

    @Guide(description: "Exact ID from Allowed Action Options matching evidenceID and techniqueID; else empty.")
    let actionID: String
}

nonisolated struct AppleFoundationModelsCoachProvider: CoachingModelProviding {
    private static let fallbackEnglishLocale = Locale(identifier: "en_US")

    func availability() -> CoachingModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            if Self.supportsEnglishLocale(model: model) {
                return .available
            }
            return .unavailable(.unsupportedLocale)
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.unknown)
            }
        }
    }

    func generatePreparation(_ request: PreparationCoachingRequest) async throws -> RawModelPreparationSelection {
        let optionSet = PreparationCoachingOptionSet.build(for: request)
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.preparationInstructions
        )
        let prompt = CoachingPromptBuilder.buildPreparationPrompt(for: request, optionSet: optionSet)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 256)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedPreparationSelection.self,
            options: options
        )
        let output = response.content
        return RawModelPreparationSelection(
            shouldAbstain: output.shouldAbstain,
            abstentionReasonID: Self.optionalID(output.abstentionReasonID),
            techniqueID: Self.optionalID(output.techniqueID),
            passageID: Self.optionalID(output.passageID),
            actionID: Self.optionalID(output.actionID)
        )
    }

    func generatePostTake(_ request: PostTakeCoachingRequest) async throws -> RawModelPostTakeSelection {
        let optionSet = PostTakeCoachingOptionSet.build(for: request)
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.postTakeInstructions
        )
        let prompt = CoachingPromptBuilder.buildPostTakePrompt(for: request, optionSet: optionSet)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 256)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedPostTakeSelection.self,
            options: options
        )
        let output = response.content
        return RawModelPostTakeSelection(
            shouldAbstain: output.shouldAbstain,
            abstentionReasonID: Self.optionalID(output.abstentionReasonID),
            techniqueID: Self.optionalID(output.techniqueID),
            passageID: Self.optionalID(output.passageID),
            evidenceID: Self.optionalID(output.evidenceID),
            actionID: Self.optionalID(output.actionID)
        )
    }
}

private extension AppleFoundationModelsCoachProvider {
    static let preparationInstructions = """
    You are an offline English presentation rehearsal coach inside Spelum.
    Select the best pre-practice option IDs from the supplied bounded menus.
    Rules:
    - Copy IDs verbatim from the provided lists. Never invent new IDs or rewrite passages.
    - Only set shouldAbstain = true when an ID appears in Allowed Abstention Options;
      leave techniqueID, passageID, and actionID empty when abstaining.
    - When shouldAbstain is false, leave abstentionReasonID empty and pick one actionID
      whose technique= and passages=[...] explicitly include your chosen techniqueID and passageID.
    - Prefer the marked exact phrase or handoff passage when it fits the technique best.
    """

    static let postTakeInstructions = """
    You are an offline English presentation rehearsal coach inside Spelum reviewing one saved take.
    Select the best post-take option IDs from the supplied bounded menus.
    Rules:
    - Copy IDs verbatim from the provided lists. Never invent new IDs.
    - Only set shouldAbstain = true when an ID appears in Allowed Abstention Options;
      leave techniqueID, passageID, evidenceID, and actionID empty when abstaining.
    - When shouldAbstain is false, leave abstentionReasonID empty and choose one evidenceID,
      one passageID in that evidence's passages=[...], one techniqueID in both the evidence's
      and action's techniques=[...], and one actionID whose evidence=[...] includes evidenceID.
    - Never treat scripted demo pauses or script reveals as proof of poor performance.
    """

    static func supportsEnglishLocale(model: SystemLanguageModel) -> Bool {
        let current = Locale.current
        if current.language.languageCode?.identifier == "en",
           model.supportsLocale(current) {
            return true
        }
        return model.supportsLocale(fallbackEnglishLocale)
    }

    static func optionalID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
