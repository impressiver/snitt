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
        return words.first { source >= $0.start && source < $0.end }?.id
    }
}
