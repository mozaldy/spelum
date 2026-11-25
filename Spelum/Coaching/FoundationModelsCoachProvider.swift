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
        let prompt = Self.buildPreparationPrompt(for: request, optionSet: optionSet)
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
        let prompt = Self.buildPostTakePrompt(for: request, optionSet: optionSet)
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
    - If shouldAbstain is true, provide only an allowed abstentionReasonID
      and leave techniqueID, passageID, and actionID empty.
    - If shouldAbstain is false, leave abstentionReasonID empty and pick one
      techniqueID, one passageID, and one compatible actionID.
    - Prefer the marked exact phrase or handoff passage when it fits the technique best.
    """

    static let postTakeInstructions = """
    You are an offline English presentation rehearsal coach inside Spelum reviewing one saved take.
    Select the best post-take option IDs from the supplied bounded menus.
    Rules:
    - Copy IDs verbatim from the provided lists. Never invent new IDs.
    - When abstention is required or the take finished cleanly with no clear adjustment needed,
      set shouldAbstain = true, pick an allowed abstentionReasonID, and leave
      techniqueID, passageID, evidenceID, and actionID empty.
    - When shouldAbstain is false, leave abstentionReasonID empty and choose one
      evidenceID, one compatible passageID, one compatible techniqueID, and one compatible actionID.
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

    static func buildPreparationPrompt(
        for request: PreparationCoachingRequest,
        optionSet: PreparationCoachingOptionSet
    ) -> String {
        var lines: [String] = [
            "Task: Pre-practice bounded selection (\(request.promptVersion))",
            "Section title: \(request.sectionTitle)",
            "Section purpose: \(request.purpose.displayName)",
            "Speaker change handoff: \(request.isSpeakerChangeHandoff ? "yes" : "no")",
            "Abstention required: \(optionSet.mustAbstain ? "yes" : "no")"
        ]
        if !request.cueWords.isEmpty {
            lines.append("Cue words: \(request.cueWords.joined(separator: ", "))")
        }
        lines.append("Script context:\n\(request.scriptText)")
        appendAbstentionOptions(optionSet.abstentionOptions, to: &lines)
        lines.append("Allowed Candidate Techniques:")
        for technique in optionSet.candidateTechniques {
            lines.append("- \(technique.id) | \(technique.title) | handoff=\(technique.appliesToHandoff ? "yes" : "no")")
        }
        lines.append("Allowed Verbatim Passages:")
        for passage in optionSet.passageOptions {
            lines.append("- \(passage.id) | role=\(passage.role.rawValue) | \"\(passage.phrase)\"")
        }
        lines.append("Allowed Action Options:")
        for action in optionSet.actionOptions {
            lines.append("- \(action.id) | technique=\(action.techniqueID) | \(action.summaryForModel)")
        }
        return lines.joined(separator: "\n")
    }

    static func buildPostTakePrompt(
        for request: PostTakeCoachingRequest,
        optionSet: PostTakeCoachingOptionSet
    ) -> String {
        var lines: [String] = [
            "Task: Post-take bounded selection (\(request.promptVersion))",
            "Section title: \(request.sectionTitle)",
            "Section purpose: \(request.purpose.displayName)",
            "Attempt status: \(request.attemptStatus.displayName)",
            "Practice mode: \(request.practiceMode.displayName)",
            "Recorded reveals: \(request.revealCount)",
            "Recorded markers: \(request.markers.count)",
            "Abstention required: \(optionSet.mustAbstain ? "yes" : "no")"
        ]
        appendAbstentionOptions(optionSet.abstentionOptions, to: &lines)
        if !optionSet.mustAbstain {
            lines.append("Allowed Evidence Options:")
            for item in optionSet.evidenceOptions {
                let passages = item.compatiblePassageIDs.sorted().joined(separator: ",")
                lines.append("- \(item.id) | \(item.summaryForModel) | passages=[\(passages)]")
            }
            lines.append("Allowed Verbatim Passages:")
            for passage in optionSet.passageOptions {
                lines.append("- \(passage.id) | role=\(passage.role.rawValue) | \"\(passage.phrase)\"")
            }
            lines.append("Allowed Candidate Techniques:")
            for technique in optionSet.candidateTechniques {
                lines.append("- \(technique.id) | \(technique.title) | \(technique.postTakeFocus)")
            }
            lines.append("Allowed Action Options:")
            for action in optionSet.actionOptions {
                let evList = action.compatibleEvidenceIDs.sorted().joined(separator: ",")
                lines.append("- \(action.id) | evidence=[\(evList)] | \(action.summaryForModel)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func appendAbstentionOptions(
        _ options: [CoachingAbstentionOption],
        to lines: inout [String]
    ) {
        if options.isEmpty {
            lines.append("Allowed Abstention Options: none")
            return
        }
        lines.append("Allowed Abstention Options:")
        for option in options {
            lines.append("- \(option.id) | \(option.summaryForModel)")
        }
    }
}
