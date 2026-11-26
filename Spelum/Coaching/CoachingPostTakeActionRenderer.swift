import Foundation

extension PostTakeCoachingOptionSet {
    func renderAction(
        template: PostTakeActionTemplate,
        evidence: CoachingEvidenceOption,
        technique: CoachingTechnique
    ) -> String {
        if let timingText = renderTimingAction(template: template, kind: evidence.kind) {
            return timingText
        }
        if let factText = renderFactAction(template: template, kind: evidence.kind, technique: technique) {
            return factText
        }
        return technique.postTakeFocus
    }

    func renderRationale(
        evidence: CoachingEvidenceOption,
        technique: CoachingTechnique,
        request: PostTakeCoachingRequest
    ) -> String {
        switch evidence.kind {
        case .phraseGap:
            let hasMultiSpeaker = request.isSpeakerChangeHandoff
                || request.isMultiSpeakerTalk
                || (request.timingAnalysis?.ambiguousNotes.contains { $0.reason == .multiSpeakerBoundary } == true)
            let hasDemoSilence = PostTakeCoachingOptionSet.hasStageDirectionSilence(in: request)
            if hasDemoSilence && hasMultiSpeaker {
                return "Grounded in the bounded estimated gap around a scripted demo pause " +
                    "without attributing the pause to any speaker."
            }
            if hasDemoSilence {
                return "Grounded in the bounded estimated gap around a scripted demo pause — " +
                    "silence during a live step can be intentional."
            }
            if hasMultiSpeaker {
                return "Grounded in the bounded estimated gap without attributing the pause to any speaker."
            }
            return "Grounded directly in the bounded estimated phrase gap from on-device speech timing."
        case .fastPace, .slowPace:
            return "Grounded in the estimated speaking pace from validated on-device word timing " +
                "(\(technique.title))."
        case .scriptReveals:
            return "Grounded in the recorded script reveal count as an optional recall check, " +
                "not a performance judgment."
        case .manualMarker:
            return "Anchored to your manual rehearsal marker so playback opens directly on that moment."
        case .alignedPhrase:
            return "Anchored to the aligned passage timestamp so you can hear the exact moment on replay."
        }
    }

    static func buildActionOptions(
        for request: PostTakeCoachingRequest,
        evidenceOptions: [CoachingEvidenceOption]
    ) -> [CoachingPostTakeActionOption] {
        let context = ActionBuilderContext(techniques: request.candidateTechniques)
        var table: [PostTakeActionTemplate: CoachingPostTakeActionOption] = [:]
        for item in evidenceOptions {
            for spec in actionSpecs(for: item.kind, context: context) {
                registerAction(spec, evidenceID: item.id, into: &table)
            }
        }
        return table.values.sorted { $0.id < $1.id }
    }
}

private extension PostTakeCoachingOptionSet {
    func renderTimingAction(
        template: PostTakeActionTemplate,
        kind: CoachingEvidenceKind
    ) -> String? {
        switch (template, kind) {
        case (.gapHoldBeat, .phraseGap(_, let gap, _, _)):
            let formatted = String(format: "%.1f", gap)
            return "Replay around the estimated \(formatted)s gap and test holding a deliberate, " +
                "calm beat so the highlighted line lands cleanly."
        case (.gapTightenTransition, .phraseGap(_, let gap, _, _)):
            let formatted = String(format: "%.1f", gap)
            return "Replay around the estimated \(formatted)s gap and test tightening that beat " +
                "slightly so momentum carries into the highlighted line."
        case (.gapSyncDemoWait, .phraseGap(_, let gap, _, _)):
            let formatted = String(format: "%.1f", gap)
            return "Replay around the estimated \(formatted)s silent beat to check whether the wait " +
                "feels intentional while the on-screen step settles."
        case (.paceBreathBeforePayoff, .fastPace(let wpm, _)):
            return "Pace was estimated near \(wpm) WPM; replay the highlighted line and try adding " +
                "one clear breath right before it."
        case (.paceSeparateSetupBeats, .fastPace(let wpm, _)):
            return "Pace was estimated near \(wpm) WPM; replay the setup into the highlighted line " +
                "and give each beat a tiny pause so the payoff stands apart."
        case (.paceSlowFinalLanding, .fastPace(let wpm, _)):
            return "Pace was estimated near \(wpm) WPM; replay the ending and slow slightly on the " +
                "highlighted closing line so it stops cleanly."
        case (.paceSteadyMomentum, .slowPace(let wpm, _)):
            return "Pace was estimated near \(wpm) WPM; replay the highlighted passage and test " +
                "carrying slightly steadier momentum into the key phrase."
        default:
            return nil
        }
    }

