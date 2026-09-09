// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import Testing
@testable import SnittApp
@testable import SnittCapture

/// The speaker-bleed warning shown in the status menu (D73).
///
/// The menu item itself is untestable AppKit; the decision of whether to warn
/// is not, which is why it lives in `speakerBleedWarning` rather than inline
/// in `showContextMenu`.
@Suite
struct SpeakerBleedWarningTests {

    @Test("Speakers plus a voiceover earns a warning")
    func warnsOnBuiltInSpeakers() throws {
        let warning = try #require(StatusItemController.speakerBleedWarning(
            route: .builtInSpeakers, microphoneEnabled: true))
        // The advice has to be IN it. "Audio problem detected" tells someone
        // there is a problem and leaves them with it; the entire fix is one
        // word and it needs to be present.
        #expect(warning.localizedCaseInsensitiveContains("headphones"))
    }

    @Test("Headphones earn no warning")
    func silentOnHeadphones() {
        #expect(StatusItemController.speakerBleedWarning(
            route: .headphones, microphoneEnabled: true) == nil)
    }

    @Test("No voiceover, no warning")
    func silentWithoutTheMicrophone() {
        // System audio alone has nothing to bleed into. Warning here would put
        // a permanent scare in the menu of anyone recording a silent screencast
        // on a laptop, which is the default configuration.
        #expect(StatusItemController.speakerBleedWarning(
            route: .builtInSpeakers, microphoneEnabled: false) == nil)
    }

    @Test("An unidentified route earns no warning")
    func silentOnUnknownRoutes() {
        for route in [AudioOutputRoute.unknown, .external] {
            #expect(StatusItemController.speakerBleedWarning(
                route: route, microphoneEnabled: true) == nil, "\(route)")
        }
    }

    @Test("The warning tracks whether system audio is actually captured")
    func followsTheCaptureDefault() {
        // Not an assertion about today's default so much as a tripwire: the
        // warning reads `CaptureOptions().captureSystemAudio` rather than a
        // literal `true`, so if system audio ever becomes opt-in this test
        // fails and says so, instead of the menu quietly warning about bleed
        // from audio nobody is recording.
        #expect(CaptureOptions().captureSystemAudio,
                "system audio is no longer captured by default — speakerBleedWarning needs the real flag threaded through, not CaptureOptions()'s default")
    }
}
