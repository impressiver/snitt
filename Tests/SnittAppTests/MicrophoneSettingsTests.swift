// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.microphone.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Microphone capture is OFF for defaults that have never been written")
func microphoneDefaultsOff() {
    // §4.10's ladder reaches two dialogs only when a user asks for voiceover.
    // A default-on microphone would charge every user that second prompt on
    // their very first recording.
    #expect(MicrophoneSettings.load(emptyDefaults()).enabled == false)
}

@Test("The microphone setting survives a save and reload")
func microphoneSettingRoundTrips() {
    let defaults = emptyDefaults()
    var settings = MicrophoneSettings.load(defaults)
    settings.enabled = true
    settings.save(to: defaults)
    #expect(MicrophoneSettings.load(defaults).enabled == true)
}

@Test("A corrupt stored value reads as off, not on")
func microphoneCorruptValueReadsAsOff() {
    let defaults = emptyDefaults()
    // Absent and invalid are DIFFERENT states, and both are not-on — the
    // same rule `EventLoggingSettingsTests.corruptValueReadsAsOff` pins for
    // its own key.
    defaults.set("yes please", forKey: "com.impressiver.snitt.microphoneEnabled")
    #expect(MicrophoneSettings.load(defaults).enabled == false)
}

@Test("Microphone has its own pre-explain state, independent of the others")
func microphoneIsItsOwnRung() {
    // Marking Input Monitoring explained must not consume the Microphone
    // explanation — it is a different rung the user has not reached.
    let defaults = emptyDefaults()
    PermissionOnboarding.markPreExplained(.inputMonitoring, defaults: defaults)
    #expect(PermissionOnboarding.shouldPreExplain(.microphone, defaults: defaults))
}
