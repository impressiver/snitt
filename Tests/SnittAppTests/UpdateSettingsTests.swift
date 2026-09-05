import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.updates.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Automatic checks are off until someone turns them on")
func automaticChecksDefaultOff() {
    let defaults = emptyDefaults()
    // An update check tells a server this machine runs Snitt, at a moment
    // the user did not pick. Defaulting it on would be a decision made for
    // them (§5), and `EventLoggingSettings` sets the precedent.
    #expect(UpdateSettings.load(defaults).automaticChecksEnabled == false)
}

@Test("The choice survives a round trip")
func updateSettingsRoundTrip() {
    let defaults = emptyDefaults()
    UpdateSettings(automaticChecksEnabled: true).save(to: defaults)
    #expect(UpdateSettings.load(defaults).automaticChecksEnabled)
}

@Test("A corrupt stored value reads as off, not on")
func corruptStoredValueReadsAsOff() {
    // `UserDefaults.bool(forKey:)` returns false both for a missing key and
    // for a value it cannot coerce to a bool — that's what keeps a garbage
    // stored type from reading as enabled. An implementation that instead
    // read `object(forKey:) as? Bool ?? true` would flip this exact case to
    // "on": this project has been bitten three times by that shape of
    // silent coercion, and absent/invalid are supposed to be indistinguishable
    // from "off" here, not from each other.
    let defaults = emptyDefaults()
    defaults.set(["not", "a", "bool"], forKey: "com.impressiver.snitt.updateAutomaticChecksEnabled")
    #expect(UpdateSettings.load(defaults).automaticChecksEnabled == false)
}
