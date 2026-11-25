import Foundation

nonisolated enum TechniqueLibrary {
    static let macworld2007Work = "Steve Jobs, Macworld 2007 iPhone Introduction"

    static let allTechniques: [CoachingTechnique] = handoffTechniques
        + revealTechniques
        + demoTechniques
        + closeAndStoryTechniques

    static func technique(withID id: String) -> CoachingTechnique? {
        allTechniques.first { $0.id == id }
    }

    static func candidateTechniques(
        for purpose: SectionPurpose,
        hasHandoff: Bool
    ) -> [CoachingTechnique] {
        var result: [CoachingTechnique] = []
        let primary = allTechniques.filter { !$0.appliesToHandoff && $0.applicablePurposes.contains(purpose) }
        result.append(contentsOf: primary)

        if hasHandoff {
            let handoffList = allTechniques.filter(\.appliesToHandoff)
            for technique in handoffList where !result.contains(where: { $0.id == technique.id }) {
                result.append(technique)
            }
        }

        if result.isEmpty {
            result = allTechniques.filter { $0.applicablePurposes.contains(.general) }
        }
        return result
    }
}

private extension TechniqueLibrary {
    static let handoffTechniques: [CoachingTechnique] = [
        CoachingTechnique(
            id: "handoff.echo-bridge",
            title: "Echo the Previous Speaker’s Theme",
            category: .handoff,
            applicablePurposes: [.general, .story, .reveal, .demonstration, .closing],
            appliesToHandoff: true,
            sourceWork: macworld2007Work,
            sourceTimestamp: "01:40:43–01:41:03",
            sourcePassageSummary:
                "After Stan Sigman left the stage, Jobs echoed Stan’s timeline ('as Stan said, " +
                "we started working together about two years ago') before pivoting to market size.",
            deliveryInstruction:
                "Pick up one concrete idea from the preceding line, acknowledge it in your opening " +
                "beat, and bridge straight into your own first point.",
            postTakeFocus:
                "Replay the transition from the handoff cue and listen for whether your first line " +
                "connects cleanly to what came before it."
        ),
        CoachingTechnique(
            id: "handoff.clean-beat",
            title: "Clear the Air With a Beat",
            category: .handoff,
            applicablePurposes: [.general, .story, .reveal, .demonstration, .closing],
            appliesToHandoff: true,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:26:22",
            sourcePassageSummary:
                "After closing the Apple TV segment, Jobs paused deliberately to drink before opening " +
                "the iPhone arc with 'This is a day I’ve been looking forward to for two and a half years.'",
            deliveryInstruction:
                "Take one deliberate silent beat after the preceding cue finishes so the previous " +
                "segment settles before you speak your opening line.",
            postTakeFocus:
                "Replay the opening seconds and judge whether your first words enter with a clean " +
                "pause rather than stepping on the transition."
        ),
        CoachingTechnique(
            id: "handoff.name-the-turn",
            title: "Direct Conversational Turn",
            category: .handoff,
            applicablePurposes: [.general, .demonstration, .story],
            appliesToHandoff: true,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:23:04–00:23:36",
            sourcePassageSummary:
                "Jobs framed the multi-computer demo by inviting Phil Schiller in directly ('Phil, " +
                "what do you got on your Mac?') and closing the turn cleanly ('All right. So, thank you, Phil.').",
            deliveryInstruction:
                "State the person or handoff moment plainly in one short phrase, then step directly " +
                "into the next action without extra filler.",
            postTakeFocus:
                "Listen back to the speaker turn to decide whether the handoff line lands crisply " +
                "and leaves room for the next speaker or act."
        )
    ]

