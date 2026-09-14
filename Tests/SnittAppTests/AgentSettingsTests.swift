// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp
import SnittAutomation

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

// MARK: - D95: the unattended grant

@Test("Unattended recording is OFF, and unconfirmed, for defaults never written")
func unattendedDefaultsOff() {
    let settings = AgentSettings.load(emptyDefaults())
    #expect(settings.unattendedRecordingEnabled == false)
    #expect(settings.unattendedConfirmedAt == nil)
    #expect(settings.unattendedGrant.status(now: Date()) == .off)
}

@Test("An absent confirmation reads as absent, not as 1970")
func missingConfirmationIsNilNotEpoch() {
    // The defect this guards is one character wide: `defaults.double(forKey:)`
    // returns 0 for a missing key, and 0 as a time interval is 1 January 1970 —
    // which `status` would classify as `.lapsed(daysAgo: 20000)`. "Renewal
    // overdue by twenty thousand days" and "you have never turned this on" are
    // different sentences, and only one of them is true on a fresh install.
    let defaults = emptyDefaults()
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.unattendedRecordingEnabled = true
    settings.save(to: defaults)

    let reloaded = AgentSettings.load(defaults)
    #expect(reloaded.unattendedConfirmedAt == nil)
    #expect(reloaded.unattendedGrant.status(now: Date()) == .off)
}

@Test("The confirmation date survives a save and reload")
func unattendedRoundTrip() {
    let defaults = emptyDefaults()
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.unattendedRecordingEnabled = true
    settings.unattendedConfirmedAt = when
    settings.save(to: defaults)

    let reloaded = AgentSettings.load(defaults)
    #expect(reloaded.unattendedConfirmedAt == when)
    #expect(reloaded.unattendedGrant.status(now: when)
            == .active(daysRemaining: UnattendedRecordingGrant.renewalDays))
}

@Test("Clearing the confirmation REMOVES the stored date")
func clearingConfirmationRemovesTheDate() {
    // Writing the flag false while leaving the date behind would let the next
    // enable inherit the previous window instead of buying a new one — the
    // renewal would appear to have happened without anyone confirming it.
    let defaults = emptyDefaults()
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.unattendedRecordingEnabled = true
    settings.unattendedConfirmedAt = Date(timeIntervalSince1970: 1_700_000_000)
    settings.save(to: defaults)

    settings.unattendedRecordingEnabled = false
    settings.unattendedConfirmedAt = nil
    settings.save(to: defaults)

    #expect(AgentSettings.load(defaults).unattendedConfirmedAt == nil)
    // Asserted on the STORE, not just the reloaded struct: a `save` that wrote
    // some placeholder instead of removing the key would still decode to nil
    // through `as? Date` and this test would pass on the wrong implementation.
    #expect(defaults.object(forKey: "com.impressiver.snitt.unattendedRecordingConfirmedAt") == nil)
}

@Test("Enabling agent recording does NOT enable unattended recording")
func enablingAgentsDoesNotGrantUnattended() {
    // The same separation `enablingAgentsDoesNotGrantDisplay` pins for
    // full-display, for the same §5.3 reason: agreeing that agents may record
    // is not agreeing that they may do it while you are out of the building.
    let defaults = emptyDefaults()
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.save(to: defaults)

    #expect(AgentSettings.load(defaults).unattendedRecordingEnabled == false)
}
