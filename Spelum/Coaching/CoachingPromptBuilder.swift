import Foundation

nonisolated enum CoachingPromptBuilder {
    static let maxScriptContextCharacters = 900
    static let maxHandoffContextCharacters = 220
    static let maxPassageDisplayCharacters = 180
    static let maxCueWordsCount = 6
    static let maxMarkersListed = 3

    static func buildPreparationPrompt(
        for request: PreparationCoachingRequest,
        optionSet: PreparationCoachingOptionSet
    ) -> String {
        var lines: [String] = [
            "Task: Pre-practice bounded selection (\(request.promptVersion))",
            "Section: \(request.sectionTitle) | Purpose: \(request.purpose.displayName)",
            speakerMetadataLine(
                isSpeakerChangeHandoff: request.isSpeakerChangeHandoff,
                isMultiSpeakerTalk: request.isMultiSpeakerTalk,
                knownSpeakerNames: request.knownSpeakerNames
            ),
            markedPhraseLine(request.exactPhrase),
            handoffCueLine(request.handoffCueText)
        ]
        if !request.cueWords.isEmpty {
            let boundedCues = request.cueWords.prefix(maxCueWordsCount).joined(separator: ", ")
            lines.append("Cue words: \(boundedCues)")
        }
        lines.append("Abstention required: \(optionSet.mustAbstain ? "yes" : "no")")
        lines.append("Script context:\n\(boundedScriptContext(scriptText: request.scriptText, anchors: [request.exactPhrase]))")

        appendAbstentionOptions(optionSet.abstentionOptions, to: &lines)
        if !optionSet.mustAbstain {
            appendPreparationMenus(optionSet: optionSet, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    static func buildPostTakePrompt(
        for request: PostTakeCoachingRequest,
        optionSet: PostTakeCoachingOptionSet
    ) -> String {
        var lines: [String] = [
            "Task: Post-take bounded selection (\(request.promptVersion))",
            "Section: \(request.sectionTitle) | Purpose: \(request.purpose.displayName)",
            speakerMetadataLine(
                isSpeakerChangeHandoff: request.isSpeakerChangeHandoff,
                isMultiSpeakerTalk: request.isMultiSpeakerTalk,
                knownSpeakerNames: request.knownSpeakerNames
            ),
            markedPhraseLine(request.exactPhrase),
            handoffCueLine(request.handoffCueText),
            takeFactsLine(for: request),
            measurementsLine(for: request),
            markersLine(for: request),
            ambiguityLine(for: request),
            "Abstention required: \(optionSet.mustAbstain ? "yes" : "no")"
        ]

        let anchors = postTakeAnchorSnippets(for: request)
        lines.append("Script context:\n\(boundedScriptContext(scriptText: request.scriptText, anchors: anchors))")

        appendAbstentionOptions(optionSet.abstentionOptions, to: &lines)
        if !optionSet.mustAbstain {
            appendPostTakeMenus(optionSet: optionSet, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    static func boundedScriptContext(
        scriptText: String,
        anchors: [String?] = [],
        maxCharacters: Int = maxScriptContextCharacters
    ) -> String {
        let normalized = normalizeWhitespace(scriptText)
        guard normalized.count > maxCharacters, maxCharacters >= 120 else {
            return normalized
        }

        let headLimit = maxCharacters / 3
        let tailLimit = maxCharacters / 4
        let head = prefixAtWordBoundary(normalized, maxLength: headLimit)
        let tail = suffixAtWordBoundary(normalized, maxLength: tailLimit)

        let middleBudget = max(80, maxCharacters - head.count - tail.count - 26)
        let middleWindow = anchorWindow(
            in: normalized,
            anchors: anchors,
            headCount: head.count,
            tailCount: tail.count,
            maxLength: middleBudget
        )

        if let middleWindow, !middleWindow.isEmpty {
            return "\(head) […] \(middleWindow) […] \(tail) [truncated]"
        }
        return "\(head) […] \(tail) [truncated]"
    }

    static func boundedHandoffCue(
        _ handoffCueText: String?,
        maxCharacters: Int = maxHandoffContextCharacters
    ) -> String? {
        guard let raw = handoffCueText else { return nil }
        let normalized = normalizeWhitespace(raw)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maxCharacters, maxCharacters >= 40 else {
            return normalized
        }
        let suffix = suffixAtWordBoundary(normalized, maxLength: maxCharacters - 6)
        return "[…] \(suffix)"
    }
}

private extension CoachingPromptBuilder {
    static func speakerMetadataLine(
        isSpeakerChangeHandoff: Bool,
        isMultiSpeakerTalk: Bool,
        knownSpeakerNames: [String]
    ) -> String {
        let names = knownSpeakerNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let namesPart = names.isEmpty ? "unspecified" : names.joined(separator: ", ")
        return "Handoff/Speakers: speakerChange=\(isSpeakerChangeHandoff ? "yes" : "no") | " +
            "multiSpeaker=\(isMultiSpeakerTalk ? "yes" : "no") | speakers=\(namesPart)"
    }

    static func markedPhraseLine(_ exactPhrase: String?) -> String {
        guard let trimmed = exactPhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return "Marked exact phrase: none"
        }
        return "Marked exact phrase: \"\(truncateInline(trimmed, maxLength: maxPassageDisplayCharacters))\""
    }

    static func handoffCueLine(_ handoffCueText: String?) -> String {
        guard let bounded = boundedHandoffCue(handoffCueText) else {
            return "Handoff cue: none"
        }
        return "Handoff cue: \"\(bounded)\""
    }

    static func takeFactsLine(for request: PostTakeCoachingRequest) -> String {
        let duration = String(format: "%.1fs", request.playableDuration)
        return "Take: status=\(request.attemptStatus.rawValue) | mode=\(request.practiceMode.rawValue) | " +
            "duration=\(duration) | reveals=\(request.revealCount)"
    }

    static func measurementsLine(for request: PostTakeCoachingRequest) -> String {
        guard let analysis = request.timingAnalysis else {
            return "Measurements: outcome=unavailable | words=0 | reliableWPM=none"
        }
        let wpmText: String
        if let reliable = PostTakeCoachingOptionSet.reliableEstimatedWPM(for: request) {
            wpmText = "\(Int(reliable.rounded()))"
        } else if analysis.estimatedWordsPerMinute != nil,
                  PostTakeCoachingOptionSet.hasBlockingAmbiguity(in: request) {
            wpmText = "withheld(timing-ambiguity)"
        } else {
            wpmText = "none"
        }
        return "Measurements: outcome=\(analysis.outcome.rawValue) | " +
            "words=\(analysis.recognizedWordCount) | reliableWPM=\(wpmText)"
    }

    static func markersLine(for request: PostTakeCoachingRequest) -> String {
        guard !request.markers.isEmpty else { return "Markers: none" }
        let items = request.markers.prefix(maxMarkersListed).enumerated().map { idx, marker in
            let clock = RehearsalTimeFormatter.clockString(for: marker.timestamp)
            return "fact.marker.\(idx)@\(clock)(\(truncateInline(marker.label, maxLength: 60)))"
        }
        return "Markers: \(items.joined(separator: "; "))"
    }

    static func ambiguityLine(for request: PostTakeCoachingRequest) -> String {
        let notes = request.timingAnalysis?.ambiguousNotes ?? []
        guard !notes.isEmpty else { return "Ambiguity: none" }
        let items = notes.map { "\($0.reason.rawValue) (\($0.reason.neutralDisplayLabel))" }
        return "Ambiguity: \(items.joined(separator: "; "))"
    }

    static func postTakeAnchorSnippets(for request: PostTakeCoachingRequest) -> [String?] {
        var anchors: [String?] = [request.exactPhrase]
        for obs in request.timingAnalysis?.observations ?? [] {
            anchors.append(obs.matchedPhrase)
            anchors.append(obs.followingContext)
        }
        return anchors
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

    static func appendPreparationMenus(
        optionSet: PreparationCoachingOptionSet,
        to lines: inout [String]
    ) {
        let techniquesByID = Dictionary(uniqueKeysWithValues: optionSet.candidateTechniques.map { ($0.id, $0) })

        lines.append("Allowed Candidate Techniques:")
        for technique in optionSet.candidateTechniques {
            lines.append(
                "- \(technique.id) | \(technique.title) | " +
                "category=\(technique.category.rawValue) | handoff=\(technique.appliesToHandoff ? "yes" : "no")"
            )
        }

        lines.append("Allowed Verbatim Passages:")
        for passage in optionSet.passageOptions {
            let preview = truncateInline(passage.phrase, maxLength: maxPassageDisplayCharacters)
            lines.append(
                "- \(passage.id) | role=\(passage.role.rawValue) | " +
                "handoff=\(passage.fromHandoff ? "yes" : "no") | \"\(preview)\""
            )
        }

        lines.append("Allowed Action Options:")
        for action in optionSet.actionOptions {
            let technique = techniquesByID[action.techniqueID]
            let validPassages = optionSet.passageOptions
                .filter { passage in
                    if passage.fromHandoff {
                        return action.allowsHandoffPassage && (technique?.appliesToHandoff == true)
                    }
                    return action.allowsScriptPassage
                }
                .map(\.id)
                .sorted()
            guard !validPassages.isEmpty else { continue }
            lines.append(
                "- \(action.id) | technique=\(action.techniqueID) | " +
                "passages=[\(validPassages.joined(separator: ","))] | \(action.summaryForModel)"
            )
        }
    }

    static func appendPostTakeMenus(
        optionSet: PostTakeCoachingOptionSet,
        to lines: inout [String]
    ) {
        let reachablePassageIDs = optionSet.evidenceOptions.reduce(into: Set<String>()) { result, item in
            result.formUnion(item.compatiblePassageIDs)
        }

        lines.append("Allowed Evidence Options:")
        for item in optionSet.evidenceOptions {
            let passages = item.compatiblePassageIDs.sorted().joined(separator: ",")
            let techniques = item.compatibleTechniqueIDs.sorted().joined(separator: ",")
            lines.append(
                "- \(item.id) | \(item.summaryForModel) | " +
                "passages=[\(passages)] | techniques=[\(techniques)]"
            )
        }

        lines.append("Allowed Verbatim Passages:")
        for passage in optionSet.passageOptions where reachablePassageIDs.contains(passage.id) {
            let preview = truncateInline(passage.phrase, maxLength: maxPassageDisplayCharacters)
            lines.append("- \(passage.id) | role=\(passage.role.rawValue) | \"\(preview)\"")
        }

        lines.append("Allowed Candidate Techniques:")
        for technique in optionSet.candidateTechniques {
            lines.append(
                "- \(technique.id) | \(technique.title) | " +
                "category=\(technique.category.rawValue) | \(technique.postTakeFocus)"
            )
        }

        lines.append("Allowed Action Options:")
        for action in optionSet.actionOptions {
            let evList = action.compatibleEvidenceIDs.sorted().joined(separator: ",")
            let techList = action.compatibleTechniqueIDs.sorted().joined(separator: ",")
            lines.append(
                "- \(action.id) | evidence=[\(evList)] | " +
                "techniques=[\(techList)] | \(action.summaryForModel)"
            )
        }
    }

    static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func truncateInline(_ text: String, maxLength: Int) -> String {
        let normalized = normalizeWhitespace(text)
        guard normalized.count > maxLength, maxLength >= 16 else { return normalized }
        return "\(prefixAtWordBoundary(normalized, maxLength: maxLength - 1))…"
    }

    static func prefixAtWordBoundary(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let endIdx = text.index(text.startIndex, offsetBy: maxLength)
        let slice = text[..<endIdx]
        if let spaceIdx = slice.lastIndex(of: " "), spaceIdx > text.startIndex {
            return String(slice[..<spaceIdx])
        }
        return String(slice)
    }

    static func suffixAtWordBoundary(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let startIdx = text.index(text.endIndex, offsetBy: -maxLength)
        let slice = text[startIdx...]
        if let spaceIdx = slice.firstIndex(of: " "), spaceIdx < text.index(before: text.endIndex) {
            return String(slice[text.index(after: spaceIdx)...])
        }
        return String(slice)
    }

    static func anchorWindow(
        in text: String,
        anchors: [String?],
        headCount: Int,
        tailCount: Int,
        maxLength: Int
    ) -> String? {
        let middleStart = text.index(text.startIndex, offsetBy: min(headCount, text.count))
        let middleEnd = text.index(text.endIndex, offsetBy: -min(tailCount, text.count))
        guard middleStart < middleEnd else { return nil }

        for rawAnchor in anchors {
            guard let rawAnchor else { continue }
            let anchor = normalizeWhitespace(rawAnchor)
            guard !anchor.isEmpty,
                  let found = text.range(of: anchor, range: middleStart..<middleEnd) else {
                continue
            }
            let anchorLength = text.distance(from: found.lowerBound, to: found.upperBound)
            if anchorLength >= maxLength {
                return prefixAtWordBoundary(anchor, maxLength: maxLength)
            }
            let pad = (maxLength - anchorLength) / 2
            let winStart = text.index(found.lowerBound, offsetBy: -pad, limitedBy: middleStart) ?? middleStart
            let winEnd = text.index(found.upperBound, offsetBy: pad, limitedBy: middleEnd) ?? middleEnd
            return String(text[winStart..<winEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
