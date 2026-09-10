// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// What the word lane can honestly draw at a given zoom (D89).
///
/// These are the prototype. The open question was "does a row of word chips
/// read as a lane or as noise at real scale", and it is answerable with
/// arithmetic — which is cheaper than building the lane and discovering the
/// answer afterwards.
@Suite
struct WordLaneTiersTests {
    /// A realistic lane: the editor opens ~1200pt wide, less the chapters rail
    /// and the lane labels.
    private let lane = 900.0

    @Test("A ten-minute narration cannot draw word chips at all")
    func realRecordingIsADensityStrip() {
        // ~1500 words on a 900pt lane is 0.6pt per word — a seventieth of the
        // 40pt a chip needs to be read or clicked. The filmstrip and the
        // waveform survive this by downsampling; you cannot average two words.
        #expect(WordLaneTiers.tier(wordCount: 1500, laneWidth: lane) == .density)
        #expect(WordLaneTiers.pointsPerWord(wordCount: 1500, laneWidth: lane) < 1)
    }

    @Test("Even the design mock's own clip only reaches phrases")
    func theMockOverstatedItsOwnCase() {
        // The mock drew ~20 discrete word chips for a 26-second clip and used
        // that to argue for the feature. At 65 words on a 900pt lane the
        // honest tier is PHRASES — word chips need 2.9x zoom even there. The
        // drawing was of a zoom level it never stated it was at.
        #expect(WordLaneTiers.tier(wordCount: 65, laneWidth: lane) == .phrases)
        #expect(WordLaneTiers.zoomNeeded(for: .words, wordCount: 65, laneWidth: lane) > 2)
    }

    @Test("Word chips arrive only when each one can actually be clicked")
    func wordsNeedRoomToBeATarget() {
        // 40pt is the mock's own working minimum and comfortably above WCAG
        // 2.5.8's 24pt floor, which a chip must clear anyway to be a target.
        // The boundary is 900/40 = 22.5 words: 22 gives 40.9pt per chip, 23
        // gives 39.1. Stated as the arithmetic rather than as round numbers,
        // because a test that guessed the boundary would move silently with
        // the lane width.
        #expect(WordLaneTiers.tier(wordCount: 22, laneWidth: lane) == .words)
        #expect(WordLaneTiers.tier(wordCount: 23, laneWidth: lane) != .words,
                "a chip narrower than 40pt was offered as clickable")
    }

    @Test("Phrases cover the middle rather than jumping straight to silence")
    func phrasesFillTheGap() {
        // Without the middle tier the lane goes from readable words to a bare
        // density strip in one step, and everything between three and thirty
        // minutes lands in the strip — which is most real recordings.
        #expect(WordLaneTiers.tier(wordCount: 70, laneWidth: lane) == .phrases)
        #expect(WordLaneTiers.tier(wordCount: 80, laneWidth: lane) == .phrases)
    }

    @Test("The lane can say how far to zoom, rather than silently drawing less")
    func zoomNeededIsReportable() {
        // A lane that quietly shows something coarser than asked for is the
        // silent no-op this project keeps finding. Reporting the factor is
        // what lets it say "zoom in to read words" instead.
        let toWords = WordLaneTiers.zoomNeeded(for: .words, wordCount: 1500, laneWidth: lane)
        let toPhrases = WordLaneTiers.zoomNeeded(for: .phrases, wordCount: 1500, laneWidth: lane)
        #expect(toWords > 60, "expected a large factor, got \(toWords)")
        #expect(toPhrases < toWords, "phrases must be reachable before words")
        #expect(toPhrases > 15)
    }

    @Test("Zoom needed is 1 when the tier is already available")
    func noZoomNeededWhenAlreadyThere() {
        #expect(WordLaneTiers.zoomNeeded(for: .words, wordCount: 20, laneWidth: lane) == 1)
        #expect(WordLaneTiers.zoomNeeded(for: .density, wordCount: 9999, laneWidth: lane) == 1)
    }

    @Test("Tiers only ever coarsen as words are added")
    func tiersAreMonotonic() {
        // A tier that flipped back to a finer level as the transcript grew
        // would be an arithmetic error, and the kind that only shows up on
        // somebody's real recording.
        let order: [WordLaneTier: Int] = [.density: 0, .phrases: 1, .words: 2]
        var previous = 2
        for count in stride(from: 10, through: 2000, by: 10) {
            let rank = order[WordLaneTiers.tier(wordCount: count, laneWidth: lane)]!
            #expect(rank <= previous, "tier improved from \(previous) to \(rank) at \(count) words")
            previous = rank
        }
    }

    @Test("An empty transcript is silence, not a division by zero")
    func emptyTranscriptIsSafe() {
        #expect(WordLaneTiers.tier(wordCount: 0, laneWidth: lane) == .density)
        #expect(WordLaneTiers.pointsPerWord(wordCount: 0, laneWidth: lane) == 0)
        #expect(WordLaneTiers.zoomNeeded(for: .words, wordCount: 0, laneWidth: lane) == 1)
    }

    @Test("A zero-width lane does not claim it can draw words")
    func zeroWidthLaneIsSafe() {
        #expect(WordLaneTiers.tier(wordCount: 100, laneWidth: 0) == .density)
    }
}
