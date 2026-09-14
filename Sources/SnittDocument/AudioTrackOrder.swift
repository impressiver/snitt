// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

/// The order in which a recording's AUDIO tracks appear, which is the order
/// `AssetWriterSink` adds its inputs — video first, then system audio, then
/// the microphone. Only the audio entries are listed: the video track is not
/// addressable by an audio mix.
///
/// This lives in `SnittDocument` because both sides need it and neither can
/// see the other: `SnittExport` must never depend on `SnittCapture` (§4.9's
/// layering, enforced by the thin-client guard), so the exporter cannot ask
/// the recorder what it wrote.
public enum AudioTrackOrder {
    /// The two tracks `capture.mov` always carries, plus the one the editor
    /// can add afterwards.
    ///
    /// **"voiceover" is third because it is appended third**, and that is safe
    /// for a reason worth writing down rather than assuming: `AssetWriterSink`
    /// adds BOTH audio inputs unconditionally, whether or not the microphone
    /// was on, so a capture always has exactly two audio tracks and index 2 is
    /// always free. Verified against a real recording (2026-09-14) rather than
    /// inferred — if the sink ever skipped a silent mic input, a voiceover
    /// would land at index 1 and be governed by the microphone's mute and
    /// gain.
    public static let canonical = ["systemAudio", "microphone", "voiceover"]

    /// The tracks that come from `capture.mov`. Everything after these is a
    /// composition-only track the recorder never wrote.
    public static let captured = ["systemAudio", "microphone"]
}
