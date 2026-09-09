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
    public static let canonical = ["systemAudio", "microphone"]
}
