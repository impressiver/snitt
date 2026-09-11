// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// The word lane's VIEW (rev 5, W14).
///
/// `WordLaneTiers` is built, tested and unchanged — its constants, its
/// boundaries and its monotonicity all predate this lane, and rev 5's spec
/// briefly described rebuilding them. Doing so would have produced a second
/// answer to a settled question, and a different one: that draft put the
/// phrases/density boundary at 4 pt/word against the shipped
/// `minimumPhraseWidth / wordsPerPhrase` = 11.25.
///
/// So these test the one thing the model cannot: that the lane asks it, and
/// draws what it is told.
@Suite(.serialized)
@MainActor
struct WordLaneViewTests {
    init() { _ = NSApplication.shared }

    /// A view holding `wordCount` words spread across `duration` seconds.
    private func view(width: Double, wordCount: Int, duration: Double = 60) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        view.update(duration: duration, cuts: [], markerPoints: [], playhead: 0)
        let step = duration / Double(max(1, wordCount))
        let words = (0..<wordCount).map { i in
            TranscriptWord(text: "word\(i)", start: Double(i) * step,
                           duration: step * 0.5, confidence: 0.9)
        }
        view.update(phrases: TranscriptPhrases.phrases(from: words))
        return view
    }

    @Test("The lane asks the model, and the model's answer is the shipped one")
    func laneTierMatchesTheModel() {
        // Identity with `WordLaneTiers`, not a re-derivation. A lane that
        // computed its own thresholds would agree with the model on most
        // inputs and disagree in the band between them — which is exactly
        // where a real recording lands and a fixture usually does not.
        for (words, width) in [(20, 900.0), (400, 900.0), (1500, 900.0), (65, 900.0)] {
            let v = view(width: width, wordCount: words)
            #expect(v.currentTierForTesting
                    == WordLaneTiers.tier(wordCount: words, laneWidth: width),
                    "\(words) words across \(width)pt")
        }
    }

    @Test("Rev 4's measured recordings land where its table said they would")
    func revFourTableStillHolds() {
        // The arithmetic that justified deferring this lane is now its test
        // data. 0.4 min / 65 words at 1x is 13.85 pt/word — above the 11.25
        // phrases boundary and below the 40pt one, so PHRASES, which is what
        // rev 4 said and what the design mock quietly contradicted by drawing
        // word chips for that clip.
        #expect(view(width: 900, wordCount: 65).currentTierForTesting == .phrases)
        // 2.5 min / 400 words → 2.25 pt/word. Density.
        #expect(view(width: 900, wordCount: 400).currentTierForTesting == .density)
        // 10 min / 1500 words → 0.6. 30 min / 4500 → 0.2. Both density.
        #expect(view(width: 900, wordCount: 1500).currentTierForTesting == .density)
        #expect(view(width: 900, wordCount: 4500).currentTierForTesting == .density)
    }

    @Test("Zooming moves a recording up the tiers, with no mode to set")
    func zoomChangesTheTier() {
        // The property that answers rev 4's deferral condition — "prototype
        // the zoom transitions" — without a setting: the tier is a function
        // of the width the lane actually has, so widening it IS zooming in.
        let narrow = view(width: 400, wordCount: 65)
        let wide = view(width: 3000, wordCount: 65)
        #expect(narrow.currentTierForTesting == .density)
        #expect(wide.currentTierForTesting == .words,
                "a 3000pt lane for 65 words is 46 pt/word and still not words")
    }

    @Test("An empty transcript draws nothing rather than an empty lane")
    func emptyTranscriptIsQuiet() {
        // `tier` answers `.density` for zero words, and the density painter
        // must then draw nothing at all — a lane that painted an empty strip
        // would put a fourth band under the waveforms on every recording that
        // has not been transcribed.
        let v = view(width: 900, wordCount: 0)
        #expect(v.wordCountForTesting == 0)
        #expect(v.currentTierForTesting == .density)
        // Rendering must not trap on the empty case.
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)
        v.cacheDisplay(in: v.bounds, to: rep!)
    }

    @Test("The lane's word count comes from the phrases it was given")
    func wordCountComesFromTheTranscript() {
        // The input to every decision above. A count that silently stayed 0
        // would put every recording in the density tier and look, from the
        // outside, like a deliberate choice.
        #expect(view(width: 900, wordCount: 137).wordCountForTesting == 137)
    }
}
