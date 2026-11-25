import Foundation
import Observation

@Observable
@MainActor
final class PreparationCoachCoordinator {
    let coachService: SectionCoachService
    private let coachingStore: CoachingStore?

    private(set) var activeRequest: PreparationCoachingRequest?
    private(set) var currentCue: CoachingSuggestion?
    private(set) var modelAvailability: CoachingModelAvailability
    private(set) var isGenerating = false
    private(set) var statusNote: String?

    private var activeGenerationToken = UUID()
    private var inFlightSignature: String?
    private var activeTask: Task<Void, Never>?

    init(
        coachService: SectionCoachService = SectionCoachService(),
        coachingStore: CoachingStore? = nil
    ) {
        self.coachService = coachService
        self.coachingStore = coachingStore
        self.modelAvailability = coachService.modelAvailability()
    }

    func load(request: PreparationCoachingRequest) {
        modelAvailability = coachService.modelAvailability()
        let newSignature = requestSignature(for: request)
        if let existingRequest = activeRequest,
           requestSignature(for: existingRequest) == newSignature,
           currentCue != nil {
            return
        }

        cancelActiveGeneration()
        activeRequest = request
        statusNote = nil

        if let cached = try? coachingStore?.fetchCachedPreparationCue(for: request) {
            currentCue = cached
            statusNote = cached.fallbackReason?.userSummary
            return
        }

        let authored = TechniqueLibrary.authoredPreparationSuggestion(
            for: request,
            origin: .authoredBaseline
        )
        currentCue = authored
        try? coachingStore?.savePreparationCue(authored, for: request)
    }

    func selectTechnique(id: String?) {
        guard let current = activeRequest else { return }
        let updated = PreparationCoachingRequest(
            presentationID: current.presentationID,
            sectionRevisionID: current.sectionRevisionID,
            talkRevisionID: current.talkRevisionID,
            sectionTitle: current.sectionTitle,
            scriptText: current.scriptText,
            exactPhrase: current.exactPhrase,
            cueWords: current.cueWords,
            purpose: current.purpose,
            handoffCueText: current.handoffCueText,
            isSpeakerChangeHandoff: current.isSpeakerChangeHandoff,
            knownSpeakerNames: current.knownSpeakerNames,
            selectedTechniqueID: id,
            candidateTechniques: current.candidateTechniques,
            promptVersion: current.promptVersion
        )
        load(request: updated)
    }

    func requestOnDeviceSuggestion() {
        guard let request = activeRequest else { return }
        let signature = requestSignature(for: request)
        if isGenerating, inFlightSignature == signature {
            return
        }

        cancelActiveGeneration()
        let token = UUID()
        activeGenerationToken = token
        inFlightSignature = signature
        isGenerating = true
        statusNote = nil
        modelAvailability = coachService.modelAvailability()

        let service = coachService
        activeTask = Task { [weak self] in
            let generated = await service.generatePreparationCue(
                request: request,
                mode: .onDeviceModel
            )
            guard let self else { return }
            self.finishGeneration(
                generated,
                for: request,
                signature: signature,
                token: token
            )
        }
    }

    func saveEditedAction(_ text: String) throws {
        guard let request = activeRequest, var cue = currentCue else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelActiveGeneration()
        cue.userEditedAction = trimmed
        cue.isDismissed = false
        cue.updatedAt = Date()
        currentCue = cue
        try coachingStore?.savePreparationCue(cue, for: request)
    }

    func dismissCurrentCue() throws {
        guard let request = activeRequest, var cue = currentCue else { return }
        cancelActiveGeneration()
        cue.isDismissed = true
        cue.updatedAt = Date()
        currentCue = cue
        try coachingStore?.savePreparationCue(cue, for: request)
    }

    func restoreDismissedCue() throws {
        guard let request = activeRequest, var cue = currentCue else { return }
        cue.isDismissed = false
        cue.updatedAt = Date()
        currentCue = cue
        try coachingStore?.savePreparationCue(cue, for: request)
    }

    func resetToAuthoredCue() throws {
        guard let request = activeRequest else { return }
        cancelActiveGeneration()
        let authored = TechniqueLibrary.authoredPreparationSuggestion(
            for: request,
            origin: .authoredBaseline
        )
        currentCue = authored
        statusNote = nil
        try coachingStore?.savePreparationCue(authored, for: request)
    }

    func handleViewDisappear() {
        cancelActiveGeneration()
    }

    func waitForActiveGeneration() async {
        await activeTask?.value
    }

    private func finishGeneration(
        _ generated: CoachingSuggestion,
        for request: PreparationCoachingRequest,
        signature: String,
        token: UUID
    ) {
        guard activeGenerationToken == token,
              let boundRequest = activeRequest,
              requestSignature(for: boundRequest) == signature else {
            return
        }
        isGenerating = false
        inFlightSignature = nil
        activeTask = nil
        currentCue = generated
        statusNote = generated.fallbackReason?.userSummary
        try? coachingStore?.savePreparationCue(generated, for: request)
    }

    private func cancelActiveGeneration() {
        activeTask?.cancel()
        activeTask = nil
        activeGenerationToken = UUID()
        inFlightSignature = nil
        isGenerating = false
    }

    private func requestSignature(for request: PreparationCoachingRequest) -> String {
        "\(request.cacheKey)|\(request.contentFingerprint)"
    }
}

