// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// The timestamp shown beside a transcript phrase.
///
/// It sits in a column next to the transport's clock and the marker rail's
/// times, so it has to be OUTPUT time. Every assertion here is against a
/// transcript with a cut in it, because with nothing cut source and output are
/// the same number and a test would pass against either.
struct ParagraphOutputStartTests {

    private func words(_ starts: [Double]) -> [TranscriptWord] {
        starts.map { TranscriptWord(text: "w", start: $0, duration: 0.2, confidence: 0.9) }
    }

    private func paragraph(_ starts: [Double]) -> TranscriptParagraph {
        let split = TranscriptParagraphs.split(words(starts), breakingAfter: 1_000)
        return split[0]
    }

    @Test("The time is the paragraph's place in the EDIT, not in the recording")
    func timeIsOutputNotSource() {
        // Two seconds removed before it, so source 10 is output 8. A pane
        // showing 10 here would disagree with the playhead it is supposed to
        // sit beside — and would keep disagreeing by exactly the amount that
        // has been trimmed, which grows as the edit does.
        let kept = [TimeRange(start: 0, end: 4), TimeRange(start: 6, end: 30)]
        #expect(TranscriptParagraphs.outputStart(of: paragraph([10, 10.2]),
                                                 keptRanges: kept) == 8)
    }

    @Test("With nothing cut it is the plain start")
    func uncutIsIdentity() {
        #expect(TranscriptParagraphs.outputStart(of: paragraph([3, 3.2]),
                                                 keptRanges: [TimeRange(start: 0, end: 30)]) == 3)
    }

    @Test("A paragraph whose first words were cut reports its first SURVIVING word")
    func partiallyCutParagraphStillHasATime() {
        // Cut words stay on screen struck through, so a paragraph can begin
        // with words that have no position in the output at all. Asking about
        // the first word alone returns nil for this paragraph — leaving a
        // perfectly reachable phrase with no timestamp and nothing to click.
        let kept = [TimeRange(start: 0, end: 5), TimeRange(start: 8, end: 30)]
        let p = paragraph([6.0, 6.4, 9.0, 9.4])
        #expect(TranscriptParagraphs.outputStart(of: p, keptRanges: kept) == 6,
                "expected the output time of the word at source 9, which is 9 - 3")
    }

    @Test("A paragraph cut away entirely has no time at all")
    func fullyCutParagraphIsNil() {
        // Nil is reserved for the case with no answer. Returning 0, or the
        // fold's position, would invent somewhere to click that is not there.
        let kept = [TimeRange(start: 0, end: 5), TimeRange(start: 8, end: 30)]
        #expect(TranscriptParagraphs.outputStart(of: paragraph([6.0, 6.4]),
                                                 keptRanges: kept) == nil)
    }

    @Test("With everything cut, nothing has a time")
    func emptyKeptRangesIsNil() {
        #expect(TranscriptParagraphs.outputStart(of: paragraph([1, 2]), keptRanges: []) == nil)
    }
}
