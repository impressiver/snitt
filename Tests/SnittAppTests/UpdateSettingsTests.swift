// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// Captured once, before any test in this process can have written a
/// `snitt.updates.*.plist` — the same fixed point
/// `UpdaterControllerTests.swift`'s `SparkleFixture` and
/// `AppcastTests.swift`'s round-trip fixture each capture for their own
/// prefixes, so a file this process creates can never be mistaken for one
/// left behind by an earlier, killed `swift test` run.
private let updateSettingsProcessStartTime = Date()

/// R43 (whole-branch-review.md, M2): this milestone built two sweeps
/// (`sweepStaleFixtureFiles()`, `sweepStaleAppcastFixtureFiles()`) to
/// bound a 1–2-file residual per prefix, then added a THIRD
/// `UserDefaults(suiteName:)` accumulator here — `snitt.updates.*` — with
/// no sweep at all. Two of this file's three tests persist a value
/// (`updateSettingsRoundTrip` via `.save(to:)`, `corruptStoredValueReadsAsOff`
/// via `.set(...)`), so every run left +2 files in
/// `~/Library/Preferences`, unbounded, exactly the growth the other two
/// sweeps exist to prevent. This is the same mechanism as those two,
/// retargeted at this prefix.
private func sweepStaleUpdateSettingsFiles() {
    guard let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences") else { return }
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: preferencesDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    for file in contents where file.lastPathComponent.hasPrefix("snitt.updates.") {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Unreadable date errs toward not deleting — same asymmetry as the
        // other two sweeps: a leaked 42-byte plist is harmless, deleting a
        // file a concurrently-running test in this same process still owns
        // is not.
        guard let modified, modified < updateSettingsProcessStartTime else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}

/// A throwaway `UserDefaults` suite plus the teardown needed to actually
/// remove its backing file, not just empty it in memory —
/// `removePersistentDomain(forName:)` alone leaves a fresh, empty plist
/// behind once `cfprefsd` flushes it (the same race `SparkleFixture.cleanUp()`
/// and `cleanUpRoundTripFixture()` both close with `synchronize()` plus a
/// bounded delete-and-retry).
private struct EphemeralUpdateSettingsDefaults {
    let defaults: UserDefaults
    private let suite: String

    static func make() -> EphemeralUpdateSettingsDefaults {
        sweepStaleUpdateSettingsFiles()
        let suite = "snitt.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return EphemeralUpdateSettingsDefaults(defaults: defaults, suite: suite)
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

@Test("Automatic checks are off until someone turns them on")
func automaticChecksDefaultOff() {
    let fixture = EphemeralUpdateSettingsDefaults.make()
    defer { fixture.cleanUp() }
    // An update check tells a server this machine runs Snitt, at a moment
    // the user did not pick. Defaulting it on would be a decision made for
    // them (§5), and `EventLoggingSettings` sets the precedent.
    #expect(UpdateSettings.load(fixture.defaults).automaticChecksEnabled == false)
}

@Test("The choice survives a round trip")
func updateSettingsRoundTrip() {
    let fixture = EphemeralUpdateSettingsDefaults.make()
    defer { fixture.cleanUp() }
    UpdateSettings(automaticChecksEnabled: true).save(to: fixture.defaults)
    #expect(UpdateSettings.load(fixture.defaults).automaticChecksEnabled)
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
    let fixture = EphemeralUpdateSettingsDefaults.make()
    defer { fixture.cleanUp() }
    fixture.defaults.set(["not", "a", "bool"], forKey: "com.impressiver.snitt.updateAutomaticChecksEnabled")
    #expect(UpdateSettings.load(fixture.defaults).automaticChecksEnabled == false)
}

@Test("A stale snitt.updates preference file is swept on the next fixture creation")
func staleUpdateSettingsFileIsSwept() throws {
    // Same discriminator R33's `staleAppcastFixtureFileIsSwept` uses for
    // its own prefix: plant a file that already matches the prefix this
    // sweep targets, backdate it before this process's own start time so
    // it unambiguously reads as "leaked by an earlier run", and confirm
    // the very next fixture creation removes it. Verified this fails
    // against the wrong implementation it exists to catch: commenting out
    // the `sweepStaleUpdateSettingsFiles()` call inside
    // `EphemeralUpdateSettingsDefaults.make()` left the planted file in
    // place after `make()` ran, exactly what this asserts against.
    guard let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences")
    else {
        Issue.record("could not resolve ~/Library/Preferences")
        return
    }
    let staleFile = preferencesDirectory
        .appendingPathComponent("snitt.updates.STALE-\(UUID().uuidString).plist")
    try Data("stale".utf8).write(to: staleFile)
    defer { try? FileManager.default.removeItem(at: staleFile) }

    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 0)],
        ofItemAtPath: staleFile.path
    )
    #expect(FileManager.default.fileExists(atPath: staleFile.path))

    let fixture = EphemeralUpdateSettingsDefaults.make()
    defer { fixture.cleanUp() }

    #expect(!FileManager.default.fileExists(atPath: staleFile.path))
}
