// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Text deletion becomes EDL cuts (D62).
///
/// The property that matters most is the non-contiguous one: selecting two
/// separate phrases must produce two cuts, because one bridging span would
/// delete the unselected words between them — a text edit silently removing
/// words nobody touched.
@Suite
struct TranscriptEditingTests {
    private static func word(_ text: String, _ start: Double, _ duration: Double = 0.4) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: duration, confidence: 0.9)
    }

    /// A stored property, deliberately. A first draft computed this per
    /// access, so `transcript.words[1]` and the `transcript` passed to
    /// `cutRanges` held DIFFERENT freshly-minted ids and every selection
    /// matched nothing — the words-are-matched-by-identity contract means a
    /// selection is only valid against the instance it came from.
    private let transcript = Transcript(words: [
            word("and", 11.28, 0.24), word("look", 11.52, 0.24),
            word("at", 11.76, 0.09), word("the", 11.85, 0.06),
            word("results", 11.91, 0.75), word("loom", 12.81, 0.48),
        ], locale: "en-US")

    @Test("Deleting a contiguous phrase cuts from its first word's start to its last word's end")
    func contiguousPhraseIsOneCut() throws {
        let selected = Array(transcript.words[1...3])   // look at the
        let ranges = TranscriptEditing.cutRanges(removing: selected, from: transcript)
        let range = try #require(ranges.first)
        #expect(ranges.count == 1)
        #expect(abs(range.start - 11.52) < 1e-9)
        #expect(abs(range.end - 11.91) < 1e-9, "the cut should end at 'the''s end, got \(range.end)")
    }

    @Test("Two separate selections produce two cuts, never one bridging span")
    func nonContiguousSelectionsDoNotBridge() {
        // "and" and "results" selected; "look at the" between them is not.
        let selected = [transcript.words[0], transcript.words[4]]
        let ranges = TranscriptEditing.cutRanges(removing: selected, from: transcript)
        #expect(ranges.count == 2, "a single span would delete the unselected words between")
        #expect(!ranges.contains { $0.start < 11.52 && $0.end > 11.91 })
    }

    @Test("The pause after a deleted phrase survives")
    func trailingSilenceSurvives() throws {
        // "results" ends at 12.66; "loom" starts at 12.81. Deleting "results"
        // must not swallow the 0.15s gap — that pause is the speaker breathing,
        // and cutting it makes the splice audible. Dead air is D57's job.
        let ranges = TranscriptEditing.cutRanges(removing: [transcript.words[4]], from: transcript)
        let range = try #require(ranges.first)
        #expect(abs(range.end - 12.66) < 1e-9,
                "cut ran to \(range.end) — it swallowed the pause before the next word")
    }

    @Test("Selection order does not matter")
    func selectionOrderIsIrrelevant() {
        let forward = TranscriptEditing.cutRanges(
            removing: [transcript.words[1], transcript.words[2]], from: transcript)
        let backward = TranscriptEditing.cutRanges(
            removing: [transcript.words[2], transcript.words[1]], from: transcript)
        #expect(forward == backward)
    }

    @Test("An empty selection cuts nothing")
    func emptySelection() {
        #expect(TranscriptEditing.cutRanges(removing: [], from: transcript).isEmpty)
    }

    @Test("A word inside a cut is reported cut; its neighbours are not")
    func cutWordsAreDetected() {
        let cuts = [Cut(range: TimeRange(start: 11.5, end: 11.95))]
        let ids = TranscriptEditing.cutWordIDs(in: transcript, cuts: cuts)
        let names = transcript.words.filter { ids.contains($0.id) }.map(\.text)
        // "look" (mid 11.64), "at" (11.805), "the" (11.88) are inside.
        // "results" (mid 12.285) is outside. "and" (11.40) is outside.
        #expect(names == ["look", "at", "the"], "got \(names)")
    }

    @Test("A boundary word counts by its midpoint")
    func boundaryWordUsesMidpoint() {
        // A cut covering only the first quarter of "results" (12.0) leaves its
        // midpoint (12.285) audible — the word mostly plays, so it is not cut.
        let quarter = [Cut(range: TimeRange(start: 11.91, end: 12.0))]
        #expect(TranscriptEditing.cutWordIDs(in: transcript, cuts: quarter).isEmpty)
        // Covering past the midpoint flips it.
        let most = [Cut(range: TimeRange(start: 11.91, end: 12.4))]
        let ids = TranscriptEditing.cutWordIDs(in: transcript, cuts: most)
        #expect(transcript.words.filter { ids.contains($0.id) }.map(\.text) == ["results"])
    }
}
