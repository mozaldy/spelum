import Foundation
import SwiftData

extension AttemptStore {
    @discardableResult
    func saveTimingAnalysis(
        _ analysis: TimingAnalysisResult,
        forAttemptID attemptID: UUID,
        expectedRelativeAudioPath: String?,
        expectedTalkRevisionID: UUID,
        expectedSectionRevisionID: UUID
    ) throws -> Bool {
        let encoded = try JSONEncoder().encode(analysis)
        return try performAtomicWrite {
            guard let existing = try attempt(withID: attemptID) else {
                return false
            }
            guard existing.relativeAudioPath == expectedRelativeAudioPath,
                  existing.talkRevisionID == expectedTalkRevisionID,
                  existing.sectionRevisionID == expectedSectionRevisionID else {
                return false
            }
            existing.timingAnalysisData = encoded
            return true
        }
    }

    @discardableResult
    func addManualMarker(
        toAttemptID attemptID: UUID,
        timestamp: TimeInterval,
        label: String? = nil,
        createdAt: Date = Date()
    ) throws -> AttemptMarker? {
        try performAtomicWrite {
            guard let existing = try attempt(withID: attemptID) else {
                return nil
            }
            let safeMax = max(existing.displayDuration, 0)
            let finiteTime = timestamp.isFinite ? max(0, timestamp) : 0
            let clamped = safeMax > 0 ? min(finiteTime, safeMax) : finiteTime
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedLabel = trimmed.isEmpty
                ? "Marker \(existing.markers.count + 1)"
                : trimmed
            let marker = AttemptMarker(
                timestamp: clamped,
                label: resolvedLabel,
                createdAt: createdAt
            )
            var updated = existing.markers
            updated.append(marker)
            existing.updateMarkers(updated)
            return marker
        }
    }
}
