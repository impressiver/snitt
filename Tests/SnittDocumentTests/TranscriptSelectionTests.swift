// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Shift-selecting a run of words.
///
/// The interesting part is not the gesture, it is WHICH ORDER the range runs
/// along. The pane stopped drawing words in `transcript.words` order when rows
/// were grouped by voice: a narrator's phrase is one row even though its words
/// interleave in time with the speech beside it.
struct TranscriptSelectionTests {

    private func recorded(_ items: [(String, Double)]) -> [TranscriptWord] {
        items.map { TranscriptWord(text: $0.0, start: $0.1, duration: 0.2, confidence: 1) }
    }

    private func narrated(_ items: [(String, Double)]) -> [TranscriptWord] {
        items.map { TranscriptWord(text: $0.0, start: $0.1, duration: 0.2,
                                   confidence: 1, track: "voiceover") }
    }

    /// Two voices whose words alternate in time but read as two rows.
    ///
    /// SORTED BY TIME, which is both what a recogniser emits and what makes
    /// this fixture able to tell anything. A first version listed the spoken
    /// words then the narrated ones, so the stored order happened to equal the
    /// display order and a mutant that ignored the rows entirely walked
    /// straight through every assertion here.
    private var interleaved: [TranscriptWord] {
        (recorded([("so", 1.0), ("here", 1.4), ("we", 1.8)])
            + narrated([("and", 1.2), ("that", 1.6), ("fails", 2.0)]))
            .sorted { $0.start < $1.start }
    }

    @Test("The fixture's stored order is NOT its display order")
    func fixtureDistinguishesTheTwoOrders() {
        // Asserted rather than assumed, because every other test in this suite
        // is vacuous if it stops being true.
        #expect(interleaved.map(\.text) == ["so", "and", "here", "that", "we", "fails"])
        #expect(TranscriptSelection.displayOrder(interleaved).map(\.text)
                != interleaved.map(\.text))
    }

    private func texts(_ ids: Set<UUID>, in words: [TranscriptWord]) -> [String] {
        TranscriptSelection.displayOrder(words).filter { ids.contains($0.id) }.map(\.text)
    }

    @Test("A range runs along what the reader sees, not along stored order")
    func rangeFollowsDisplayOrder() throws {
        // THE DEFECT. In stored time order the words run so/and/here/that/we,
        // so selecting "so" through "here" would drag the narrator's "and"
        // into a selection the reader can see does not contain it — and then
        // delete it.
        let words = interleaved
        let ordered = TranscriptSelection.displayOrder(words)
        let so = try #require(ordered.first { $0.text == "so" })
        let here = try #require(ordered.first { $0.text == "here" })

        let selected = TranscriptSelection.range(from: so.id, to: here.id, in: words)
        #expect(texts(selected, in: words) == ["so", "here"],
                "the selection reached into the other voice's row")
    }

    @Test("Display order is the rows, flattened")
    func displayOrderIsTheRows() {
        // Whatever `TranscriptParagraphs` decides the rows are, this follows —
        // one derivation, so the selection cannot disagree with the layout.
        #expect(TranscriptSelection.displayOrder(interleaved).map(\.text)
                == ["so", "here", "we", "and", "that", "fails"])
    }

    @Test("A range selects everything between its ends")
    func rangeIsInclusive() throws {
        let words = recorded([("a", 0), ("b", 1), ("c", 2), ("d", 3)])
        let selected = TranscriptSelection.range(from: words[0].id, to: words[2].id, in: words)
        #expect(texts(selected, in: words) == ["a", "b", "c"])
    }

    @Test("Dragging upward selects the same words as dragging downward")
    func rangeIsSymmetric() {
        // Text selection behaves this way everywhere else on the platform, and
        // a range that only worked forwards would look like the second click
        // doing nothing.
        let words = recorded([("a", 0), ("b", 1), ("c", 2)])
        let down = TranscriptSelection.range(from: words[0].id, to: words[2].id, in: words)
        let up = TranscriptSelection.range(from: words[2].id, to: words[0].id, in: words)
        #expect(down == up)
        #expect(down.count == 3)
    }

    @Test("With no anchor, only the clicked word is selected")
    func noAnchorSelectsOne() {
        let words = recorded([("a", 0), ("b", 1)])
        let selected = TranscriptSelection.range(from: nil, to: words[1].id, in: words)
        #expect(texts(selected, in: words) == ["b"])
    }

    @Test("An anchor that is no longer on screen selects only the clicked word")
    func staleAnchorSelectsOne() {
        // The muted case: mute a track and its words leave the pane, so an
        // anchor set before the mute points at something nobody can see.
        // Selecting from there to here would delete a span the reader was
        // never shown.
        let onScreen = recorded([("a", 0), ("b", 1)])
        let vanished = narrated([("gone", 0.5)])[0]
        let selected = TranscriptSelection.range(from: vanished.id, to: onScreen[1].id,
                                                 in: onScreen)
        #expect(texts(selected, in: onScreen) == ["b"])
    }

    @Test("Anchoring and clicking the same word selects just it")
    func singleWordRange() {
        let words = recorded([("a", 0), ("b", 1)])
        let selected = TranscriptSelection.range(from: words[0].id, to: words[0].id, in: words)
        #expect(texts(selected, in: words) == ["a"])
    }

    @Test("A range may cross from one voice's row into the other's")
    func rangeCanSpanRows() throws {
        // Crossing rows is legitimate — it is selecting the wrong words while
        // doing so that is not. From the last word of the spoken row to the
        // first of the narrated one is exactly two words in display order.
        let words = interleaved
        let ordered = TranscriptSelection.displayOrder(words)
        let we = try #require(ordered.first { $0.text == "we" })
        let and = try #require(ordered.first { $0.text == "and" })
        let selected = TranscriptSelection.range(from: we.id, to: and.id, in: words)
        #expect(texts(selected, in: words) == ["we", "and"])
    }
}
