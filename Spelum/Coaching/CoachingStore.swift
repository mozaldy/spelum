import Foundation
import SwiftData

@Model
final class CoachingCueRecord {
    var cacheKey: String
    var taskKindRawValue: String
    var presentationID: UUID?
    var sectionRevisionID: UUID
    var attemptID: UUID?
    var techniqueID: String
    var promptVersion: String
    var evidenceVersion: String?
    var contentFingerprint: String?
    var payloadData: Data
    var updatedAt: Date

    init(
        cacheKey: String,
        taskKind: CoachingTaskKind,
        presentationID: UUID?,
        sectionRevisionID: UUID,
        attemptID: UUID?,
        techniqueID: String,
        promptVersion: String,
        evidenceVersion: String?,
        contentFingerprint: String?,
        payloadData: Data,
        updatedAt: Date = Date()
    ) {
        self.cacheKey = cacheKey
        self.taskKindRawValue = taskKind.rawValue
        self.presentationID = presentationID
        self.sectionRevisionID = sectionRevisionID
        self.attemptID = attemptID
        self.techniqueID = techniqueID
        self.promptVersion = promptVersion
        self.evidenceVersion = evidenceVersion
        self.contentFingerprint = contentFingerprint
        self.payloadData = payloadData
        self.updatedAt = updatedAt
    }

    var suggestion: CoachingSuggestion? {
        try? JSONDecoder().decode(CoachingSuggestion.self, from: payloadData)
    }
}

@MainActor
final class CoachingStore {
    let modelContext: ModelContext
    private let saveContext: (ModelContext) throws -> Void

    init(
        modelContext: ModelContext,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.saveContext = saveContext
    }

    func fetchCachedPreparationCue(for request: PreparationCoachingRequest) throws -> CoachingSuggestion? {
        let key = request.cacheKey
        let fingerprint = request.contentFingerprint
        let descriptor = FetchDescriptor<CoachingCueRecord>(
            predicate: #Predicate<CoachingCueRecord> { record in
                record.cacheKey == key
            }
        )
        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }
        guard record.sectionRevisionID == request.sectionRevisionID,
              record.promptVersion == request.promptVersion,
              record.contentFingerprint == fingerprint,
              let suggestion = record.suggestion,
              suggestion.promptVersion == request.promptVersion,
              suggestion.sectionRevisionID == request.sectionRevisionID else {
            return nil
        }
        return suggestion
    }

    func savePreparationCue(
        _ suggestion: CoachingSuggestion,
        for request: PreparationCoachingRequest
    ) throws {
        let encoded = try JSONEncoder().encode(suggestion)
        let key = request.cacheKey
        try performAtomicWrite {
            let descriptor = FetchDescriptor<CoachingCueRecord>(
                predicate: #Predicate<CoachingCueRecord> { record in
                    record.cacheKey == key
                }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.presentationID = request.presentationID
                existing.sectionRevisionID = request.sectionRevisionID
                existing.techniqueID = request.effectiveTechniqueKey
                existing.promptVersion = request.promptVersion
                existing.contentFingerprint = request.contentFingerprint
                existing.payloadData = encoded
                existing.updatedAt = suggestion.updatedAt
            } else {
                let record = CoachingCueRecord(
                    cacheKey: key,
                    taskKind: .preparation,
                    presentationID: request.presentationID,
                    sectionRevisionID: request.sectionRevisionID,
                    attemptID: nil,
                    techniqueID: request.effectiveTechniqueKey,
                    promptVersion: request.promptVersion,
                    evidenceVersion: nil,
                    contentFingerprint: request.contentFingerprint,
                    payloadData: encoded,
                    updatedAt: suggestion.updatedAt
                )
                modelContext.insert(record)
            }
        }
    }

    func fetchCachedPostTakeCue(for request: PostTakeCoachingRequest) throws -> CoachingSuggestion? {
        let key = request.cacheKey
        let expectedEvidence = request.evidenceVersion
        let descriptor = FetchDescriptor<CoachingCueRecord>(
            predicate: #Predicate<CoachingCueRecord> { record in
                record.cacheKey == key
            }
        )
        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }
        guard record.attemptID == request.attemptID,
              record.sectionRevisionID == request.sectionRevisionID,
              record.evidenceVersion == expectedEvidence,
              record.promptVersion == request.promptVersion,
              let suggestion = record.suggestion,
              suggestion.promptVersion == request.promptVersion,
              suggestion.sectionRevisionID == request.sectionRevisionID,
              suggestion.attemptID == request.attemptID,
              suggestion.evidenceVersion == expectedEvidence else {
            return nil
        }
        return suggestion
    }

    func savePostTakeCue(
        _ suggestion: CoachingSuggestion,
        for request: PostTakeCoachingRequest
    ) throws {
        let encoded = try JSONEncoder().encode(suggestion)
        let key = request.cacheKey
        try performAtomicWrite {
            let descriptor = FetchDescriptor<CoachingCueRecord>(
                predicate: #Predicate<CoachingCueRecord> { record in
                    record.cacheKey == key
                }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.presentationID = request.presentationID
                existing.sectionRevisionID = request.sectionRevisionID
                existing.attemptID = request.attemptID
                existing.techniqueID = suggestion.techniqueID ?? "abstain"
                existing.promptVersion = request.promptVersion
                existing.evidenceVersion = request.evidenceVersion
                existing.payloadData = encoded
                existing.updatedAt = suggestion.updatedAt
            } else {
                let record = CoachingCueRecord(
                    cacheKey: key,
                    taskKind: .postTake,
                    presentationID: request.presentationID,
                    sectionRevisionID: request.sectionRevisionID,
                    attemptID: request.attemptID,
                    techniqueID: suggestion.techniqueID ?? "abstain",
                    promptVersion: request.promptVersion,
                    evidenceVersion: request.evidenceVersion,
                    contentFingerprint: nil,
                    payloadData: encoded,
                    updatedAt: suggestion.updatedAt
                )
                modelContext.insert(record)
            }
        }
    }

    func deleteCues(forAttemptID attemptID: UUID) throws {
        let descriptor = FetchDescriptor<CoachingCueRecord>(
            predicate: #Predicate<CoachingCueRecord> { record in
                record.attemptID == attemptID
            }
        )
        let records = try modelContext.fetch(descriptor)
        for record in records {
            modelContext.delete(record)
        }
    }

    func deleteCues(forPresentationID presentationID: UUID) throws {
        let descriptor = FetchDescriptor<CoachingCueRecord>(
            predicate: #Predicate<CoachingCueRecord> { record in
                record.presentationID == presentationID
            }
        )
        let records = try modelContext.fetch(descriptor)
        for record in records {
            modelContext.delete(record)
        }
    }

    private func performAtomicWrite(_ body: () throws -> Void) throws {
        let previousAutosave = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosave }

        do {
            try body()
            try saveContext(modelContext)
        } catch {
            modelContext.processPendingChanges()
            modelContext.rollback()
            throw error
        }
    }
}
