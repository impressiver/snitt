// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

@Test("The canonical order matches what the recorder actually writes")
func canonicalOrderMatchesTheRecorder() {
    // AssetWriterSink adds inputs as [video, systemAudio, microphone], so a
    // recording's AUDIO tracks are [systemAudio, microphone]. If someone
    // reorders those `writer.add` calls, this is the test that fails —
    // otherwise the mix silently addresses the wrong track again.
    #expect(AudioTrackOrder.canonical == ["systemAudio", "microphone"])
}
