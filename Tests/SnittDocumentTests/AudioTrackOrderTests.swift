// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

@Test("The captured order matches what the recorder actually writes")
func capturedOrderMatchesTheRecorder() {
    // AssetWriterSink adds inputs as [video, systemAudio, microphone], so a
    // recording's AUDIO tracks are [systemAudio, microphone]. If someone
    // reorders those `writer.add` calls, this is the test that fails —
    // otherwise the mix silently addresses the wrong track again.
    //
    // This used to assert the same of `canonical`, which was correct while the
    // two were the same list. D93's voiceover is a composition-only track the
    // recorder never writes, so they have parted: `captured` is what comes out
    // of `capture.mov`, `canonical` is what the composition's audio tracks are
    // named in order.
    #expect(AudioTrackOrder.captured == ["systemAudio", "microphone"])
}

@Test("The canonical order EXTENDS the captured one rather than reordering it")
func canonicalExtendsCaptured() {
    // The load-bearing property, and the one that makes appending safe:
    // composition audio track `i` is resolved to `canonical[i]`, and the first
    // tracks always come from the capture. A voiceover inserted anywhere but
    // the end would renumber them, so muting the microphone would silence
    // something else.
    #expect(AudioTrackOrder.canonical.starts(with: AudioTrackOrder.captured))
    #expect(AudioTrackOrder.canonical.last == "voiceover")
    // No duplicates: the mix resolves a state BY NAME, so two tracks sharing
    // one would both answer to it.
    #expect(Set(AudioTrackOrder.canonical).count == AudioTrackOrder.canonical.count)
}
