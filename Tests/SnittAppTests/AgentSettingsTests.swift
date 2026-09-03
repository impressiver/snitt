import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.test.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Agent recording is OFF for defaults that have never been written")
func agentRecordingDefaultsOff() {
    // §5.3 is a safety rule, not a preference — a default that silently reads as
    // enabled would make the opt-in decorative.
    let settings = AgentSettings.load(emptyDefaults())
    #expect(settings.agentRecordingEnabled == false)
    #expect(settings.fullDisplayAllowed == false)
}

@Test("Settings survive a save and reload")
func settingsRoundTrip() {
    let defaults = emptyDefaults()
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.save(to: defaults)

    #expect(AgentSettings.load(defaults).agentRecordingEnabled == true)
}

@Test("Enabling agent recording does NOT enable full-display recording")
func enablingAgentsDoesNotGrantDisplay() {
    // Two separate grants on purpose: agreeing to agent recording is not agreeing
    // to hand over the whole screen (§5.3).
    let defaults = emptyDefaults()
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.save(to: defaults)

    #expect(AgentSettings.load(defaults).fullDisplayAllowed == false)
}
