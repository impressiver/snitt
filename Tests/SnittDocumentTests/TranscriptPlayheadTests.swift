// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Which word the playhead is inside.
///
/// Every test uses a recording WITH a cut, deliberately. Without one the source
/// and output clocks agree, and an implementation that ignores `keptRanges`
/// entirely passes — which is M4b's Critical #1 shape and the reason
/// `TimelineSampleIndex` is built the same way.
@Suite
struct TranscriptPlayheadTests {
    // 2s removed from 2...4. Output is source minus 2 after the cut.
    private let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 4, end: 20)]

    private static func word(_ text: String, _ start: Double, _ duration: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: duration, confidence: 0.9)
    }

    private let words = [
        word("before", 1.0, 0.5),      // survives, output 1.0
        word("removed", 2.5, 0.5),     // inside the cut — unreachable
        word("after", 5.0, 0.5),       // survives, output 3.0
        word("later", 6.0, 0.5),       // survives, output 4.0
    ]

    @Test("Before any cut, output and source agree")
    func beforeTheCut() {
        let id = TranscriptPlayhead.currentWordID(outputSeconds: 1.2, words: words, keptRanges: kept)
        #expect(id == words[0].id)
    }

    @Test("After a cut, the playhead finds the word by SOURCE time")
    func afterTheCut() {
        // Output 3.2 is source 5.2 — inside "after". An implementation treating
        // output as source finds nothing here (source 3.2 is in the cut), so
        // this is the assertion that catches the whole defect class.
        let id = TranscriptPlayhead.currentWordID(outputSeconds: 3.2, words: words, keptRanges: kept)
        #expect(id == words[2].id, "the playhead did not map through the cut")
    }

    @Test("A word inside a cut is never current")
    func cutWordsAreUnreachable() {
        // No output time maps to source 2.5-3.0 at all; the guarantee falls out
        // of the mapping rather than needing a special case. Sweep the whole
        // output timeline to be sure nothing reaches it.
        let reachable = stride(from: 0.0, to: 18.0, by: 0.05).compactMap {
            TranscriptPlayhead.currentWordID(outputSeconds: $0, words: words, keptRanges: kept)
        }
        #expect(!reachable.contains(words[1].id), "a cut word was highlighted")
    }

    @Test("Silence between words highlights nothing")
    func gapsHighlightNothing() {
        // Output 2.0 is source 4.0 — after the cut, before "after" at 5.0.
        // Holding the previous word lit through a pause would claim someone is
        // still saying it.
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 2.0, words: words,
                                                 keptRanges: kept) == nil)
    }

    @Test("A word's end belongs to the NEXT word, not to it")
    func endIsExclusive() {
        // Contiguous spans are what the recognizer produces within an
        // utterance. An inclusive end lights two words on the same frame.
        let touching = [Self.word("one", 0.0, 0.5), Self.word("two", 0.5, 0.5)]
        let whole = [TimeRange(start: 0, end: 10)]
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 0.5, words: touching,
                                                 keptRanges: whole) == touching[1].id)
    }

    @Test("Past the end of the recording, nothing is current")
    func pastTheEnd() {
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 500, words: words,
                                                 keptRanges: kept) == nil)
    }

    @Test("An empty transcript highlights nothing rather than crashing")
    func emptyTranscript() {
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 1.0, words: [],
                                                 keptRanges: kept) == nil)
    }

    // MARK: - The seek clock

    /// `CMTime(seconds:preferredTimescale: 600)`, which is what
    /// `PreviewController.seek` builds its target from and therefore what the
    /// player reports back afterwards. Rounds half away from zero, like CMTime.
    private static func throughTheSeekClock(_ seconds: Double) -> Double {
        (seconds * 600).rounded() / 600
    }

    @Test("Clicking a word highlights THAT word, whatever its start rounds to")
    func clickRoundTripsThroughTheSeekClock() throws {
        // The reported defect: click a word, the word BEFORE it lights up.
        //
        // This is the whole path, not a piece of it — source start, out
        // through the mapping `seek(toWord:)` uses, through the seek clock's
        // rounding, and back in through the mapping the highlight uses. The
        // starts are contiguous and chosen so their fractional parts round
        // both ways at 1/600: 5.0004 rounds DOWN to 5.0 and 6.5008 down to
        // 6.5, while 7.7777 rounds UP. Against the implementation before this
        // fix the two that round down return the PREVIOUS word and the one
        // that rounds up is correct, which is exactly the coin flip that made
        // this read as intermittent.
        let contiguous = [
            Self.word("alpha", 4.5, 0.5004),     // ends where beta begins
            Self.word("beta", 5.0004, 1.5004),   // ends where gamma begins
            Self.word("gamma", 6.5008, 1.2769),  // ends where delta begins
            Self.word("delta", 7.7777, 0.9),
        ]
        for word in contiguous {
            let trimmed = TimeRangeMapping.nearestTrimmedTime(toSourceTime: word.start,
                                                              keptRanges: kept)
            let playhead = try Self.throughTheSeekClock(#require(trimmed))
            let id = TranscriptPlayhead.currentWordID(outputSeconds: playhead,
                                                      words: contiguous, keptRanges: kept)
            #expect(id == word.id, "clicking \(word.text) highlighted a different word")
        }
    }

    @Test("The tolerance reaches back one clock tick, not into the previous word")
    func toleranceDoesNotSwallowThePreviousWord() {
        // The other half of the fix: a tolerance generous enough to make the
        // test above pass can also light a word before it is spoken. Four
        // milliseconds before the boundary is still firmly inside "alpha" —
        // more than the 1.667ms tick, less than any word — so a tolerance of
        // 10ms (or of a whole 0.06s word) fails here while the shipped value
        // passes. Without this, `clockTolerance` could be raised without
        // limit and no test would object.
        let touching = [Self.word("alpha", 0.0, 1.0), Self.word("beta", 1.0, 1.0)]
        let whole = [TimeRange(start: 0, end: 10)]
        let id = TranscriptPlayhead.currentWordID(outputSeconds: 1.0 - 0.004,
                                                  words: touching, keptRanges: whole)
        #expect(id == touching[0].id, "the tolerance reached back into the previous word")
    }

    @Test("The tolerance is at least the seek clock's own error")
    func toleranceCoversTheSeekClock() {
        // A unit check on the constant itself, in the terms it is derived
        // from. `clockTolerance = 0` restores the original defect and this is
        // the assertion that names why.
        #expect(TranscriptPlayhead.clockTolerance >= 1.0 / 1200.0)
        #expect(TranscriptPlayhead.clockTolerance < 0.06,
                "a tolerance approaching a word's length lights the next word early")
    }
}
