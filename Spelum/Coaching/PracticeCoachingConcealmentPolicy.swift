import Foundation
import SwiftUI

enum PracticeCoachingConcealmentState: Equatable, Sendable {
    /// Full cue is visible (Full Script mode, script revealed, or verified unedited handoff / marked exact phrase).
    case visible
    /// Verbatim script passage, disclosure, and mutation controls are concealed (Cue Words mode quoting hidden body text).
    case concealScriptPassage
    /// Entire coaching cue body, disclosure, and mutation controls are concealed behind a reveal gate.
    case concealEntireCue
}

enum PracticeCoachingConcealmentReason: Equatable, Sendable {
    case none
    case memoryMode
    case cueWordsHiddenBodyPassage
    case editedReminderInCueWords
}

struct PracticeCoachingConcealmentPolicy: Equatable, Sendable {
    let state: PracticeCoachingConcealmentState
    let allowsEditing: Bool
    let reason: PracticeCoachingConcealmentReason

    init(
        state: PracticeCoachingConcealmentState,
        allowsEditing: Bool,
        reason: PracticeCoachingConcealmentReason = .none
    ) {
        self.state = state
        self.allowsEditing = allowsEditing
        self.reason = reason
    }

    var showsCueBody: Bool {
        state != .concealEntireCue
    }

    var showsQuotedPassage: Bool {
        state == .visible
    }

    var showsProvenanceDisclosure: Bool {
        state == .visible
    }

    var allowsCustomActions: Bool {
        state == .visible
    }

    var showsRevealAction: Bool {
        state != .visible
    }

    static func evaluate(
        practiceMode: PracticeMode,
        isScriptRevealed: Bool,
        sectionExactPhrase: String?,
        handoffCueText: String?,
        cue: CoachingSuggestion
    ) -> PracticeCoachingConcealmentPolicy {
        if practiceMode == .fullScript || isScriptRevealed {
            return PracticeCoachingConcealmentPolicy(state: .visible, allowsEditing: true, reason: .none)
        }

        let isIntentionalHandoff = isVerifiedIntentionalHandoff(
            cue: cue,
            handoffCueText: handoffCueText
        )

        switch practiceMode {
        case .fullScript:
            return PracticeCoachingConcealmentPolicy(state: .visible, allowsEditing: true, reason: .none)

        case .memory:
            if isIntentionalHandoff {
                return PracticeCoachingConcealmentPolicy(state: .visible, allowsEditing: false, reason: .none)
            }
            return PracticeCoachingConcealmentPolicy(
                state: .concealEntireCue,
                allowsEditing: false,
                reason: .memoryMode
            )

        case .cueWords:
            if cue.isUserEdited {
                return PracticeCoachingConcealmentPolicy(
                    state: .concealEntireCue,
                    allowsEditing: false,
                    reason: .editedReminderInCueWords
                )
            }
            if let quoted = normalized(cue.exactPhrase) {
                if isIntentionalHandoff {
                    return PracticeCoachingConcealmentPolicy(state: .visible, allowsEditing: true, reason: .none)
                }
                if let markedExact = normalized(sectionExactPhrase), quoted == markedExact {
                    return PracticeCoachingConcealmentPolicy(state: .visible, allowsEditing: true, reason: .none)
                }
                return PracticeCoachingConcealmentPolicy(
                    state: .concealScriptPassage,
                    allowsEditing: false,
                    reason: .cueWordsHiddenBodyPassage
                )
            }
            return PracticeCoachingConcealmentPolicy(state: .visible, allowsEditing: true, reason: .none)
        }
    }

    private static func isVerifiedIntentionalHandoff(
        cue: CoachingSuggestion,
        handoffCueText: String?
    ) -> Bool {
        guard cue.exactPhraseFromHandoff,
              !cue.isUserEdited,
              let quoted = normalized(cue.exactPhrase),
              let handoff = normalized(handoffCueText) else {
            return false
        }
        return handoff.contains(quoted)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct PracticeCoachingConcealedCueView: View {
    let isActiveTake: Bool
    var reason: PracticeCoachingConcealmentReason = .memoryMode
    let onRevealScript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(titleText, systemImage: "eye.slash")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("practiceCoachConcealedTitle")

            Text(explanationText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onRevealScript()
            } label: {
                Label(revealButtonTitle, systemImage: "eye")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(
                isActiveTake
                    ? "Reveals the script and coaching cue, and adds one reveal to this take."
                    : "Reveals the script and coaching cue."
            )
            .accessibilityIdentifier("practiceCoachRevealButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("practiceCoachConcealedView")
    }

    var titleText: String {
        if reason == .editedReminderInCueWords {
            return "Edited Reminder Hidden (Cue Words)"
        }
        return "Coach Hidden for Recall"
    }

    var revealButtonTitle: String {
        if reason == .editedReminderInCueWords {
            return "Reveal Script & Edited Reminder"
        }
        return "Reveal Script & Coach"
    }

    var explanationText: String {
        if reason == .editedReminderInCueWords {
            if isActiveTake {
                return "Your edited coaching reminder stays hidden in Cue Words mode while the script is concealed. " +
                    "Reveal the script to view it (counts as one reveal for this take)."
            }
            return "Your edited coaching reminder needs a script reveal to view in Cue Words mode, " +
                "keeping custom wording from giving away hidden lines."
        }
        if isActiveTake {
            return "Pre-practice coaching is hidden while your script is concealed. " +
                "Revealing also counts as a script reveal for this take."
        }
        return "Pre-practice coaching is hidden while your script is concealed so verbatim lines stay out of sight."
    }
}

struct PracticeCoachingConcealedPassageBox: View {
    let isActiveTake: Bool
    let onRevealScript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Script Passage Hidden (Cue Words Mode)", systemImage: "eye.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(
                isActiveTake
                    ? "Reveal the script to view this quoted body line. Revealing counts toward your take reveals."
                    : "Reveal the script to view this quoted body line."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                onRevealScript()
            } label: {
                Label("Reveal Script", systemImage: "eye")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(
                isActiveTake
                    ? "Reveals the full script and adds one reveal to this take."
                    : "Reveals the full script."
            )
            .accessibilityIdentifier("practiceCoachRevealButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("practiceCoachConcealedPassageBox")
    }
}
