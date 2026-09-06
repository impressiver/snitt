import Testing
import Foundation
@testable import SnittApp

/// Captured once, before any test in this process can have written a
/// `snitt.crashreports.*.plist` — the same fixed point
/// `UpdateSettingsTests.swift`'s `EphemeralUpdateSettingsDefaults` and
/// `AppcastTests.swift`'s round-trip fixture each capture for their own
/// prefixes, so a file this process creates can never be mistaken for one
/// left behind by an earlier, killed `swift test` run.
private let crashReportSettingsProcessStartTime = Date()

/// `defer { UserDefaults().removePersistentDomain(forName:) }` alone is not
/// enough: `removePersistentDomain` empties the in-memory domain but leaves
/// a fresh, empty `.plist` behind once `cfprefsd` flushes it, so a bare
/// `defer` of that call still leaks one file per test run — the exact
/// growth `UpdateSettingsTests.swift` already found and fixed for its own
/// `snitt.updates.*` prefix. This sweeps `snitt.crashreports.*` the same
/// way, rather than repeating the half-fix.
private func sweepStaleCrashReportSettingsFiles() {
    guard let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences") else { return }
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: preferencesDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    for file in contents where file.lastPathComponent.hasPrefix("snitt.crashreports.") {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Unreadable date errs toward not deleting — a leaked 42-byte plist
        // is harmless; deleting a file a concurrently-running test in this
        // same process still owns is not.
        guard let modified, modified < crashReportSettingsProcessStartTime else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}

/// A throwaway `UserDefaults` suite plus the teardown needed to actually
/// remove its backing file, not just empty it in memory —
/// `removePersistentDomain(forName:)` alone leaves a fresh, empty plist
/// behind once `cfprefsd` flushes it, the same race
/// `EphemeralUpdateSettingsDefaults.cleanUp()` closes with `synchronize()`
/// plus a bounded delete-and-retry.
private struct EphemeralCrashReportDefaults {
    let defaults: UserDefaults
    private let suite: String

    static func make() -> EphemeralCrashReportDefaults {
        sweepStaleCrashReportSettingsFiles()
        let suite = "snitt.crashreports.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return EphemeralCrashReportDefaults(defaults: defaults, suite: suite)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        guard let preferencesURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences")
            .appendingPathComponent("\(suite).plist")
        else { return }
        for attempt in 0..<10 {
            try? FileManager.default.removeItem(at: preferencesURL)
            guard attempt < 9 else { break }
            Thread.sleep(forTimeInterval: 0.05)
            if !FileManager.default.fileExists(atPath: preferencesURL.path) {
                break
            }
        }
    }
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
    let fixture = EphemeralCrashReportDefaults.make()
    defer { fixture.cleanUp() }
    #expect(CrashReportSettings.load(fixture.defaults).enabled == false)
}

@Test("The choice survives a save and reload")
func crashReportingSettingRoundTrips() {
    let fixture = EphemeralCrashReportDefaults.make()
    defer { fixture.cleanUp() }
    var settings = CrashReportSettings.load(fixture.defaults)
    settings.enabled = true
    settings.save(to: fixture.defaults)
    #expect(CrashReportSettings.load(fixture.defaults).enabled == true)
}

@Test("A corrupt stored value reads as off, not on")
func crashReportingCorruptStoredValueReadsAsOff() {
    // `UserDefaults.bool(forKey:)` returns false both for a missing key and
    // for a value it cannot coerce to a bool. An implementation that instead
    // read `object(forKey:) as? Bool ?? true` would flip this exact case to
    // "on" — absent and invalid must both read as off, but as two different
    // kinds of not-on, never as each other and never as on.
    let fixture = EphemeralCrashReportDefaults.make()
    defer { fixture.cleanUp() }
    fixture.defaults.set(["not", "a", "bool"], forKey: "com.impressiver.snitt.crashReportingEnabled")
    #expect(CrashReportSettings.load(fixture.defaults).enabled == false)
}

@Test("A stale snitt.crashreports preference file is swept on the next fixture creation")
func staleCrashReportSettingsFileIsSwept() throws {
    // Same discriminator `UpdateSettingsTests.swift`'s
    // `staleUpdateSettingsFileIsSwept` uses for its own prefix: plant a file
    // that already matches the prefix this sweep targets, backdate it
    // before this process's own start time so it unambiguously reads as
    // "leaked by an earlier run", and confirm the very next fixture creation
    // removes it.
    guard let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences")
    else {
        Issue.record("could not resolve ~/Library/Preferences")
        return
    }
    let staleFile = preferencesDirectory
        .appendingPathComponent("snitt.crashreports.STALE-\(UUID().uuidString).plist")
    try Data("stale".utf8).write(to: staleFile)
    defer { try? FileManager.default.removeItem(at: staleFile) }

    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 0)],
        ofItemAtPath: staleFile.path
    )
    #expect(FileManager.default.fileExists(atPath: staleFile.path))

    let fixture = EphemeralCrashReportDefaults.make()
    defer { fixture.cleanUp() }

    #expect(!FileManager.default.fileExists(atPath: staleFile.path))
}
