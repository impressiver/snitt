import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.onboarding.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("A service is pre-explained the first time and never again")
func preExplainHappensOnce() {
    // §4.10: the sheet exists so the system dialog is expected. Showing it on
    // every recording would be nagging, which is the thing it prevents.
    let defaults = emptyDefaults()
    #expect(PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults))
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(!PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults))
}

@Test("Services are tracked independently")
func servicesAreIndependent() {
    // Marking screen recording explained must not silently consume the
    // microphone's first-run explanation — that is the second rung of §4.10's
    // ladder and the user has not seen it yet.
    let defaults = emptyDefaults()
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(PermissionOnboarding.shouldPreExplain(.microphone, defaults: defaults))
}

@Test("Every service deep-links to a distinct Settings pane")
func everyServiceHasADistinctSettingsPane() {
    let urls = PermissionOnboarding.Service.allCases.map {
        PermissionOnboarding.settingsURL(for: $0).absoluteString
    }
    #expect(urls.allSatisfy { $0.hasPrefix("x-apple.systempreferences:") })
    #expect(Set(urls).count == urls.count, "a shared pane would send users to the wrong list")
}
