import Foundation
import Testing
@testable import Spelum

@Suite("App Configuration")
struct AppConfigurationTests {
    @Test("App bundle targets minimum iOS 27.0")
    func minimumOSVersionIs27Point0() {
        let minimumOSVersion = Bundle.main.infoDictionary?["MinimumOSVersion"] as? String
        #expect(minimumOSVersion == "27.0")
    }

    @Test("App bundle targets iPhone only")
    func appTargetsIPhoneOnly() {
        let deviceFamilies = Bundle.main.infoDictionary?["UIDeviceFamily"] as? [Int]
        #expect(deviceFamilies == [1])
    }

    @Test("Tests run hosted inside Spelum.app")
    func hostedInSpelumAppBundle() {
        let executableName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
        #expect(executableName == "Spelum")
    }

    @Test("App bundle includes a microphone purpose string for offline rehearsal")
    func microphoneUsageDescriptionIsConfigured() {
        let purpose = Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] as? String
        let trimmed = purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(!trimmed.isEmpty)
    }

    @Test("App bundle uses the owner-confirmed permanent bundle identifier")
    func bundleIdentifierMatchesPermanentAppID() {
        #expect(Bundle.main.bundleIdentifier == "com.rizaldyramadhan.Spelum")
    }

    @Test("App bundle configures the primary AppIcon asset metadata")
    func appIconIsConfiguredInBundle() {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconName = primaryIcon?["CFBundleIconName"] as? String
        let iconFiles = primaryIcon?["CFBundleIconFiles"] as? [String] ?? []
        #expect(iconName == "AppIcon")
        #expect(!iconFiles.isEmpty)
    }

    @Test("App bundle has a marketing version and an incremented integer build number")
    func marketingAndBuildVersionsAreReleaseReady() {
        let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let trimmedMarketing = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(!trimmedMarketing.isEmpty)

        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let isPureInteger = !buildVersion.isEmpty && buildVersion.allSatisfy { $0.isASCII && $0.isNumber }
        #expect(isPureInteger)
        #expect((Int(buildVersion) ?? 0) >= 2)
    }

    @Test("App bundle declares no non-exempt encryption for this offline-only release")
    func exportComplianceDeclaresNoNonExemptEncryption() {
        let usesNonExemptEncryption = Bundle.main.infoDictionary?["ITSAppUsesNonExemptEncryption"] as? Bool
        #expect(usesNonExemptEncryption == false)
    }
}
