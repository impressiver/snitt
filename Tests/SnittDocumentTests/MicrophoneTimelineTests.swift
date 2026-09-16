// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// What the microphone is made of, second by second (D102).
///
/// The piece D93 never needed. A third track was simply added alongside the
/// capture's own; a take has to be woven INTO one of them, which means someone
/// has to decide, at every moment, whether the microphone is what was captured
/// or what was said afterwards.
///
/// The invariant underneath all of these: the result TILES the kept footage.
/// Every second of output has exactly one microphone source — no gaps, no
/// overlaps — which is what makes deleting a take restore the original rather
/// than leave a hole.
struct MicrophoneTimelineTests {

    private let whole = [TimeRange(start: 0, end: 10)]

    private func take(_ start: Double, _ duration: Double, file: Double = 0) -> Overdub {
        Overdub(filename: "t.m4a", durationSeconds: duration,
                segments: [OverdubSegment(takeStart: file, sourceStart: start,
                                          durationSeconds: duration)])
    }

    /// Asserts the result covers the output with no gaps and no overlaps.
    private func expectTiles(_ pieces: [MicrophoneTimeline.Piece],
                             totalDuration: Double,
                             _ label: String = "") {
        var cursor = 0.0
        for piece in pieces.sorted(by: { $0.outputStart < $1.outputStart }) {
            #expect(abs(piece.outputStart - cursor) < 1e-9,
                    "\(label) gap or overlap at \(cursor): next piece starts \(piece.outputStart)")
            cursor = piece.outputEnd
        }
        #expect(abs(cursor - totalDuration) < 1e-9,
                "\(label) covers \(cursor)s of \(totalDuration)s")
    }

    @Test("With no takes it is exactly the kept footage")
    func noTakesIsTheCapture() {
        // The overwhelmingly common case, and the reason the exporter can use
        // this one path for every recording rather than branching.
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole, overdubs: [])
        #expect(pieces.count == 1)
        #expect(pieces[0].source == .capture(start: 0))
        #expect(pieces[0].durationSeconds == 10)
    }

    @Test("A take in the middle splits the capture around it")
    func takeSplitsTheCapture() {
        // Three pieces: capture, take, capture. Two would mean the tail was
        // lost, one would mean the take never landed.
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole, overdubs: [take(4, 2)])
        expectTiles(pieces, totalDuration: 10)
        #expect(pieces.map(\.source) == [.capture(start: 0),
                                         .overdub(index: 0, start: 0),
                                         .capture(start: 6)])
        #expect(pieces.map(\.durationSeconds) == [4, 2, 4])
    }

    @Test("The capture AFTER a take resumes at the right source second")
    func captureResumesAtTheRightPlace() {
        // The defect that would be inaudible in a duration check and obvious
        // to a listener: advancing the output time without advancing the
        // source offset replays the seconds the take just covered.
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole, overdubs: [take(4, 2)])
        let tail = try? #require(pieces.last)
        #expect(tail?.source == .capture(start: 6),
                "the capture resumed at \(String(describing: tail?.source)) rather than source 6")
    }

    @Test("A take at the very start leaves no empty piece in front of it")
    func takeAtZero() {
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole, overdubs: [take(0, 3)])
        expectTiles(pieces, totalDuration: 10)
        #expect(pieces.count == 2)
        #expect(pieces[0].source == .overdub(index: 0, start: 0))
    }

    @Test("A take running to the end leaves no empty piece after it")
    func takeAtEnd() {
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole, overdubs: [take(7, 3)])
        expectTiles(pieces, totalDuration: 10)
        #expect(pieces.count == 2)
        #expect(pieces[1].source == .overdub(index: 0, start: 0))
    }

    @Test("A take covering everything leaves no capture at all")
    func takeCoveringEverything() {
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole, overdubs: [take(0, 10)])
        expectTiles(pieces, totalDuration: 10)
        #expect(pieces.allSatisfy {
            if case .overdub = $0.source { return true }
            return false
        })
    }

    @Test("Two takes each own their own span")
    func twoSeparateTakes() {
        // The reason takes are a list. Fixing two sentences must not mean
        // re-recording everything between them.
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole,
                                               overdubs: [take(1, 2), take(6, 2)])
        expectTiles(pieces, totalDuration: 10)
        #expect(pieces.map(\.source) == [.capture(start: 0),
                                         .overdub(index: 0, start: 0),
                                         .capture(start: 3),
                                         .overdub(index: 1, start: 0),
                                         .capture(start: 8)])
    }

    @Test("A LATER take wins where two overlap")
    func laterTakeWins() {
        // Recording again over a line you already re-recorded is a fix, and
        // the second attempt is the one you meant.
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole,
                                               overdubs: [take(2, 4), take(3, 2)])
        expectTiles(pieces, totalDuration: 10)
        // Take 1 owns 3-5 outright; take 0 keeps only what is left of its span.
        //
        // The assertion is on WHICH TAKE is heard at that instant, not on the
        // file offset there: a piece carries the offset it BEGINS at, and a
        // first version of this asked for the offset four seconds in and
        // failed against correct code.
        let atFour = pieces.first { $0.outputStart <= 4 && 4 < $0.outputEnd }
        guard case .overdub(let index, _)? = atFour?.source else {
            Issue.record("at output 4 the microphone is \(String(describing: atFour?.source))")
            return
        }
        #expect(index == 1, "the earlier take is still heard under the later one")
        // And take 0 survives either side of the overlap rather than vanishing.
        #expect(pieces.contains {
            if case .overdub(let i, _) = $0.source { return i == 0 }
            return false
        }, "the earlier take was removed entirely rather than trimmed")
    }

    @Test("An overlapped take keeps the right offset into its own file")
    func overlapKeepsFileOffsets() {
        // The half of the earlier take that survives starts LATER in its own
        // file. Keeping offset 0 there would replay its opening words.
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole,
                                               overdubs: [take(2, 4), take(4, 2)])
        let survivor = pieces.first { $0.source == .overdub(index: 0, start: 0) }
        #expect(survivor?.durationSeconds == 2, "take 0 should keep 2-4, its first two seconds")
        let later = pieces.first {
            if case .overdub(let index, _) = $0.source { return index == 1 }
            return false
        }
        #expect(later?.source == .overdub(index: 1, start: 0))
    }

    @Test("A take split by a cut lands in both places")
    func takeAcrossACut() {
        // Anchored to the FOOTAGE: a cut through a take takes the speech over
        // the removed picture with it and leaves the rest where it belongs.
        let kept = [TimeRange(start: 0, end: 3), TimeRange(start: 7, end: 10)]
        let overdub = Overdub(filename: "t.m4a", durationSeconds: 4, segments: [
            OverdubSegment(takeStart: 0, sourceStart: 2, durationSeconds: 1),
            OverdubSegment(takeStart: 1, sourceStart: 7, durationSeconds: 1),
        ])
        let pieces = MicrophoneTimeline.pieces(keptRanges: kept, overdubs: [overdub])
        expectTiles(pieces, totalDuration: 6)
        #expect(pieces.filter {
            if case .overdub = $0.source { return true }
            return false
        }.count == 2)
    }

    @Test("A take over footage that has since been cut disappears entirely")
    func takeOverRemovedFootage() {
        // Its segments point at source nobody kept, so there is nowhere for it
        // to play — and the capture underneath is unaffected because there was
        // never any capture there either.
        let kept = [TimeRange(start: 0, end: 3)]
        let pieces = MicrophoneTimeline.pieces(keptRanges: kept, overdubs: [take(50, 2)])
        expectTiles(pieces, totalDuration: 3)
        #expect(pieces == [MicrophoneTimeline.Piece(source: .capture(start: 0),
                                                    outputStart: 0, durationSeconds: 3)])
    }

    @Test("Cuts either side of a take keep the output contiguous")
    func cutsAndTakesTogether() {
        // The case where both mechanisms are in play, which is where an
        // off-by-one in the cursor shows up as audio sliding under the picture.
        let kept = [TimeRange(start: 0, end: 4), TimeRange(start: 8, end: 12)]
        let pieces = MicrophoneTimeline.pieces(keptRanges: kept, overdubs: [take(2, 1)])
        expectTiles(pieces, totalDuration: 8)
        #expect(pieces.map(\.source) == [.capture(start: 0),
                                         .overdub(index: 0, start: 0),
                                         .capture(start: 3),
                                         .capture(start: 8)])
    }

    @Test("Nothing kept means nothing to play")
    func nothingKept() {
        #expect(MicrophoneTimeline.pieces(keptRanges: [], overdubs: [take(0, 2)]).isEmpty)
        #expect(MicrophoneTimeline.pieces(keptRanges: [], overdubs: []).isEmpty)
    }

    @Test("A take with no segments changes nothing")
    func takeWithNoSegments() {
        let empty = Overdub(filename: "t.m4a", durationSeconds: 2, segments: [])
        let pieces = MicrophoneTimeline.pieces(keptRanges: whole, overdubs: [empty])
        #expect(pieces == MicrophoneTimeline.pieces(keptRanges: whole, overdubs: []))
    }
}

/// A recording made with the MICROPHONE OFF, spoken over afterwards.
///
/// The case that has no captured audio to weave a take into. It is not exotic:
/// recording a screencast silently and narrating it later is a normal way to
/// work, and it is the one where a take is the whole of the microphone.
struct OverdubWithoutCapturedMicTests {

    @Test("A take still plays when the capture has no microphone at all")
    func takeWithoutCapturedMic() {
        // `MicrophoneTimeline` does not know whether the capture HAS a
        // microphone — it lays out spans, and the exporter pairs them with
        // whatever source exists. What it must not do is refuse to place the
        // take, which is what an implementation keyed on "is there capture
        // here" would do.
        let overdub = Overdub(filename: "t.m4a", durationSeconds: 2,
                              segments: [OverdubSegment(takeStart: 0, sourceStart: 1,
                                                        durationSeconds: 2)])
        let pieces = MicrophoneTimeline.pieces(keptRanges: [TimeRange(start: 0, end: 5)],
                                               overdubs: [overdub])
        #expect(pieces.contains {
            if case .overdub = $0.source { return true }
            return false
        }, "the take was not placed")
    }
}
