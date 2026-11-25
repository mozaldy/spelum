# Spelum MVP implementation plan

**Goal.** Ship an English-language iPhone rehearsal app that helps its owner remember a presentation, practice a chosen delivery technique, and hear the difference between attempts.

**Architecture.** SwiftUI owns navigation and practice controls, SwiftData holds immutable script revisions and attempt metadata, and AVFoundation owns recordings. Apple Speech and the on-device Foundation Models provider enrich a saved take independently. Saving and replaying a take must succeed when either enrichment is unavailable.

**Target.** iPhone 17, iOS 27.0 minimum, Xcode 27.2. Use Apple frameworks and Swift Testing/XCTest. The only required development tool beyond Xcode is pinned SwiftLint.

**Design.** Read the [MVP design](../specs/2026-11-25-spelum-mvp-design.md) before implementing.

## Handoff to Neon

After owner approval, Codex hands one numbered task at a time to **Gemini 4 Neon on Antigravity**. Give it this plan, the design, its task number, the current branch or commit, and the preceding task’s verification results. Keep the docs available in its checkout. Ask for a focused patch, test output, and any checks that require a device or account owner. Use Neon at High. For each completed implementation task, dispatch a fresh independent review to Gemini 4 Hydrogen at High on Antigravity. The reviewer checks the diff, reruns relevant tests, and reports findings with reproduction evidence. Codex integrates the review before handing off dependent work. Reuse one PR for closely related changes when that keeps review simple. Use the requested provider and model throughout programming.

**Design review for UI changes.** Follow the [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/). Prefer standard SwiftUI components, system text styles, semantic colors, and familiar iOS navigation. State the interaction that justifies any custom control. Supply evidence for light and dark appearance, accessibility text size, and VoiceOver labels and navigation on changed screens. The reviewer checks this alongside behavioral acceptance criteria.

**Starting point.** The repository currently has the Spelum app target, the shared MyApp scheme, and a starter ContentView. Project settings live in `Spelum.xcodeproj/project.xcproj`. The shared scheme has an existing working-tree edit. Preserve it when adding tests. The bundle ID is a placeholder, and the current deployment target is 27.2. Git tracks origin/main.

**Verification commands.** Keep the existing shared scheme name through this MVP. The following destination exists on the development Mac. Provision the same runtime on CI or use an available iOS 27.x simulator on the selected runner. Record the resolved Xcode and simulator versions in the job output.

