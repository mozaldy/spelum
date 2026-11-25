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

## Internal TestFlight Release

Local simulator testing and unsigned Release builds (`CODE_SIGNING_ALLOWED=NO`) work without distribution credentials. Signed archives and internal TestFlight releases use the owner-confirmed configuration below; all App Store Connect, Xcode Cloud, and physical-device checks must be reported separately from simulator and local-export results.

### Repository-Side Release Configuration

- **Signing & identity:** `DEVELOPMENT_TEAM = DFUYA8Z9D5`, `CODE_SIGN_STYLE = Automatic`, `PRODUCT_BUNDLE_IDENTIFIER = com.rizaldyramadhan.Spelum`, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`, `TARGETED_DEVICE_FAMILY = 1` (iPhone only).
- **App icon:** `Spelum/Assets.xcassets/AppIcon.appiconset` (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, single-size 1024×1024 universal iOS assets for Default/Any, Dark, and Tinted).
- **Microphone purpose string:** `INFOPLIST_KEY_NSMicrophoneUsageDescription` in `Spelum.xcodeproj/project.xcproj`.
- **Export compliance:** `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` (`ITSAppUsesNonExemptEncryption = false` in generated `Info.plist`). Verified for Milestone 1 against the actual codebase and dependencies: Spelum links only Apple first-party frameworks (`SwiftUI`, `SwiftData`, `AVFoundation`, `Foundation`, `Observation`, `UIKit`, `UniformTypeIdentifiers`), contains no third-party packages, performs no networking, and uses no custom or non-exempt encryption. Re-evaluate this setting before shipping if a future milestone adds networking, a backend, or cryptographic libraries.
- **Build numbering:** `GENERATE_INFOPLIST_FILE = YES` populates `CFBundleVersion` from `$(CURRENT_PROJECT_VERSION)` (plain integer, incremented from `1` to `2` for `MARKETING_VERSION = 1.0`). Keep `CURRENT_PROJECT_VERSION` a plain integer and do not hardcode `CFBundleVersion` or add custom build scripts that conflict with Xcode Cloud's managed build counter.

### Local Signed Archive and Export Dry Run (No Upload)

Run signed archive and App Store Connect export validation strictly to paths **outside** the repository, using `destination = export` (never `upload` during local verification):

```sh
RELEASE_DIR="/tmp/spelum-release-check"
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

xcodebuild archive \
  -project Spelum.xcodeproj \
  -scheme MyApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "${RELEASE_DIR}/Spelum.xcarchive" \
  -allowProvisioningUpdates

cat > "${RELEASE_DIR}/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>DFUYA8Z9D5</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "${RELEASE_DIR}/Spelum.xcarchive" \
  -exportPath "${RELEASE_DIR}/export" \
  -exportOptionsPlist "${RELEASE_DIR}/ExportOptions.plist" \
  -allowProvisioningUpdates
```

Inspect both the `.xcarchive` and the extracted `.ipa` payload before trusting a release candidate:

```sh
plutil -p "${RELEASE_DIR}/Spelum.xcarchive/Products/Applications/Spelum.app/Info.plist"
codesign -dvv "${RELEASE_DIR}/Spelum.xcarchive/Products/Applications/Spelum.app"
unzip -q "${RELEASE_DIR}/export/Spelum.ipa" -d "${RELEASE_DIR}/ipa-inspect"
plutil -p "${RELEASE_DIR}/ipa-inspect/Payload/Spelum.app/Info.plist"
codesign -dvv "${RELEASE_DIR}/ipa-inspect/Payload/Spelum.app"
security cms -D -i "${RELEASE_DIR}/ipa-inspect/Payload/Spelum.app/embedded.mobileprovision" | plutil -p -
```

Confirm:
- `CFBundleIdentifier == com.rizaldyramadhan.Spelum`, `MinimumOSVersion == 27.0`, `UIDeviceFamily == [1]`.
- `NSMicrophoneUsageDescription` is non-empty and `ITSAppUsesNonExemptEncryption == false`.
- `CFBundleShortVersionString` and integer `CFBundleVersion` match the expected release.
- `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName == AppIcon`, `CFBundleIconFiles` is populated, and `Assets.car` / compiled icon files exist inside `Spelum.app`.
- Exported IPA signing uses an `Apple Distribution` certificate for team `DFUYA8Z9D5` and an App Store distribution provisioning profile.

### Account-Side Xcode Cloud & TestFlight Workflow (Owner Portal Steps)

The following steps live in App Store Connect / Xcode Cloud and must be configured and verified directly by the account owner (treat each item as pending until explicitly verified in the portal):

1. **App record & internal tester access:** Confirm the App Store Connect app record for `com.rizaldyramadhan.Spelum` (team `DFUYA8Z9D5`) exists, and add the intended internal tester account to an **Internal Testing** group in **App Store Connect → TestFlight** with access to the app record.
2. **Source-host & signing access:** Connect Xcode Cloud to the GitHub repository with read access to `main` and automatic signing for team `DFUYA8Z9D5`.
3. **Cloud build numbering:** Xcode Cloud assigns its own monotonically increasing integer `CI_BUILD_NUMBER` at archive/export time and overrides `CURRENT_PROJECT_VERSION` for cloud distributions. Before the first cloud TestFlight build (and after any local upload on the same `MARKETING_VERSION`), set **App Store Connect → Spelum → Xcode Cloud → Settings → Build Number → Next Build Number** to an integer strictly greater than any build already uploaded for `1.0` (at least `2` if no build `1` exists yet, or `highestUploadedBuild + 1`). Prefer Xcode Cloud as the single upload pipeline per marketing version to avoid `ITMS-90189` duplicate-build conflicts.
4. **Manual Xcode Cloud archive workflow:** Create a workflow configured for manual dispatch only:
   - **Start condition:** None / manual start only (do not auto-distribute every push).
   - **Environment:** Xcode `27.2` (or matching verified `27.x` toolchain) on a compatible macOS image.
   - **Action:** `Archive - iOS` with scheme `MyApp` and **Deployment Preparation** set to **TestFlight (Internal Testing Only)**.
   - **Post-Action:** `TestFlight Internal Testing` delivering to the internal tester group.

### Repeatable Internal Release Checklist

1. **Select an approved `main` revision:** Confirm the target commit is merged to `main` and both required PR checks (`SwiftLint` and `iOS build and tests`) succeeded on that commit SHA.
2. **Start the manual Xcode Cloud build:** In **App Store Connect → Spelum → Xcode Cloud** (or Xcode), open the manual internal TestFlight workflow, start a build targeting `main`, and verify the run checks out the approved commit SHA.
3. **Verify build processing independently:** In **App Store Connect → TestFlight → Builds**, confirm the build completes processing, clears export compliance automatically (`ITSAppUsesNonExemptEncryption = false`), and reaches **Ready to Test** for the internal group. Record the **commit SHA**, **marketing version**, **cloud build number**, and **processing status**.
4. **Verify physical iPhone 17 install independently:** Install or update the build from the TestFlight app on the owner's iPhone 17, then rehearse a handoff, record and replay a take, and retry. Upload or App Store Connect processing alone leaves the install check pending.