    static let revealTechniques: [CoachingTechnique] = [
        CoachingTechnique(
            id: "reveal.three-part-resolution",
            title: "Resolve a Repeated Setup Into One Reveal",
            category: .reveal,
            applicablePurposes: [.reveal],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:27:38–00:29:28",
            sourcePassageSummary:
                "Jobs repeated three categories ('widescreen iPod, revolutionary mobile phone, " +
                "breakthrough internet communicator') before resolving them into one reveal ('one device… iPhone').",
            deliveryInstruction:
                "Keep each setup beat distinct and rhythmic, hold a brief beat before the payoff, " +
                "and deliver the final reveal line cleanly without rushing.",
            postTakeFocus:
                "Replay the setup and payoff line to hear whether the reveal stands apart from the " +
                "build-up before it."
        ),
        CoachingTechnique(
            id: "reveal.contrast-before-headline",
            title: "Reject the Familiar Alternative First",
            category: .reveal,
            applicablePurposes: [.reveal, .story],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:32:55–00:33:27",
            sourcePassageSummary:
                "Jobs asked 'Oh, a stylus, right?', rejected it crisply ('No. Who wants a stylus?'), " +
                "and then revealed direct multi-touch with fingers.",
            deliveryInstruction:
                "Deliver the old alternative as a short question or contrast, stop cleanly on the " +
                "rejection, then state your solution in plain words.",
            postTakeFocus:
                "Listen to the turn between the contrast and your solution to judge if the shift " +
                "feels sharp and unhurried."
        ),
        CoachingTechnique(
            id: "reveal.problem-to-short-line",
            title: "Name the Limit Before a Short Headline",
            category: .reveal,
            applicablePurposes: [.reveal, .general],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:34:37–00:35:08",
            sourcePassageSummary:
                "After calling mobile phone software limited ('baby software'), Jobs landed a " +
                "four-word headline: 'iPhone runs OS X.'",
            deliveryInstruction:
                "Keep the problem statement tight and matter-of-fact so your short headline line " +
                "carries the weight when it lands.",
            postTakeFocus:
                "Replay the headline line and check whether it comes across cleanly without extra " +
                "qualifiers trailing behind it."
        ),
        CoachingTechnique(
            id: "reveal.anchor-before-number",
            title: "Anchor Familiar Context Before the Headline",
            category: .reveal,
            applicablePurposes: [.reveal, .closing],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "01:30:46–01:33:04",
            sourcePassageSummary:
                "Jobs anchored the familiar cost of an iPod ($199) plus a smartphone ($299) at $499 " +
                "before revealing iPhone’s $499 starting price.",
            deliveryInstruction:
                "Give each reference point its own beat so the audience can hold the comparison in " +
                "mind before you state your headline number or claim.",
            postTakeFocus:
                "Replay the comparison leading into your key phrase to hear whether the reference " +
                "point registers before the reveal."
        )
    ]

    static let demoTechniques: [CoachingTechnique] = [
        CoachingTechnique(
            id: "demo.narrate-the-gesture",
            title: "Narrate the Visible Action as You Do It",
            category: .demo,
            applicablePurposes: [.demonstration],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:41:34–00:42:02",
            sourcePassageSummary:
                "With the overhead camera up, Jobs matched each physical action to one plain phrase: " +
                "'push the sleep/wake button… take my finger and slide it across… Boom.'",
            deliveryInstruction:
                "Name the exact tap or gesture right before your hand moves, then pause briefly as " +
                "the screen responds so voice and visual stay synchronized.",
            postTakeFocus:
                "Replay the demo line and check whether your spoken cue leaves room for the " +
                "on-screen gesture to land."
        ),
        CoachingTechnique(
            id: "demo.question-then-show",
            title: "Ask One Short Question, Then Let the Demo Answer",
            category: .demo,
            applicablePurposes: [.demonstration],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:42:20–00:42:44",
            sourcePassageSummary:
                "Before scrolling artists, Jobs asked 'How do I scroll through my list of artists?' " +
                "and let the flick gesture answer ('I just take my finger and I scroll. That’s it.').",
            deliveryInstruction:
                "Frame the next interaction with one concise 'how do you…' question, then perform " +
                "the action and keep the confirmation to a few words.",
            postTakeFocus:
                "Listen back to the question-and-result beat to see if the spoken explanation stays " +
                "out of the way of the visible proof."
        ),
        CoachingTechnique(
            id: "demo.anchor-screen-cue",
            title: "Direct Eyes to One Specific Screen Cue",
            category: .demo,
            applicablePurposes: [.demonstration],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:51:15–00:52:01",
            sourcePassageSummary:
                "Jobs guided attention to visual landmarks ('that icon in the lower left-hand " +
                "corner' and 'the green bar across the top') before tapping.",
            deliveryInstruction:
                "Point the audience to the exact corner, icon, or indicator first so they are " +
                "looking at the right spot before the screen changes.",
            postTakeFocus:
                "Replay your attention-directing phrase and decide whether an audience member would " +
                "have time to find the cue before the next step."
        ),
        CoachingTechnique(
            id: "demo.hold-for-load",
            title: "Hold Deliberate Silence While the Demo Responds",
            category: .demo,
            applicablePurposes: [.demonstration],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "01:07:30–01:08:49",
            sourcePassageSummary:
                "While loading the full New York Times page over Wi-Fi, Jobs stayed calm through the " +
                "brief load ('Here we are loading it… And there it is') instead of rushing past it.",
            deliveryInstruction:
                "Keep deliberate silence during a live load or transition rather than filling the " +
                "air, then confirm the result in a short phrase once it appears.",
            postTakeFocus:
                "Replay around the silent demo beat to verify the wait feels intentional rather " +
                "than rushed."
        )
    ]

