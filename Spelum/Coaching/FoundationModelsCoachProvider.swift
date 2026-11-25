import Foundation
import FoundationModels

nonisolated protocol CoachingModelProviding: Sendable {
    func availability() -> CoachingModelAvailability
    func generatePreparation(_ request: PreparationCoachingRequest) async throws -> RawModelCoachingSuggestion
    func generatePostTake(_ request: PostTakeCoachingRequest) async throws -> RawModelCoachingSuggestion
}

@Generable
nonisolated struct GeneratedPreparationOutput: Sendable {
    @Guide(description: "Set true only if no delivery cue is warranted for this passage.")
    let shouldAbstain: Bool

    @Guide(
        description: "Exact technique ID copied verbatim from the allowed candidates list, or empty if abstaining."
    )
    let techniqueID: String

    @Guide(
        description: "Exact verbatim substring copied from the script or handoff cue, or empty if abstaining."
    )
    let exactPhrase: String

    @Guide(
        description: "One concrete delivery experiment in 1-2 short sentences. No scores or voice/accent grading."
    )
    let action: String

    @Guide(description: "One brief sentence explaining why this technique fits this passage, or why abstaining fits.")
    let rationale: String
}

@Generable
nonisolated struct GeneratedPostTakeOutput: Sendable {
    @Guide(
        description: "Set true if the take looks strong and needs no correction, or if evidence is silent or ambiguous."
    )
    let shouldAbstain: Bool

    @Guide(
        description: "Exact technique ID copied verbatim from the allowed candidates list, or empty if abstaining."
    )
    let techniqueID: String

    @Guide(
        description: "Exact verbatim substring copied from the script or handoff cue, or empty if abstaining."
    )
    let exactPhrase: String

    @Guide(
        description: "Exact UUID string copied from validated observations, or empty if abstaining or none applies."
    )
    let observationID: String

    @Guide(
        description: "One concrete delivery experiment or calm abstention note. Never invent numbers or blame speakers."
    )
    let action: String

    @Guide(
        description: "One brief sentence grounded strictly in provided facts without scoring or judging voice/accent."
    )
    let rationale: String
}

nonisolated struct AppleFoundationModelsCoachProvider: CoachingModelProviding {
    private static let englishLocale = Locale(identifier: "en_US")

    func availability() -> CoachingModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            if model.supportsLocale(Self.englishLocale) {
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

    func generatePreparation(_ request: PreparationCoachingRequest) async throws -> RawModelCoachingSuggestion {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.preparationInstructions
        )
        let prompt = Self.buildPreparationPrompt(for: request)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 220)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedPreparationOutput.self,
            options: options
        )
        let output = response.content
        return RawModelCoachingSuggestion(
            shouldAbstain: output.shouldAbstain,
            techniqueID: output.techniqueID,
            exactPhrase: output.exactPhrase,
            observationID: nil,
            action: output.action,
            rationale: output.rationale
        )
    }

    func generatePostTake(_ request: PostTakeCoachingRequest) async throws -> RawModelCoachingSuggestion {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.postTakeInstructions
        )
        let prompt = Self.buildPostTakePrompt(for: request)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 240)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedPostTakeOutput.self,
            options: options
        )
        let output = response.content
        let trimmedObs = output.observationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return RawModelCoachingSuggestion(
            shouldAbstain: output.shouldAbstain,
            techniqueID: output.techniqueID,
            exactPhrase: output.exactPhrase,
            observationID: trimmedObs.isEmpty ? nil : trimmedObs,
            action: output.action,
            rationale: output.rationale
        )
    }
}

private extension AppleFoundationModelsCoachProvider {
    static let preparationInstructions = """
    You are an offline English presentation rehearsal coach inside Spelum.
    Offer one optional pre-practice delivery experiment grounded in the user's exact script.
    Rules:
    - Pick a techniqueID verbatim from the provided candidate techniques list.
    - Copy exactPhrase verbatim character-for-character from the script or handoff cue. Never rewrite quotes.
    - Give one concrete delivery experiment in 1-2 short sentences.
    - Never invent timing numbers, never give scores, and never judge accent, emotion, or voice similarity.
    - Never blame a speaker or teammate.
    """