    func renderFactAction(
        template: PostTakeActionTemplate,
        kind: CoachingEvidenceKind,
        technique: CoachingTechnique
    ) -> String? {
        switch (template, kind) {
        case (.revealsAnchorRecall, .scriptReveals(let count, _)):
            let word = count == 1 ? "1 script reveal" : "\(count) script reveals"
            return "You used \(word) during this take; if you want to test recall without glancing, " +
                "replay the highlighted line once and try focusing on that single anchor."
        case (.revealsBridgeTransition, .scriptReveals(let count, _)):
            let word = count == 1 ? "1 script reveal" : "\(count) script reveals"
            return "You used \(word) during this take; if helpful, rehearse stepping into the highlighted " +
                "line from the transition before your next pass."
        case (.markerRehearseAfterMark, .manualMarker(let timestamp, _, _)):
            let clock = RehearsalTimeFormatter.clockString(for: timestamp)
            return "Jump to your manual marker at \(clock) in playback and try one clean retry " +
                "focused on the highlighted line after it."
        case (.markerCompareLeadIn, .manualMarker(let timestamp, _, _)):
            let clock = RehearsalTimeFormatter.clockString(for: timestamp)
            return "Replay from your manual marker at \(clock) to listen to the lead-in and decide " +
                "whether holding or trimming the beat sounds cleaner."
        case (.alignedVerifyPayoff, .alignedPhrase(_, _, let startTime, _)):
            let clock = RehearsalTimeFormatter.clockString(for: startTime)
            return "Replay the aligned passage at \(clock) and listen for whether the highlighted " +
                "line stands clearly apart from the setup before it."
        case (.alignedTechniqueFocus, _):
            return technique.postTakeFocus
        default:
            return nil
        }
    }

    struct ActionBuilderContext {
        let allTechIDs: Set<String>
        let demoTechIDs: Set<String>
        let closeTechIDs: Set<String>

        init(techniques: [CoachingTechnique]) {
            self.allTechIDs = Set(techniques.map(\.id))
            self.demoTechIDs = Set(techniques.filter { $0.category == .demo }.map(\.id))
            self.closeTechIDs = Set(techniques.filter { $0.category == .close }.map(\.id))
        }
    }

    struct ActionSpec {
        let template: PostTakeActionTemplate
        let techIDs: Set<String>
        let summary: String
    }

    static func registerAction(
        _ spec: ActionSpec,
        evidenceID: String,
        into table: inout [PostTakeActionTemplate: CoachingPostTakeActionOption]
    ) {
        guard !spec.techIDs.isEmpty else { return }
        if let existing = table[spec.template] {
            table[spec.template] = CoachingPostTakeActionOption(
                id: existing.id,
                template: spec.template,
                compatibleEvidenceIDs: existing.compatibleEvidenceIDs.union([evidenceID]),
                compatibleTechniqueIDs: existing.compatibleTechniqueIDs.union(spec.techIDs),
                summaryForModel: existing.summaryForModel
            )
        } else {
            table[spec.template] = CoachingPostTakeActionOption(
                id: spec.template.rawValue,
                template: spec.template,
                compatibleEvidenceIDs: [evidenceID],
                compatibleTechniqueIDs: spec.techIDs,
                summaryForModel: spec.summary
            )
        }
    }