```sh
xcodebuild -list -project Spelum.xcodeproj
swiftlint lint --strict --config .swiftlint.yml
xcodebuild test -project Spelum.xcodeproj -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
xcodebuild build -project Spelum.xcodeproj -scheme MyApp -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

For each implementation task, add the named regression first and run the relevant test using `-only-testing:SpelumTests/TestSuiteName` with the actual suite name. Verify the regression fails for the expected reason, implement, then run the full checks above. Test results for audio hardware, distribution, and model quality require the additional evidence specified below.

## Milestone 1 — Installable section practice

### 1. Establish a build Neon and CI can reproduce

**Files.** Project settings and shared scheme, root `AGENTS.md`, `.swiftlint.yml`, `SpelumTests/AppConfigurationTests.swift`, and the PR workflow in the repository host. For GitHub, use `.github/workflows/ios.yml`.

- [ ] Configure an iPhone app with minimum iOS 27.0. Add the hosted SpelumTests target to the existing shared scheme. Make a configuration smoke test assert the expected minimum OS from the app bundle.
- [ ] Pin a SwiftLint release compatible with this toolchain. Record its exact version and install/check commands in AGENTS.md. Include the project layout, checks above, local data boundary, and how to report simulator versus phone results.
- [ ] Add named PR checks `SwiftLint` and `iOS build and tests`. Validate a lint violation and a failing assertion each fail the corresponding check, then remove those temporary failures. Enable the checks as required on main once the host has registered them. Verify the resulting protection using the host settings or API.
- [ ] Confirm the distribution team and a permanent bundle ID with the owner’s account. Use the same identifier for signing and App Store Connect. Record any account-only dependency separately so local feature development can proceed.

### 2. Import a script and prepare the handoff

**Files.** `Spelum/MyApp.swift`, `Spelum/ContentView.swift`, `Spelum/Library/PresentationStore.swift`, `Spelum/Library/ScriptEditor.swift`, `SpelumTests/PresentationStoreTests.swift`.

- [ ] Test importing a two-speaker UTF-8 script with blank lines, curly quotes, and emoji. Verify the original wording survives import, split, save, and relaunch. Empty or unreadable input leaves the previous talk intact.
- [ ] Add SwiftData records for a presentation, ordered section revisions, and a talk revision referencing them. Each section stores a stable section ID, revision ID, text, speaker, purpose, editable cues, and optional exact phrase. A saved edit creates a new revision. A take retains the revision IDs it started with.
- [ ] Implement paste and Files import, manual split at a selected text position, title, speaker assignment, purpose, and editable cue words. Use the same import path for paste and file text. Preserve original text independently of display formatting.
- [ ] Show the selected section with the preceding section’s final line as an editable handoff cue. Test first section, changed speaker, reordered sections, and a talk with one speaker.

### 3. Record, replay, and retry a section entirely offline

**Files.** `Spelum/Practice/PracticeView.swift`, `Spelum/Practice/RecordingSession.swift`, `Spelum/Practice/AttemptStore.swift`, `Spelum/Review/TakeReview.swift`, `SpelumTests/AttemptStoreTests.swift`. Wire navigation from ContentView.

- [ ] Define an attempt with UUID, talk/section revision, start date, practice mode, relative audio path, playable duration, reveal count, and manual markers. Use opaque file names. Keep attempt files under Application Support. Exercise save, delete, and reopen with a temporary store.
- [ ] Expose full script, cue words, and hidden-script recall. Count an explicit reveal once per activation. Ask for microphone access on first record. Denial leaves silent recall accessible. Give record, stop, reveal, and playback controls VoiceOver labels and usable layouts at accessibility text sizes.
- [ ] Use AVAudioSession and AVFoundation for recording and playback. Finalize a playable file before marking the take ready. On interruption or storage failure, preserve playable partial audio, label it interrupted, and surface a recovery action. Recover unfinished saves on relaunch. Test repeated stop and deletion so retries neither duplicate takes nor remove another take’s audio.
- [ ] Make review open from the completed take and from history. Retry starts a new attempt with the same section and cue mode. On a phone, record two takes in airplane mode, play each, interrupt a third, and confirm saved takes survive relaunch.

### 4. Deliver the first internal TestFlight build

**Files and services.** App icon assets, signing settings, Xcode Cloud workflow, and App Store Connect internal tester group. Add only reproducible release steps to AGENTS.md.

- [ ] Validate a signed Release archive with the permanent identifier, distribution team, microphone purpose string, app icon, and incremented build number. Resolve export-compliance questions according to the actual build.
- [ ] Configure a manually triggered Xcode Cloud archive workflow for approved main revisions and internal TestFlight distribution. Verify source-host access, signing, and that the intended internal tester can access the app record.
- [ ] Record build number, commit, processing status, and install confirmation separately. **Exit:** the owner can install from TestFlight on the iPhone 17, rehearse the handoff, replay a take, and retry. Upload alone leaves the install check pending.

## Milestone 2 — Contextual coaching with evidence

### 5. Produce local observations and timestamped playback

**Files.** `Spelum/Analysis/TakeTranscriber.swift`, `Spelum/Analysis/TimingObservations.swift`, TakeReview, `SpelumTests/TimingObservationsTests.swift`, and synthetic test fixtures under `SpelumTests/Fixtures/`.

- [ ] Run English SpeechAnalyzer/SpeechTranscriber on a saved audio file after recording stops. Check supported locale, assets, and availability. Preserve a ready recording when transcription is pending, declined, unsupported, interrupted, or retried.
- [ ] Associate each final recognized word or phrase with its reported audio range. For English word-level data, estimated words per minute equals recognized words × 60 / elapsed recording seconds. Only show a phrase gap when both neighboring boundaries support it. Omit unsupported observations for empty audio, overlapping ranges, paraphrases, repeats, or ambiguous alignment. Never assign a gap to a speaker solely from the transcript.
- [ ] Test a 10-second fixture with 20 recognized words (120 estimated WPM), a known 0.8-second gap, repeated product names, and a stage direction followed by silence. Use deterministic timed segments for assertions and a generated audio fixture for playback duration/seek. Check actual transcription separately with the presenter’s product name on device.
- [ ] Label estimates and measured facts at their point of use. Tapping an aligned observation seeks playback with a little lead-in. Ambiguous evidence offers manual marking and playback. Verify reanalysis replaces the earlier result for that take without adding another recording.

### 6. Compare authored cues and Apple’s on-device coaching

**Files.** `Spelum/Coaching/TechniqueLibrary.swift`, `Spelum/Coaching/SectionCoach.swift`, `SpelumTests/SectionCoachTests.swift`, `SpelumTests/Fixtures/CoachingCases.json`; integrate with PracticeView and TakeReview.

- [ ] Write an original cue library for the handoff, reveal, demo, and close. Give each technique an ID, applicable purpose, source timestamp or passage, and concrete delivery instruction. Keep guidance tied to evidence from the reference. Preserve the user’s exact script in every display.
- [ ] Implement preparation and post-take coaching as distinct requests. Inputs are selected section revision, section purpose, candidate techniques, and, for review, validated observation IDs. Request a structured result with technique ID, exact phrase, optional observation ID, and one action. Resolve IDs and verify the phrase against the source. Suggestions that fail validation revert to an authored cue.
- [ ] Check availability of Apple’s **on-device** system model. Cache accepted preparation cues by revision, technique, and prompt version; store review cues per attempt and evidence version. Allow editing or dismissal. Test unavailable model, stale cache after edits, invented quotation, absent observation, and duplicate generation requests.
- [ ] On iPhone 17, evaluate 20 cases for **each task**, spanning handoff, reveal, demo, and closing. Include paraphrases, uncertain alignment, silence, and strong takes that need no correction. Blind the source of authored and generated suggestions where practical. Count a case as useful when the presenter can identify the passage, the action, and a reason it fits, or agrees that withholding a suggestion was appropriate. Record counts, cold/warm response times, device OS, prompt version, and repeated-case variation. Keep private scripts and recordings off source control.
- [ ] **Decision per task:** ship local generation when at least 16/20 cases are useful, there are zero invented measurements, altered quotes, or unsupported speaker judgments in user-visible output, and it offers a practical benefit over authored cues. Otherwise ship the authored baseline for that task. If the remaining gap matters to the presenter, compare Gemini on the same cases with authorized inputs. Bring results to the owner before provisioning a backend or adding a network path.

## Milestone 3 — Full run and progress review

### 7. Rehearse the entire presentation and compare attempts

**Files.** `Spelum/Practice/FullRunView.swift`, `Spelum/Review/AttemptHistory.swift`, AttemptStore, TakeReview, `SpelumTests/FullRunTests.swift`.

- [ ] Reuse the section recording lifecycle for one continuous recording. Snapshot section order and speaker assignments at start. A manual advance records the elapsed audio time, section ID, and speaker; allow a solo presenter to start from the handoff. Intentional demo silence stays in the timeline.
- [ ] Test opening → reveal → demo → close, a single-section talk, early finish, and an interrupted run. Check that each valid marker seeks within the saved audio. Edits to the current script must preserve the old run’s text and order.
- [ ] Add chronological history with duration, cue reveals, practice mode, and optional timing estimates. Default comparison to two takes of the same section revision or two runs of the same talk revision and scope. Identify older revisions explicitly. The presenter can replay either recording and decide which delivery to keep.
- [ ] Deliver an internal update through the existing distribution workflow. On the iPhone 17, update over the first TestFlight build, recover its recordings, complete a timed full run, compare it with a second run, and replay the reveal. Verify Dynamic Type, VoiceOver controls, offline behavior, and deletion across app relaunch.

## Review focus and release evidence

| Failure mode | Evidence required |
| --- | --- |
| Script edited after recording | Tasks 2 and 7 preserve the original revision and speaker order on replay. |
| Microphone denied, recording interrupted, or save retried | Task 3 retains valid audio and leaves recall usable. |
| Speech engine mishears a product or a demo goes quiet | Task 5 suppresses ambiguous attribution and offers playback. |
| Model unavailable or confidently invents evidence | Task 6 validates its output, exercises the authored fallback, and records human ratings. |
| A passing build cannot be used on the owner’s phone | Tasks 4 and 7 require an actual TestFlight install and update, with recording and playback verified. |

**Owner inputs at the point of use.** Distribution requires an eligible Apple Developer team, App Store Connect access, and a tester account. Device evaluation benefits from the real English script and the presenter’s judgment. Synthetic English material can cover automated tests. Keep secrets in the appropriate credential store and keep private rehearsal material on the phone.
