import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.events.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Event logging is OFF for defaults that have never been written")
func eventLoggingDefaultsOff() {
    // §4.10's ladder reaches three dialogs only when a user asks for keystroke
    // capture. A default-on log would charge every user that prompt for a
    // feature whose only consumer ships in a later milestone.
    #expect(EventLoggingSettings.load(emptyDefaults()).enabled == false)
}

@Test("The setting survives a save and reload")
func settingRoundTrips() {
    let defaults = emptyDefaults()
    var settings = EventLoggingSettings.load(defaults)
    settings.enabled = true
    settings.save(to: defaults)
    #expect(EventLoggingSettings.load(defaults).enabled == true)
}

@Test("Input Monitoring has its own pre-explain state, independent of the others")
func inputMonitoringIsItsOwnRung() {
    // Marking screen recording explained must not consume the Input Monitoring
    // explanation — it is a different rung the user has not reached.
    let defaults = emptyDefaults()
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(PermissionOnboarding.shouldPreExplain(.inputMonitoring, defaults: defaults))
}

@Test("Every service still deep-links to a distinct Settings pane")
func inputMonitoringHasItsOwnPane() {
    let urls = PermissionOnboarding.Service.allCases.map {
        PermissionOnboarding.settingsURL(for: $0).absoluteString
    }
    #expect(Set(urls).count == urls.count,
            "a shared pane would send users to the wrong list")
    #expect(PermissionOnboarding.settingsURL(for: .inputMonitoring)
        .absoluteString.contains("ListenEvent"))
}
