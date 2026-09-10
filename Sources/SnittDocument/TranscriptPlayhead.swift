// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Which transcript word the playhead is inside.
///
/// The join between two clocks again, and the same one that has bitten this
/// project before: transcript words are in SOURCE time (facts about
/// `capture.mov`), while the playhead is in OUTPUT time, because the preview
/// plays the trimmed composition. A recording with a cut before the playhead
/// makes those numbers differ by the length of everything removed.
///
/// Pure, so the mapping is testable without a player, an asset, or a decoded
/// frame — the same split as `TimelineSampleIndex`, which solves the identical
/// problem for waveform buckets.
public enum TranscriptPlayhead {
    /// The word being spoken at `outputSeconds`, or nil.
    ///
    /// Nil is a real answer, not a failure. Between utterances there is silence
    /// that belongs to no word, and holding the previous word lit through it
    /// would claim someone is still saying it. Within an utterance the
    /// recognizer's spans are contiguous, so there is nothing to flicker
    /// against — a word gives way directly to its successor.
    ///
    /// A word inside a cut can never be current, which falls out rather than
    /// being special-cased: output time maps only into kept ranges, so the
    /// playhead cannot land on removed footage.
    public static func currentWordID(outputSeconds: Double,
                                     words: [TranscriptWord],
                                     keptRanges: [TimeRange]) -> UUID? {
        guard !words.isEmpty else { return nil }
        guard let source = TimeRangeMapping.sourceTime(ofTrimmedTime: outputSeconds,
                                                       keptRanges: keptRanges) else { return nil }
        // The LAST word whose start the playhead has reached, not the first
        // one it falls inside. Inside the tolerance window two contiguous
        // words both match — the one ending there and the one starting there
        // — and the later one is the one being asked about. `first` returns
        // the earlier, which IS the defect this tolerance exists to fix, so
        // adding the tolerance without changing the search fixes nothing.
        //
        // Both this and the previous `first` assume `words` is in ascending
        // start order, which is what the recognizer emits and what
        // `correctWord` preserves (it rewrites text, never timing).
        guard let index = words.lastIndex(where: { source >= $0.start - clockTolerance })
        else { return nil }
        return source < words[index].end ? words[index].id : nil
    }

    /// How far before a word's start still counts as being inside it.
    ///
    /// This comparison is between two numbers measured on different clocks,
    /// and only one of them is exact. `PreviewController.seek` builds its
    /// target as `CMTime(seconds:preferredTimescale: 600)`, so the instant
    /// the player reports back afterwards is the requested one rounded to the
    /// nearest 1/600 s — up to 1/1200 s BEFORE what was asked for. Clicking a
    /// word seeks to `word.start` and then asks this function which word that
    /// is; when the rounding goes down, `source >= word.start` is false by a
    /// fraction of a millisecond and the answer is the PREVIOUS word, whose
    /// span ends exactly where this one begins. Whether it rounds down is
    /// decided by the fractional part of each word's start time, which is why
    /// this read as "sometimes it highlights the word before it" rather than
    /// as a consistent off-by-one.
    ///
    /// One full tick — twice the largest error it has to absorb, and no more.
    /// Bigger is not safer here: the tolerance also lights the next word early
    /// during playback, and at the pane's 20Hz poll a 10ms tolerance would put
    /// the highlight a word ahead of the audio on one sample in five. At
    /// 1/600 s it is 36x shorter than the shortest word this recognizer has
    /// produced (0.06 s, "the").
    public static let clockTolerance = 1.0 / 600.0
}
