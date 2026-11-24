# Spelum MVP design

**Acceptance scenario.** On an iPhone 17, a presenter reads their teammate’s closing line, delivers their own product reveal from memory, replays the transition, and makes another attempt. Later they rehearse the entire English-language talk, including the live demo, and compare two runs.

## Rehearsal experience

The presentation library opens a talk at its ordered sections. The presenter pastes or imports UTF-8 plain text, divides it into sections, assigns speakers, and selects a purpose such as story, reveal, demonstration, closing, or general. Keep their original words available throughout. Let them edit cue words, mark a phrase to deliver exactly, and paraphrase the rest. A handoff can show the preceding speaker’s last line even when practicing alone.

Practice offers full text, cue words, and recall from memory. During a take, the presenter controls the timer, recording, markers, and any script reveals. A review opens with playback and the relevant phrase or marked moment. It offers one delivery experiment at a time and a quick retry. Full runs retain one audio timeline across speakers, including deliberate silence during demos. Users can delete individual recordings and review earlier script revisions.

## Native iOS design

Use Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) as the design reference for every screen. Start with standard SwiftUI components and their system appearance and behavior. A library can use a navigable List, a script editor can use a TextEditor and toolbar, and import can use the system file picker. Follow platform conventions for back navigation, sheets, destructive confirmations, typography, SF Symbols, semantic colors, safe areas, and light and dark appearance. For a custom rehearsal control, identify the interaction that needs it and preserve its accessible label, state, and system interaction behavior.

## What the coach can say

Base the initial technique library on Steve Jobs’s 2007 iPhone introduction. Two examples are resolving a repeated setup into a short reveal, and directing attention to a visible action during a demonstration. Write original instructions with provenance. Applying one of these techniques is an editorial suggestion. The speaker can keep, edit, or dismiss it. [Keynote and timed transcript](https://allaboutstevejobs.com/videos/keynotes/macworld_2007)

Duration, manually placed markers, and reveal taps are recorded facts. Pace and gaps derived from transcription are estimates. Playback is the basis for deciding whether a delivery choice worked. The app makes no claim to grade accent, pronunciation, emotion, articulation, or similarity to Jobs. There is no voice cloning, shadowing, or global performance score.

## Product and technical choices

| Choice | Rationale |
| --- | --- |
| Section practice before a full-run recorder | A repeatable handoff and reveal lets the presenter change one thing and immediately hear the difference. The full run then tests timing and transitions in context. |
| Native SwiftUI on iOS 27.0+, English, iPhone first | Target the presenter’s iPhone 17. Use native navigation, Dynamic Type, VoiceOver, and clear recording states. The exact installed phone OS still needs a device check. |
| Local storage and local speech processing | SwiftData holds scripts and history. AVFoundation stores audio in the app container. Apple Speech supplies time ranges where available. Preserve manual practice and playback if speech assets are unavailable. [SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) |
| Curated cues plus an evaluated Apple on-device model | Apple Foundation Models can produce structured suggestions for a bounded passage. Assess preparation and post-take feedback independently against authored cues. Rehearsal works offline after applicable system assets are installed. [Foundation Models](https://developer.apple.com/documentation/foundationmodels/) |
| Conditional Gemini comparison | A downloadable model adds model distribution and device testing. A hosted model adds a network dependency and data transfer. Compare Gemini only for a task where local results fall short. If the comparison justifies shipping it, use explicit consent and a small authenticated backend with the owner’s server-held key. Cloud deployment is a separate decision. |

## Delivery and responsibilities

Ship through internal TestFlight. Require SwiftLint and build/test checks on pull requests to main. Root AGENTS.md will describe commands, data handling, and conventions for contributors. Codex owns planning and integration review. Gemini 4 Neon on Antigravity is the requested programming model. This choice concerns development tooling and is independent of the model shipped in the app.

There is no calendar deadline. Each milestone has an observable result on the target phone. Source-control administration, distribution team access, and the permanent bundle identifier require verification during setup.
