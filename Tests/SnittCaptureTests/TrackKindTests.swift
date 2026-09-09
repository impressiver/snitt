// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import ScreenCaptureKit
@testable import SnittCapture

@Test("Every SCStreamOutputType maps to the expected track")
func mapsOutputTypes() {
    #expect(TrackKind(.screen) == .video)
    #expect(TrackKind(.audio) == .systemAudio)
    #expect(TrackKind(.microphone) == .microphone)
}

@Test("All three tracks are enumerable")
func allTracksEnumerable() {
    #expect(TrackKind.allCases.count == 3)
    #expect(Set(TrackKind.allCases.map(\.rawValue))
            == ["video", "systemAudio", "microphone"])
}
