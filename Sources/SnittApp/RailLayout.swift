// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreGraphics
import Foundation

/// How the side panel divides itself between its two sections.
///
/// Pulled out of the view because these are DECISIONS with branches, and the
/// view around them is SwiftUI — which this project cannot assert against at
/// all on a headless runner (it renders blank). The arithmetic of a layout is
/// testable even when its appearance is not, and getting the branches wrong
/// here is what puts a drag handle on a closed section or pins an open one to
/// a height it should not have.
enum RailLayout {

    /// What height a section should take.
    enum Height: Equatable {
        /// Closed: the header, and nothing else.
        case collapsed
        /// The only open section, so it takes the rail.
        case fill
        /// Sharing the rail, so it takes the height someone dragged it to.
        case fixed(Double)
    }

    /// Whether the transcript section should open ITSELF, right now.
    ///
    /// It starts closed and opens when the recording turns out to have words.
    /// A recording with none leaves it shut, because an empty section is a
    /// header promising something that is not there.
    ///
    /// The transcript is loaded AFTER the editor opens — `loadTranscript` is
    /// deliberately not called from `init`, so the test host never constructs a
    /// recognizer — which is why this is a rule that fires on a change rather
    /// than an initial value. At the moment the rail is first built there is
    /// usually nothing to decide from.
    ///
    /// `alreadyDecided` is what makes it a DEFAULT rather than a behaviour. The
    /// section is re-evaluated whenever the word count moves, and every edit to
    /// the transcript moves it — so without this, closing the section and then
    /// deleting a word would spring it open again, and the panel would feel
    /// like it was fighting back.
    static func transcriptOpensItself(wordCount: Int, alreadyDecided: Bool) -> Bool {
        !alreadyDecided && wordCount > 0
    }

    /// The transcript's share of the rail.
    ///
    /// Its stored height applies ONLY while it is sharing — a section alone in
    /// the rail that kept a fixed height would leave a band of empty panel
    /// under it, which reads as the list having ended rather than as the
    /// window being larger than the list.
    static func transcriptHeight(markersExpanded: Bool,
                                 transcriptExpanded: Bool,
                                 stored: Double) -> Height {
        guard transcriptExpanded else { return .collapsed }
        return markersExpanded ? .fixed(stored) : .fill
    }

    /// The markers list's share. It is the one that FLEXES: the transcript
    /// carries the stored measurement, so the markers list takes whatever is
    /// left, and only one of the two can own a number without the two of them
    /// disagreeing about the rail's height.
    static func markersHeight(markersExpanded: Bool) -> Height {
        markersExpanded ? .fill : .collapsed
    }

    /// Whether a drag handle belongs between the two sections.
    ///
    /// Only when BOTH are open. A handle between an open section and a closed
    /// header resizes nothing — it would be a control that responds to being
    /// dragged and changes no pixels, which is worse than an absent one.
    static func showsDivider(markersExpanded: Bool, transcriptExpanded: Bool) -> Bool {
        markersExpanded && transcriptExpanded
    }
}

extension RailLayout.Height {
    /// The value SwiftUI's `maxHeight:` wants, which has no case for "closed"
    /// beyond `nil` — the section then sizes to its own header.
    func maxHeight(fillIsInfinite: Bool) -> CGFloat? {
        switch self {
        case .collapsed: return nil
        case .fill: return fillIsInfinite ? .infinity : nil
        case .fixed(let height): return CGFloat(height)
        }
    }
}