    static let postTakeInstructions = """
    You are an offline English presentation rehearsal coach inside Spelum reviewing one saved take.
    Rules:
    - Set shouldAbstain = true when the take finished cleanly with no clear issue,
      or when audio/timing evidence is silent, declined, interrupted, or ambiguous.
    - When not abstaining, pick a techniqueID verbatim from allowed candidates and
      copy exactPhrase verbatim from the script or handoff cue.
    - Only set observationID to a UUID verbatim from validated observations;
      leave it empty if none applies or when abstaining.
    - Never invent measurements (WPM, seconds, timestamps, counts), never give scores,
      and never judge accent, pronunciation, emotion, or voice similarity.
    - Never attribute pauses or timing to any speaker name or teammate.
    """

    static func buildPreparationPrompt(for request: PreparationCoachingRequest) -> String {
        var lines: [String] = [
            "Task: Pre-practice coaching (\(request.promptVersion))",
            "Section title: \(request.sectionTitle)",
            "Section purpose: \(request.purpose.displayName)",
            "Speaker change handoff: \(request.isSpeakerChangeHandoff ? "yes" : "no")"
        ]
        if let handoff = request.handoffCueText, !handoff.isEmpty {
            lines.append("Handoff cue (verbatim): \(handoff)")
        }
        if let exact = request.exactPhrase, !exact.isEmpty {
            lines.append("Marked exact phrase: \(exact)")
        }
        if !request.cueWords.isEmpty {
            lines.append("Cue words: \(request.cueWords.joined(separator: ", "))")
        }
        lines.append("Script text (verbatim):\n\(request.scriptText)")
        if let pinnedID = request.selectedTechniqueID {
            lines.append("Required techniqueID: \(pinnedID)")
        }
        lines.append("Allowed candidate techniques:")
        for technique in request.candidateTechniques {
            lines.append("- \(technique.id) | \(technique.title) | \(technique.deliveryInstruction)")
        }
        return lines.joined(separator: "\n")
    }

    static func buildPostTakePrompt(for request: PostTakeCoachingRequest) -> String {
        var lines: [String] = [
            "Task: Post-take review coaching (\(request.promptVersion))",
            "Section title: \(request.sectionTitle)",
            "Section purpose: \(request.purpose.displayName)",
            "Attempt status: \(request.attemptStatus.displayName)",
            "Practice mode: \(request.practiceMode.displayName)",
            "Measured playable duration: \(String(format: "%.1f", request.playableDuration))s",
            "Measured script reveals: \(request.revealCount)",
            "Measured manual markers: \(request.markers.count)",
            "Multi-speaker handoff: \(request.isSpeakerChangeHandoff ? "yes" : "no")"
        ]
        if let exact = request.exactPhrase, !exact.isEmpty {
            lines.append("Marked exact phrase: \(exact)")
        }
        if let handoff = request.handoffCueText, !handoff.isEmpty {
            lines.append("Handoff cue (verbatim): \(handoff)")
        }
        lines.append("Script text (verbatim):\n\(request.scriptText)")
        appendTimingEvidence(from: request, to: &lines)
        lines.append("Allowed candidate techniques:")
        for technique in request.candidateTechniques {
            lines.append("- \(technique.id) | \(technique.title) | \(technique.postTakeFocus)")
        }
        return lines.joined(separator: "\n")
    }

    static func appendTimingEvidence(from request: PostTakeCoachingRequest, to lines: inout [String]) {
        guard let analysis = request.timingAnalysis else {
            lines.append("Timing analysis: unavailable")
            return
        }
        lines.append("Timing analysis outcome: \(analysis.outcome.rawValue)")
        if let wpm = analysis.estimatedWordsPerMinute {
            lines.append("Estimated pace: \(Int(wpm.rounded())) WPM")
        }
        if analysis.observations.isEmpty {
            lines.append("Validated observations: none")
        } else {
            lines.append("Validated observations (use exact UUID only):")
            for obs in analysis.observations {
                let gapText = obs.gapDuration.map { String(format: ", gap=%.1fs", $0) } ?? ""
                let phraseText = obs.matchedPhrase.map { ", phrase=\"\($0)\"" } ?? ""
                lines.append(
                    "- id=\(obs.id.uuidString) | kind=\(obs.kind.rawValue) | " +
                    "\(String(format: "%.1f", obs.startTime))s-\(String(format: "%.1f", obs.endTime))s" +
                    "\(gapText)\(phraseText)"
                )
            }
        }
        if !analysis.ambiguousNotes.isEmpty {
            lines.append("Ambiguous evidence notes:")
            for note in analysis.ambiguousNotes {
                lines.append("- \(note.reason.rawValue): \(note.explanation)")
            }
        }
    }
}
