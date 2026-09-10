// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// How the word lane draws itself at a given zoom (D89).
public enum WordLaneTier: Equatable, Sendable {
    /// Where talking happens versus silence, keyed like a miniature waveform.
    /// No individual words — there is no room for any.
    case density
    /// Phrase or sentence chips, at the granularity the transcript's paragraph
    /// breaks already compute.
    case phrases
    /// Discrete, individually clickable word chips.
    case words
}

/// Which tier the word lane can honestly draw, and what it would take to reach
/// the next one.
///
/// **The tiers are the deliverable, not a refinement of it.** A single row of
/// word chips works beautifully in a mockup of a 26-second clip and does not
/// survive contact with a real recording: the filmstrip and the waveform
/// degrade gracefully because they downsample, and *you cannot average two
/// words*. Shipping the one zoom level that was easy to draw would be shipping
/// the demo.
///
/// Pure, so the question "does this read as a lane or as noise at real scale"
/// is answered by arithmetic rather than by a screenshot.
public enum WordLaneTiers {

    /// The narrowest a word chip can be and still be read and clicked.
    ///
    /// Derived from the design mock rather than chosen: ~20 chips across a
    /// ~900pt lane, with 6pt of horizontal padding and a 1pt border each. That
    /// is also comfortably above WCAG 2.5.8's 24pt target floor, which a chip
    /// must clear anyway to be clickable.
    public static let minimumChipWidth: Double = 40

    /// A phrase chip carries several words, so it needs more room than one —
    /// but far less than the words it replaces.
    public static let minimumPhraseWidth: Double = 90

    /// Words per phrase chip, at the granularity the transcript's own pause
    /// detection already groups by.
    public static let wordsPerPhrase: Double = 8

    /// Points of lane per word at this zoom. The number everything else is
    /// decided from.
    public static func pointsPerWord(wordCount: Int, laneWidth: Double) -> Double {
        guard wordCount > 0, laneWidth > 0 else { return 0 }
        return laneWidth / Double(wordCount)
    }

    /// What the lane can honestly draw.
    public static func tier(wordCount: Int, laneWidth: Double) -> WordLaneTier {
        let perWord = pointsPerWord(wordCount: wordCount, laneWidth: laneWidth)
        // An empty transcript has no words to be too small: the lane is
        // silence end to end, which the density strip already draws.
        guard perWord > 0 else { return .density }
        if perWord >= minimumChipWidth { return .words }
        if perWord * wordsPerPhrase >= minimumPhraseWidth { return .phrases }
        return .density
    }

    /// How far the timeline must be zoomed, from a given lane width, before
    /// `tier` reaches `target`. 1 means it already does.
    ///
    /// This is what lets the lane say "zoom in to read words" instead of
    /// silently showing something coarser than the user asked for — the
    /// silent-no-op failure this project keeps finding.
    public static func zoomNeeded(for target: WordLaneTier,
                                  wordCount: Int, laneWidth: Double) -> Double {
        guard wordCount > 0, laneWidth > 0 else { return 1 }
        let perWord = pointsPerWord(wordCount: wordCount, laneWidth: laneWidth)
        let required: Double
        switch target {
        case .density: return 1
        case .phrases: required = minimumPhraseWidth / wordsPerPhrase
        case .words: required = minimumChipWidth
        }
        return max(1, required / perWord)
    }
}
