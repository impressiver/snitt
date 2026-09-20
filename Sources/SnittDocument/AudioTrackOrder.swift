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

    /// The audio tracks this recording actually HAS, in canonical order
    /// (D110).
    ///
    /// Track presence alone cannot answer this and never could:
    /// `EditDecisionList.fullRange()` writes a `TrackState` for both audio
    /// sources, and `Recorder` writes it at `start()` — before one sample has
    /// arrived. So a recording made with the microphone switched off carried a
    /// microphone state exactly like one made with it on, and the editor drew
    /// an empty lane that was indistinguishable from a lane of silence.
    ///
    /// **`CaptureHealth`'s `nil` is the evidence, and `nil` is the whole
    /// mechanism.** `CaptureSession.start()` adds the `.microphone` and
    /// `.audio` stream outputs only when each option is on, so a source that
    /// was never enabled delivers no buffers, `HealthSampler` counts no
    /// samples, and its RMS is `nil`. A source that WAS enabled has an RMS,
    /// which may be zero. Those are different facts about different
    /// recordings, and this turns on exactly that difference.
    ///
    /// **A track is dropped only when it was never captured.** Not when it was
    /// quiet: a live microphone in a room has a noise floor, so any loudness
    /// threshold would collapse the lane of a microphone that worked, and the
    /// person who switched it on could not tell that from having left it off.
    /// A microphone that WAS on and recorded pure digital silence keeps its
    /// lane for the same reason from the other side — a muted or dead input
    /// device is the thing that lane most needs to be able to report.
    ///
    /// Not an equality test against zero, either. Digital silence surviving a
    /// float conversion is not reliably bit-exact, so `== 0` would hide some
    /// silent recordings and not others.
    ///
    /// - Parameters:
    ///   - states: the document's own track states. Still required: the
    ///     gutter's mute and gain controls and the export mix both address
    ///     these, so a lane with no state behind it would be wired to nothing.
    ///   - health: `nil` for a bundle written before `CaptureHealth` existed
    ///     and for an imported video, and then every present track is kept.
    ///     Absent evidence is not evidence of absence, and reading it the
    ///     other way would empty the lanes of every older recording.
    ///   - overdubbed: whether a take covers the microphone, or one is being
    ///     recorded right now. A take lands on the microphone track (D102),
    ///     and `meta.json` is written once at capture — so no health will ever
    ///     mention audio the editor added afterwards.
    public static func recorded(in states: [TrackState],
                                health: CaptureHealth?,
                                overdubbed: Bool) -> [String] {
        let present = canonical.filter { name in states.contains { $0.track == name } }
        guard let health else { return present }
        return present.filter { name in
            if name == "microphone" && overdubbed { return true }
            // A track this type has no measurement for — `voiceover`, which
            // the recorder never writes — is kept rather than hidden for want
            // of a number that cannot exist.
            return health.captured(name) ?? true
        }
    }
}

extension CaptureHealth {
    /// Whether `track` was captured at all: its stream output existed and
    /// delivered at least one buffer.
    ///
    /// `nil` for a track this type carries no measurement for, which is a
    /// different answer from `false` and must not be collapsed into one — see
    /// `AudioTrackOrder.recorded(in:health:overdubbed:)`, which keeps a track
    /// it cannot measure.
    public func captured(_ track: String) -> Bool? {
        switch track {
        case "microphone": return micRMS != nil
        case "systemAudio": return systemAudioRMS != nil
        default: return nil
        }
    }
}
