import Foundation

extension TechniqueLibrary {
    private struct SecondaryActionSpec {
        let suffix: String
        let summary: String
        let instruction: String
    }

    static func secondaryPreparationAction(for technique: CoachingTechnique) -> CoachingPreparationActionOption {
        let details = secondaryActionTable[technique.id] ?? SecondaryActionSpec(
            suffix: "plain-contrast",
            summary: "State the framing contrast cleanly before your main line",
            instruction: "Keep the two framing points plain and distinct, then pause briefly before " +
                "delivering your highlighted line."
        )
        return CoachingPreparationActionOption(
            id: "\(technique.id).\(details.suffix)",
            techniqueID: technique.id,
            summaryForModel: details.summary,
            renderedAction: details.instruction,
            allowsHandoffPassage: technique.appliesToHandoff,
            allowsScriptPassage: true
        )
    }

    private static let secondaryActionTable: [String: SecondaryActionSpec] = [
        "handoff.echo-bridge": SecondaryActionSpec(
            suffix: "steady-opening",
            summary: "Acknowledge the handoff cue briefly, then land your first point calmly",
            instruction: "Acknowledge the cue from the previous section in one plain clause, " +
                "pause briefly, and step cleanly into your first point."
        ),
        "handoff.clean-beat": SecondaryActionSpec(
            suffix: "breath-reset",
            summary: "Let the handoff settle with one calm breath before starting",
            instruction: "Wait until the preceding line fully settles, take one quiet breath, " +
                "and open directly on your highlighted phrase."
        ),
        "handoff.name-the-turn": SecondaryActionSpec(
            suffix: "crisp-cue",
            summary: "Keep the turn-taking line short and direct without extra filler",
            instruction: "Deliver the handoff line directly at conversational pace and stop cleanly " +
                "so the next speaker or step enters without overlap."
        ),
        "reveal.three-part-resolution": SecondaryActionSpec(
            suffix: "pause-before-payoff",
            summary: "Separate the setup items clearly and hold a beat before the reveal line",
            instruction: "Give each setup phrase its own crisp pause, then hold one quiet beat " +
                "before delivering the final reveal phrase cleanly."
        ),
        "reveal.contrast-before-headline": SecondaryActionSpec(
            suffix: "drop-on-contrast",
            summary: "Stop cleanly on the contrast before stating your headline",
            instruction: "Keep the familiar alternative brief, land firmly on the turn away from it, " +
                "and state your headline line plainly."
        ),
        "reveal.problem-to-short-line": SecondaryActionSpec(
            suffix: "unhurried-headline",
            summary: "Keep the limit concise so the short headline carries the beat",
            instruction: "Deliver the limitation in a steady, matter-of-fact cadence, then pause " +
                "briefly before landing your short headline phrase."
        ),
        "reveal.anchor-before-number": SecondaryActionSpec(
            suffix: "separate-anchor",
            summary: "Let the comparison anchor register before stating the payoff",
            instruction: "Pause briefly after the familiar reference point so the audience holds it " +
                "in mind before you deliver the highlighted headline."
        ),
        "demo.narrate-the-gesture": SecondaryActionSpec(
            suffix: "cue-then-tap",
            summary: "Speak the short cue right before the gesture, then let the screen answer",
            instruction: "Say the short cue line just before moving your hand, perform the tap " +
                "deliberately, and let the result register before speaking again."
        ),
        "demo.question-then-show": SecondaryActionSpec(
            suffix: "short-answer",
            summary: "Ask the setup question briskly, then keep the confirmation minimal",
            instruction: "Deliver the framing question cleanly, execute the visible action without " +
                "extra narration, and confirm the result in a short phrase."
        ),
        "demo.anchor-screen-cue": SecondaryActionSpec(
            suffix: "wait-for-eyes",
            summary: "Give listeners a brief beat to find the screen landmark before tapping",
            instruction: "Name the exact on-screen landmark first, hold a short beat so eyes find it, " +
                "and only then trigger the next interaction."
        ),
        "demo.hold-for-load": SecondaryActionSpec(
            suffix: "confirm-after-silence",
            summary: "Hold calm silence during the wait, then confirm once the result appears",
            instruction: "Stay silent through the live load or transition without filling the air, " +
                "then deliver the confirmation phrase cleanly once it appears."
        ),
        "close.lineup-identity": SecondaryActionSpec(
            suffix: "steady-summary",
            summary: "Keep the recap tight so the final identity line stands out",
            instruction: "Keep the closing recap crisp and rhythmic, then slow slightly as you land " +
                "the single identity sentence."
        ),
        "close.opening-callback": SecondaryActionSpec(
            suffix: "bridge-to-takeaway",
            summary: "Pause lightly between the opening callback and final takeaway",
            instruction: "State the callback to your opening plainly, hold a brief beat, and deliver " +
                "your final takeaway line cleanly."
        ),
        "close.short-final-line": SecondaryActionSpec(
            suffix: "clean-stop",
            summary: "Deliver the final phrase cleanly and stop without trailing remarks",
            instruction: "Give the highlighted closing line an unhurried landing, hold a quiet beat, " +
                "and end cleanly without adding extra qualifiers."
        ),
        "story.two-milestone-setup": SecondaryActionSpec(
            suffix: "tight-transition",
            summary: "Keep the setup anchors crisp so momentum carries into the point",
            instruction: "Deliver each anchor cleanly without detouring so your story moves smoothly " +
                "into the highlighted takeaway line."
        )
    ]
}
