import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.crashreports.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Crash reporting is OFF for defaults that have never been written")
func crashReportingDefaultsOff() {
    // §12: the maintainer's local-only design still opts a user IN to
    // reading their own machine's crash reports. A default-on setting would
    // collect before anyone asked, exactly the mistake `UpdateSettings` and
    // `EventLoggingSettings` were both written to avoid.
    //
    // Verified against the wrong implementation this guards: a `load` that
    // reads `object(forKey:) ?? true`, or an `init` whose default parameter
    // is `true`, both make this fail.
    #expect(CrashReportSettings.load(emptyDefaults()).enabled == false)
}

@Test("The choice survives a save and reload")
func crashReportingSettingRoundTrips() {
    let defaults = emptyDefaults()
    var settings = CrashReportSettings.load(defaults)
    settings.enabled = true
    settings.save(to: defaults)
    #expect(CrashReportSettings.load(defaults).enabled == true)
}

@Test("A corrupt stored value reads as off, not on")
func crashReportingCorruptStoredValueReadsAsOff() {
    // `UserDefaults.bool(forKey:)` returns false both for a missing key and
    // for a value it cannot coerce to a bool. An implementation that instead
    // read `object(forKey:) as? Bool ?? true` would flip this exact case to
    // "on" — absent and invalid must both read as off, but as two different
    // kinds of not-on, never as each other and never as on.
    let defaults = emptyDefaults()
    defaults.set(["not", "a", "bool"], forKey: "com.impressiver.snitt.crashReportingEnabled")
    #expect(CrashReportSettings.load(defaults).enabled == false)
}
