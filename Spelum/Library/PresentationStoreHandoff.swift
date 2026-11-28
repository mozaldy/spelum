import Foundation
import SwiftData

extension PresentationStore {
    func handoffContext(
        forSectionID sectionID: UUID,
        in presentation: PresentationRecord
    ) -> HandoffContext? {
        guard let revision = currentTalkRevision(for: presentation) else {
            return nil
        }
        return handoffContext(forSectionID: sectionID, in: revision)
    }

    func handoffContext(
        forSectionID sectionID: UUID,
        in talkRevision: TalkRevisionRecord
    ) -> HandoffContext? {
        let sections = orderedSections(in: talkRevision)
        guard let index = sections.firstIndex(where: { $0.sectionID == sectionID }) else {
            return nil
        }

        let current = sections[index]
        let isSingleSpeakerTalk = Set(sections.map(Self.normalizedSpeakerKey)).count <= 1
        let currentOrigin: HandoffTransitionOrigin = index == 0
            ? .opening
            : .fromSection(sections[index - 1].sectionID)
        let rawCustomCue = Self.normalizedOptionalText(current.handoffCueOverride)
        let storedOrigin = resolveHandoffCueOrigin(for: current, in: talkRevision)
        let customCue = (storedOrigin == currentOrigin) ? rawCustomCue : nil

        guard index > 0 else {
            return HandoffContext(
                sectionID: current.sectionID,
                sectionIndex: index,
                precedingSectionID: nil,
                precedingSectionTitle: nil,
                precedingSpeaker: nil,
                precedingSpeakerRole: nil,
                derivedFinalLine: nil,
                customCue: customCue,
                effectiveCueText: customCue,
                isCustomCue: customCue != nil,
                isFirstSection: true,
                isSpeakerChange: false,
                isSingleSpeakerTalk: isSingleSpeakerTalk
            )
        }

        let preceding = sections[index - 1]
        let derivedLine = AnnotatedScriptParser.lastSpokenLine(in: preceding.text)
        let isSpeakerChange = Self.normalizedSpeakerKey(preceding) != Self.normalizedSpeakerKey(current)

        return HandoffContext(
            sectionID: current.sectionID,
            sectionIndex: index,
            precedingSectionID: preceding.sectionID,
            precedingSectionTitle: preceding.title,
            precedingSpeaker: preceding.speaker,
            precedingSpeakerRole: preceding.speakerRole,
            derivedFinalLine: derivedLine,
            customCue: customCue,
            effectiveCueText: customCue ?? derivedLine,
            isCustomCue: customCue != nil,
            isFirstSection: false,
            isSpeakerChange: isSpeakerChange,
            isSingleSpeakerTalk: isSingleSpeakerTalk
        )
    }

    func resolveHandoffCueOrigin(
        for section: SectionRevisionRecord,
        in talkRevision: TalkRevisionRecord
    ) -> HandoffTransitionOrigin? {
        guard Self.normalizedOptionalText(section.handoffCueOverride) != nil else {
            return nil
        }
        if section.handoffCueIsOpening == true {
            return .opening
        }
        if let sourceID = section.handoffCueSourceSectionID {
            return .fromSection(sourceID)
        }
        // Legacy record fallback: infer originating transition from earliest revision containing this record.
        if let revisions = talkRevision.presentation?.talkRevisions {
            let chronological = revisions.sorted { $0.revisionNumber < $1.revisionNumber }
            for revision in chronological {
                let ordered = orderedSections(in: revision)
                if let originIndex = ordered.firstIndex(where: { $0.revisionID == section.revisionID }) {
                    return originIndex == 0 ? .opening : .fromSection(ordered[originIndex - 1].sectionID)
                }
            }
        }
        let currentOrdered = orderedSections(in: talkRevision)
        if let currentIndex = currentOrdered.firstIndex(where: { $0.revisionID == section.revisionID }) {
            return currentIndex == 0 ? .opening : .fromSection(currentOrdered[currentIndex - 1].sectionID)
        }
        return nil
    }

    // swiftlint:disable:next function_parameter_count
    func rebindFollowerHandoffIfNeeded(
        in updatedSections: inout [SectionRevisionRecord],
        followerIndex: Int,
        oldPredecessorID: UUID,
        newPredecessorID: UUID,
        previousRevision: TalkRevisionRecord,
        presentation: PresentationRecord,
        timestamp: Date
    ) {
        guard updatedSections.indices.contains(followerIndex) else { return }
        let follower = updatedSections[followerIndex]
        guard let customCue = Self.normalizedOptionalText(follower.handoffCueOverride),
              resolveHandoffCueOrigin(for: follower, in: previousRevision) == .fromSection(oldPredecessorID) else {
            return
        }

        let rebound = SectionRevisionRecord(
            sectionID: follower.sectionID,
            title: follower.title,
            text: follower.text,
            speaker: follower.speaker,
            speakerRole: follower.speakerRole,
            purpose: follower.purpose,
            cueWords: follower.cueWords,
            exactPhrase: follower.exactPhrase,
            handoffCueOverride: customCue,
            handoffCueSourceSectionID: newPredecessorID,
            handoffCueIsOpening: false,
            slideReferences: follower.slideReferences,
            createdAt: timestamp,
            presentation: presentation
        )
        presentation.sectionRevisions.append(rebound)
        modelContext.insert(rebound)
        updatedSections[followerIndex] = rebound
    }

    func reconcileHandoffOverrides(
        for newOrder: [SectionRevisionRecord],
        previousRevision: TalkRevisionRecord,
        presentation: PresentationRecord,
        timestamp: Date
    ) -> [SectionRevisionRecord] {
        newOrder.enumerated().map { index, section in
            guard Self.normalizedOptionalText(section.handoffCueOverride) != nil else {
                return section
            }
            let newOrigin: HandoffTransitionOrigin = index == 0
                ? .opening
                : .fromSection(newOrder[index - 1].sectionID)
            let storedOrigin = resolveHandoffCueOrigin(for: section, in: previousRevision)
            guard storedOrigin != newOrigin else {
                return section
            }

            let cleared = SectionRevisionRecord(
                sectionID: section.sectionID,
                title: section.title,
                text: section.text,
                speaker: section.speaker,
                speakerRole: section.speakerRole,
                purpose: section.purpose,
                cueWords: section.cueWords,
                exactPhrase: section.exactPhrase,
                handoffCueOverride: nil,
                handoffCueSourceSectionID: nil,
                handoffCueIsOpening: nil,
                slideReferences: section.slideReferences,
                createdAt: timestamp,
                presentation: presentation
            )
            presentation.sectionRevisions.append(cleared)
            modelContext.insert(cleared)
            return cleared
        }
    }
}
