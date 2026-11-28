import Foundation

struct PracticeTarget: Hashable, Sendable {
    let presentationID: UUID
    let sectionID: UUID
    let talkRevisionID: UUID?
    let sectionRevisionID: UUID?
    let initialMode: PracticeMode
    let initialSlideIndex: Int
    let hasUnsavedEditorDraft: Bool
    let retryToken: UUID

    init(
        presentationID: UUID,
        sectionID: UUID,
        talkRevisionID: UUID? = nil,
        sectionRevisionID: UUID? = nil,
        initialMode: PracticeMode = .cueWords,
        initialSlideIndex: Int = 0,
        hasUnsavedEditorDraft: Bool = false,
        retryToken: UUID = UUID()
    ) {
        self.presentationID = presentationID
        self.sectionID = sectionID
        self.talkRevisionID = talkRevisionID
        self.sectionRevisionID = sectionRevisionID
        self.initialMode = initialMode
        self.initialSlideIndex = max(0, initialSlideIndex)
        self.hasUnsavedEditorDraft = hasUnsavedEditorDraft
        self.retryToken = retryToken
    }
}
