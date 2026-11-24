# Spelum Contributor Guide

Spelum is an English-language native iPhone rehearsal app built with SwiftUI, SwiftData, AVFoundation, Apple Speech, and Apple's on-device Foundation Models. Read the [MVP design](docs/superpowers/specs/2026-11-25-spelum-mvp-design.md) and [MVP implementation plan](docs/superpowers/plans/2026-11-25-spelum-mvp.md) before making changes.

## Project Layout

- `Spelum/` — iPhone app target (`MyApp.swift`, `ContentView.swift`, `Assets.xcassets/`). Feature modules belong under `Spelum/Library/`, `Spelum/Practice/`, `Spelum/Review/`, `Spelum/Analysis/`, and `Spelum/Coaching/`.
- `SpelumTests/` — Hosted unit-test target (`AppConfigurationTests.swift` and future test suites/synthetic fixtures).
- `Spelum.xcodeproj/` — Xcode 27 JSON project (`project.xcproj`) and shared scheme (`xcshareddata/xcschemes/MyApp.xcscheme`). Keep the shared scheme name `MyApp` through this MVP.
- `.swiftlint.yml` — Strict SwiftLint configuration covering `Spelum` and `SpelumTests`.
- `scripts/install-swiftlint.sh` — Reproducible SHA-256-verified installer for the pinned SwiftLint binary.
- `.github/workflows/ios.yml` — GitHub Actions CI defining the `SwiftLint` and `iOS build and tests` PR checks.
- `docs/superpowers/` — Approved design specification and implementation plan.

## Toolchain and Project Format

- **Target platform:** iPhone only (`TARGETED_DEVICE_FAMILY = 1`), minimum iOS `27.0`.
- **Xcode:** Xcode `27.2` (verified on build `27B52`, Swift `6.4.2`).
- **Project format:** `Spelum.xcodeproj/project.xcproj` uses Xcode 27's JSON `.xcproj` format (requires Xcode 27.0 or later). Edit project structure/settings with `xcrun xcodeproj` and normalize formatting with `xcrun xcprojformatter --update Spelum.xcodeproj`.
- **CI runner:** GitHub-hosted `xcode-27` (`arm64`, macOS 27), requiring `/Applications/Xcode_27.2.app/Contents/Developer`.
- **Dependencies:** Prefer Apple first-party frameworks and Swift Testing / XCTest. The only required development tool outside Xcode is pinned SwiftLint.

## Pinned SwiftLint

- **Version:** `0.65.1` (`realm/SwiftLint` release `portable_swiftlint.zip`)
- **SHA-256:** `c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0`
- **Install:**
  ```sh
  ./scripts/install-swiftlint.sh
  ```
  By default this installs to `${HOME}/.local/bin/swiftlint` (pass a custom directory as the first argument if needed). Ensure `${HOME}/.local/bin` is on your `PATH`.
- **Verify version and lint:**
  ```sh
  swiftlint version
  swiftlint lint --strict --config .swiftlint.yml
  ```

## Verification Commands

Run targeted regressions first during development using `-only-testing:SpelumTests/<TestSuiteName>`, then run the full verification suite:

```sh
xcodebuild -list -project Spelum.xcodeproj
swiftlint lint --strict --config .swiftlint.yml
xcodebuild test -project Spelum.xcodeproj -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
xcodebuild build -project Spelum.xcodeproj -scheme MyApp -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

CI runs these checks under two named jobs:
- `SwiftLint`
- `iOS build and tests`

## UI and Apple HIG Conventions

- **Native SwiftUI first:** Build every screen with native SwiftUI, adhering to the [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/).
- **Stock controls wherever possible:** Prefer standard iOS components and system behaviors (`NavigationStack`, `List`, `TextEditor`, toolbars, system file importer, sheets, destructive confirmations, SF Symbols, system text styles, semantic colors, safe areas, and standard back navigation).
- **Justify custom controls:** Only introduce a custom rehearsal control when stock controls cannot support the interaction cleanly. State the interaction that justifies it and preserve its accessible label, value/state, hit target, and system interaction behavior.
- **Accessibility and appearance evidence:** For every UI change, verify and report light and dark appearance, accessibility Dynamic Type sizes, and VoiceOver labels and navigation order.

## Local Data and Privacy Boundary

- Keep user rehearsal scripts, audio takes, transcripts, and evaluation notes strictly local on-device (application container / Application Support) and offline-capable. Saving and replaying a take must succeed even if Apple Speech or on-device Foundation Models are unavailable.
- **Never commit** private scripts, personal audio recordings, presenter names, Apple IDs, email addresses, API keys, certificates, or provisioning credentials to the repository.
- Use synthetic English fixtures only for automated tests under `SpelumTests/`.
- Store any credentials or secrets in the appropriate credential store rather than source control.

## Reporting Simulator vs. Physical Phone Results

Always report **Simulator** and **Physical iPhone** verification separately, and include the resolved Xcode version/build and iOS runtime/OS version:

- **Simulator checks** cover buildability, unit/integration logic, bundle configuration, layout/accessibility inspection, and synthetic fixture tests (`iPhone 17`, iOS `27.0` or available `27.x` simulator).
- **Physical iPhone checks** are required for microphone/audio session hardware behavior, airplane-mode offline recording/playback/interruption recovery, on-device Speech transcription against real product names, on-device Foundation Models 20-case evaluations, and TestFlight install/update verification.
- Never report a simulator pass as proof of physical device or distribution readiness. Explicitly list unexecuted device or Apple account checks as pending owner/device verification.

## Distribution Dependencies

Local simulator testing and unsigned Release builds (`CODE_SIGNING_ALLOWED=NO`) work without distribution credentials. Signed archives, App Store Connect records, and TestFlight distribution remain separate account-owner dependencies requiring:
- A confirmed paid Apple Developer Program distribution team.
- A permanent bundle identifier registered consistently for signing and App Store Connect (replacing the placeholder identifier before Milestone 1 Task 4).
- App Store Connect / Xcode Cloud access and an internal tester account.