    static let closeAndStoryTechniques: [CoachingTechnique] = [
        CoachingTechnique(
            id: "close.lineup-identity",
            title: "Gather the Arc Into One Identity Line",
            category: .close,
            applicablePurposes: [.closing],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "01:43:37–01:44:22",
            sourcePassageSummary:
                "Jobs summarized the four-product lineup (Mac, iPod, Apple TV, iPhone) and distilled " +
                "it into one clear statement: dropping 'Computer' to become Apple Inc.",
            deliveryInstruction:
                "Summarize the talk’s core pieces in one clean breath, then land on a single plain " +
                "sentence that states what the whole presentation means.",
            postTakeFocus:
                "Replay the summary into your closing statement to hear whether the final takeaway " +
                "feels unified and decisive."
        ),
        CoachingTechnique(
            id: "close.opening-callback",
            title: "Echo Your Opening Arc Before the Takeaway",
            category: .close,
            applicablePurposes: [.closing, .story],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "01:44:22–01:44:55",
            sourcePassageSummary:
                "Near the close, Jobs returned to the 1984 Mac and 2001 iPod milestones he opened " +
                "the iPhone segment with, tying them directly to 2007.",
            deliveryInstruction:
                "Bring back the opening question or milestone briefly right before your takeaway so " +
                "the audience hears the circle close.",
            postTakeFocus:
                "Listen back to the closing passage to decide whether the callback connects clearly " +
                "to your final line."
        ),
        CoachingTechnique(
            id: "close.short-final-line",
            title: "Land One Short Final Line and Stop Cleanly",
            category: .close,
            applicablePurposes: [.closing],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "01:44:55",
            sourcePassageSummary:
                "Jobs closed with one brief Wayne Gretzky line ('skate to where the puck is going " +
                "to be'), one linking sentence, and a clean 'So, thank you, very, very much.'",
            deliveryInstruction:
                "Slow slightly on your final takeaway sentence, let a brief beat sit after it, and " +
                "deliver your thank-you cleanly without tacking on extra remarks.",
            postTakeFocus:
                "Replay the final seconds of the take to hear whether the ending lands cleanly " +
                "instead of trailing off."
        ),
        CoachingTechnique(
            id: "story.two-milestone-setup",
            title: "Ground the Story in Two Brief Anchors",
            category: .story,
            applicablePurposes: [.story, .general],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:26:33–00:27:38",
            sourcePassageSummary:
                "Jobs used two tight historical anchors—1984 Macintosh and 2001 iPod—in under a " +
                "minute to earn the stakes for today’s announcement.",
            deliveryInstruction:
                "Keep background context to one or two crisp, dated or concrete anchors so momentum " +
                "moves quickly toward why today matters.",
            postTakeFocus:
                "Replay the story opening to judge whether the setup stays tight enough to carry " +
                "energy into your main point."
        ),
        CoachingTechnique(
            id: "general.two-axis-frame",
            title: "Frame Two Simple Tradeoffs Before Your Thesis",
            category: .general,
            applicablePurposes: [.general, .story],
            appliesToHandoff: false,
            sourceWork: macworld2007Work,
            sourceTimestamp: "00:30:15–00:31:02",
            sourcePassageSummary:
                "Jobs framed the smartphone market on two plain axes—'smart' and 'easy to " +
                "use'—before stating iPhone’s thesis.",
            deliveryInstruction:
                "Contrast two straightforward criteria in plain language first so your audience " +
                "immediately sees what makes your approach different.",
            postTakeFocus:
                "Replay the framing lines to check whether the contrast comes across plainly " +
                "without jargon."
        )
    ]
}