@Observable
@MainActor
final class PostTakeCoachCoordinator {
    struct DeletionRecoveryToken {
        fileprivate let attemptID: UUID
        fileprivate let previousCue: CoachingSuggestion?
        fileprivate let previousRequest: PostTakeCoachingRequest?
    }

    let coachService: SectionCoachService
    private let coachingStore: CoachingStore?

    private(set) var activeRequest: PostTakeCoachingRequest?
    private(set) var currentCue: CoachingSuggestion?
    private(set) var modelAvailability: CoachingModelAvailability
    private(set) var isGenerating = false
    private(set) var statusNote: String?

    private var activeGenerationToken = UUID()
    private var inFlightSignature: String?
    private var activeTask: Task<Void, Never>?

    init(
        coachService: SectionCoachService = SectionCoachService(),
        coachingStore: CoachingStore? = nil
    ) {
        self.coachService = coachService
        self.coachingStore = coachingStore
        self.modelAvailability = coachService.modelAvailability()
    }

    func load(request: PostTakeCoachingRequest) {
        modelAvailability = coachService.modelAvailability()
        let newSignature = requestSignature(for: request)
        if let existing = activeRequest,
           requestSignature(for: existing) == newSignature,
           currentCue != nil {
            return
        }

        cancelActiveGeneration()
        activeRequest = request
        statusNote = nil

        if let cached = try? coachingStore?.fetchCachedPostTakeCue(for: request) {
            currentCue = cached
            statusNote = cached.fallbackReason?.userSummary
            return
        }

        let authored = TechniqueLibrary.authoredPostTakeSuggestion(
            for: request,
            origin: .authoredBaseline
        )
        currentCue = authored
        try? coachingStore?.savePostTakeCue(authored, for: request)
    }

    func requestOnDeviceSuggestion(attemptStore: AttemptStore? = nil) {
        guard let request = activeRequest else { return }
        let signature = requestSignature(for: request)
        if isGenerating, inFlightSignature == signature {
            return
        }

        cancelActiveGeneration()
        let token = UUID()
        activeGenerationToken = token
        inFlightSignature = signature
        isGenerating = true
        statusNote = nil
        modelAvailability = coachService.modelAvailability()

        let service = coachService
        activeTask = Task { [weak self] in
            let generated = await service.generatePostTakeCue(
                request: request,
                mode: .onDeviceModel
            )
            guard let self else { return }
            self.finishGeneration(
                generated,
                for: request,
                signature: signature,
                token: token,
                attemptStore: attemptStore
            )
        }
    }

    func saveEditedAction(_ text: String) throws {
        guard let request = activeRequest, var cue = currentCue else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelActiveGeneration()
        cue.userEditedAction = trimmed
        cue.isDismissed = false
        cue.updatedAt = Date()
        currentCue = cue
        try coachingStore?.savePostTakeCue(cue, for: request)
    }

    func dismissCurrentCue() throws {
        guard let request = activeRequest, var cue = currentCue else { return }
        cancelActiveGeneration()
        cue.isDismissed = true
        cue.updatedAt = Date()
        currentCue = cue
        try coachingStore?.savePostTakeCue(cue, for: request)
    }

    func restoreDismissedCue() throws {
        guard let request = activeRequest, var cue = currentCue else { return }
        cue.isDismissed = false
        cue.updatedAt = Date()
        currentCue = cue
        try coachingStore?.savePostTakeCue(cue, for: request)
    }

    func resetToAuthoredCue() throws {
        guard let request = activeRequest else { return }
        cancelActiveGeneration()
        let authored = TechniqueLibrary.authoredPostTakeSuggestion(
            for: request,
            origin: .authoredBaseline
        )
        currentCue = authored
        statusNote = nil
        try coachingStore?.savePostTakeCue(authored, for: request)
    }

    func prepareForDeletion(attemptID: UUID) -> DeletionRecoveryToken {
        let token = DeletionRecoveryToken(
            attemptID: attemptID,
            previousCue: currentCue,
            previousRequest: activeRequest
        )
        cancelActiveGeneration()
        activeRequest = nil
        currentCue = nil
        return token
    }

    func restoreAfterFailedDeletion(_ token: DeletionRecoveryToken) {
        activeRequest = token.previousRequest
        currentCue = token.previousCue
    }

    func handleViewDisappear() {
        cancelActiveGeneration()
    }

    func waitForActiveGeneration() async {
        await activeTask?.value
    }

    private func finishGeneration(
        _ generated: CoachingSuggestion,
        for request: PostTakeCoachingRequest,
        signature: String,
        token: UUID,
        attemptStore: AttemptStore?
    ) {
        guard activeGenerationToken == token,
              let boundRequest = activeRequest,
              requestSignature(for: boundRequest) == signature else {
            return
        }
        if let attemptStore {
            guard (try? attemptStore.attempt(withID: request.attemptID)) != nil else {
                isGenerating = false
                inFlightSignature = nil
                activeTask = nil
                return
            }
        }
        isGenerating = false
        inFlightSignature = nil
        activeTask = nil
        currentCue = generated
        statusNote = generated.fallbackReason?.userSummary
        try? coachingStore?.savePostTakeCue(generated, for: request)
    }

    private func cancelActiveGeneration() {
        activeTask?.cancel()
        activeTask = nil
        activeGenerationToken = UUID()
        inFlightSignature = nil
        isGenerating = false
    }

    private func requestSignature(for request: PostTakeCoachingRequest) -> String {
        request.cacheKey
    }
}
