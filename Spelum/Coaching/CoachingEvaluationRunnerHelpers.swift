import Foundation

nonisolated struct EvaluationEntryMetadata: Sendable {
    let id: String
    let category: CoachingCategory
    let title: String
    let sectionTitle: String
    let scriptText: String
    let exactPhrase: String?
    let handoffCueText: String?
    let isSpeakerChangeHandoff: Bool
    let knownSpeakerNames: [String]
    let postTakeEvidence: EvaluationPostTakeEvidence?
    let tags: [String]
    let expectsAbstention: Bool
    let contextSummary: String

    init(from evalCase: PreparationEvaluationCase) {
        self.id = evalCase.id
        self.category = evalCase.category
        self.title = evalCase.title
        self.sectionTitle = evalCase.sectionTitle
        self.scriptText = evalCase.scriptText
        self.exactPhrase = evalCase.exactPhrase
        self.handoffCueText = evalCase.handoffCueText
        self.isSpeakerChangeHandoff = evalCase.isSpeakerChangeHandoff
        self.knownSpeakerNames = evalCase.knownSpeakerNames
        self.postTakeEvidence = nil
        self.tags = evalCase.tags
        self.expectsAbstention = evalCase.expectsAbstention
        self.contextSummary = "Purpose: \(evalCase.purpose.displayName)"
    }

    init(from evalCase: PostTakeEvaluationCase) {
        self.id = evalCase.id
        self.category = evalCase.category
        self.title = evalCase.title
        self.sectionTitle = evalCase.sectionTitle
        self.scriptText = evalCase.scriptText
        self.exactPhrase = evalCase.exactPhrase
        self.handoffCueText = evalCase.handoffCueText
        self.isSpeakerChangeHandoff = evalCase.isSpeakerChangeHandoff
        self.knownSpeakerNames = evalCase.knownSpeakerNames
        self.postTakeEvidence = EvaluationPostTakeEvidence(from: evalCase)
        self.tags = evalCase.tags
        self.expectsAbstention = evalCase.expectsAbstention
        self.contextSummary = Self.postTakeContextSummary(for: evalCase)
    }

    func makeBlindedEntry(
        authored: CoachingSuggestion,
        model: CoachingSuggestion,
        latencyMS: Double?,
        modelFirst: Bool
    ) -> BlindedEvaluationEntry {
        BlindedEvaluationEntry(
            id: id,
            category: category,
            title: title,
            sectionTitle: sectionTitle,
            scriptText: scriptText,
            exactPhrase: exactPhrase,
            handoffCueText: handoffCueText,
            isSpeakerChangeHandoff: isSpeakerChangeHandoff,
            knownSpeakerNames: knownSpeakerNames,
            postTakeEvidence: postTakeEvidence,
            tags: tags,
            expectsAbstention: expectsAbstention,
            contextSummary: contextSummary,
            optionASource: modelFirst ? .onDeviceModel : .authoredBaseline,
            optionBSource: modelFirst ? .authoredBaseline : .onDeviceModel,
            optionASuggestion: modelFirst ? model : authored,
            optionBSuggestion: modelFirst ? authored : model,
            modelLatencyMilliseconds: latencyMS,
            modelFellBackToAuthored: model.origin == .authoredFallback,
            modelFallbackSummary: model.fallbackReason?.userSummary,
            rating: nil
        )
    }

    private static func postTakeContextSummary(for evalCase: PostTakeEvaluationCase) -> String {
        var parts: [String] = [
            "Status: \(evalCase.attemptStatus.displayName)",
            "Mode: \(evalCase.practiceMode.displayName)",
            "Duration: \(String(format: "%.1fs", evalCase.playableDuration))",
            "Reveals: \(evalCase.revealCount)"
        ]
        if let wpm = evalCase.estimatedWordsPerMinute {
            parts.append("Est. Pace: \(Int(wpm.rounded())) WPM")
        }
        if !evalCase.markers.isEmpty {
            parts.append("Markers: \(evalCase.markers.count)")
        }
        if !evalCase.observations.isEmpty {
            parts.append("Observations: \(evalCase.observations.count)")
        }
        if !evalCase.ambiguousNotes.isEmpty {
            parts.append("Ambiguity notes: \(evalCase.ambiguousNotes.count)")
        }
        return parts.joined(separator: " · ")
    }
}
