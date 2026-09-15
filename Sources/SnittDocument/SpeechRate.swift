// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// How long text takes to get through.
///
/// In `SnittDocument` because three layers need it and they cannot all see
/// each other: `WebVTTSubtitles` and `SubtitleCues` size captions with it, and
/// `AuthoredNarration` times a written line with it. `SnittExport` may depend
/// on this module and not the reverse, so a constant declared up there was
/// unreachable from here — the same shape that put `TranscriptParagraphs`'
/// `breakSeconds` in this module and had the caption grouper read it.
///
/// One number, for the usual reason: two reading speeds means a caption that
/// is on screen for a length its own text was never measured against.
public enum SpeechRate {
    /// Reading speed, in words per second.
    ///
    /// ~3.3 w/s is around 200 wpm, a common subtitle-industry comfortable
    /// reading rate. Not tuned against this project's own recordings yet —
    /// D57's "subtitles need reading time" criterion will want the same number,
    /// so when one of them is measured the other should move with it.
    ///
    /// Doing double duty for authored narration is a real assumption and not
    /// merely a reuse: a written line is TIMED as though it will be spoken at
    /// reading speed, which is a guess a synthesiser will replace with the
    /// durations it actually produces. Until then it is the guess least likely
    /// to surprise, because the caption is on screen for exactly as long as it
    /// takes to read.
    public static let wordsPerSecond = 3.3
}
