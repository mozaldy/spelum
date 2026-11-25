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
}