    static func actionSpecs(
        for kind: CoachingEvidenceKind,
        context: ActionBuilderContext
    ) -> [ActionSpec] {
        switch kind {
        case .phraseGap, .fastPace, .slowPace:
            return timingSpecs(for: kind, context: context)
        case .scriptReveals, .manualMarker, .alignedPhrase:
            return rehearsalFactSpecs(for: kind, context: context)
        }
    }

    static func timingSpecs(
        for kind: CoachingEvidenceKind,
        context: ActionBuilderContext
    ) -> [ActionSpec] {
        switch kind {
        case .phraseGap:
            var specs = [
                ActionSpec(
                    template: .gapHoldBeat,
                    techIDs: context.allTechIDs,
                    summary: "Replay the bounded gap and test holding a calm beat before the line"
                ),
                ActionSpec(
                    template: .gapTightenTransition,
                    techIDs: context.allTechIDs,
                    summary: "Replay the bounded gap and test tightening the transition into the line"
                )
            ]
            if !context.demoTechIDs.isEmpty {
                specs.append(
                    ActionSpec(
                        template: .gapSyncDemoWait,
                        techIDs: context.demoTechIDs,
                        summary: "Replay the silent demo beat to verify the wait feels intentional"
                    )
                )
            }
            return specs
        case .fastPace:
            var specs = [
                ActionSpec(
                    template: .paceBreathBeforePayoff,
                    techIDs: context.allTechIDs,
                    summary: "Replay the fast passage and add one clear breath before the key phrase"
                ),
                ActionSpec(
                    template: .paceSeparateSetupBeats,
                    techIDs: context.allTechIDs,
                    summary: "Replay the fast setup and separate each beat before the payoff"
                )
            ]
            if !context.closeTechIDs.isEmpty {
                specs.append(
                    ActionSpec(
                        template: .paceSlowFinalLanding,
                        techIDs: context.closeTechIDs,
                        summary: "Replay the fast close and slow slightly on the final line"
                    )
                )
            }
            return specs
        case .slowPace:
            return [
                ActionSpec(
                    template: .paceSteadyMomentum,
                    techIDs: context.allTechIDs,
                    summary: "Replay the slow passage and test carrying steadier momentum"
                )
            ]
        case .scriptReveals, .manualMarker, .alignedPhrase:
            return []
        }
    }

    static func rehearsalFactSpecs(
        for kind: CoachingEvidenceKind,
        context: ActionBuilderContext
    ) -> [ActionSpec] {
        switch kind {
        case .scriptReveals:
            return [
                ActionSpec(
                    template: .revealsAnchorRecall,
                    techIDs: context.allTechIDs,
                    summary: "Replay the line and retry focusing on a single recall anchor"
                ),
                ActionSpec(
                    template: .revealsBridgeTransition,
                    techIDs: context.allTechIDs,
                    summary: "Rehearse stepping into this line cleanly from the transition"
                )
            ]
        case .manualMarker:
            return [
                ActionSpec(
                    template: .markerRehearseAfterMark,
                    techIDs: context.allTechIDs,
                    summary: "Jump to the manual marker and retry the line immediately after it"
                ),
                ActionSpec(
                    template: .markerCompareLeadIn,
                    techIDs: context.allTechIDs,
                    summary: "Replay from the manual marker to compare lead-in pacing"
                )
            ]
        case .alignedPhrase:
            return [
                ActionSpec(
                    template: .alignedVerifyPayoff,
                    techIDs: context.allTechIDs,
                    summary: "Replay the aligned passage to check if the key line stands apart"
                ),
                ActionSpec(
                    template: .alignedTechniqueFocus,
                    techIDs: context.allTechIDs,
                    summary: "Replay the aligned passage with the technique's listening focus"
                )
            ]
        case .phraseGap, .fastPace, .slowPace:
            return []
        }
    }
}
