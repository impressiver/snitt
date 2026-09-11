// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// How a cut looks in each of the four states it can be in.
///
/// Split out of `TimelineView.draw` because the interesting decision here is a
/// RELATIONSHIP — selected is a stronger variant of unselected, in the same
/// hue, not a third opinion about what a cut looks like — and a relationship
/// asserted against literals inside a draw method is asserted nowhere.
///
/// It exists at all because selection was invisible. `EditorTimelineState`
/// tracked `selectedFoldID`, decided what Delete meant from it, and had done
/// since M5f — but the view was never told, so a selected cut drew exactly
/// like an unselected one. The blue rectangle `selectFold` set alongside it
/// could not stand in either: a cut's source range is precisely the ground
/// that cut removed, so both ends fail to map onto the output axis and the
/// rectangle is skipped rather than drawn. The state was right, complete,
/// tested, and had no pixels.
enum FoldPalette {

    /// One hue for every state. The states differ in weight, never in hue:
    /// a cut that turned orange when selected would read as a different kind
    /// of thing rather than as the same thing, chosen.
    ///
    /// Brand red since rev 5 (W1) rather than `NSColor.systemRed` — the same
    /// value the app icon's record dot is drawn in, so a cut and the thing
    /// that made it agree about what red means.
    static let base = SnittPalette.recordRed

    enum Appearance: Equatable {
        case collapsed, collapsedSelected, expanded, expandedSelected
    }

    static func appearance(expanded: Bool, selected: Bool) -> Appearance {
        switch (expanded, selected) {
        case (false, false): .collapsed
        case (false, true): .collapsedSelected
        case (true, false): .expanded
        case (true, true): .expandedSelected
        }
    }

    /// The fill: opaque for a line, transparent for a band, and the selected
    /// band stronger than the unselected one so the two can be told apart at
    /// a glance without looking away from the timeline.
    static func fill(_ appearance: Appearance) -> NSColor {
        switch appearance {
        case .collapsed, .collapsedSelected: base
        case .expanded: base.withAlphaComponent(0.35)
        case .expandedSelected: base.withAlphaComponent(0.55)
        }
    }

    /// A collapsed cut is a line, and the selected one is drawn thicker.
    /// Weight rather than colour for the same reason as above — and because
    /// two pixels of solid red at 100% cannot get any more emphatic without
    /// getting bigger.
    static func lineWidth(_ appearance: Appearance) -> Double {
        appearance == .collapsedSelected ? 4 : 2
    }

    /// A solid edge around the selected band. The fill alone is a 20-point
    /// alpha step, which is legible side by side and much less so on its own;
    /// the border is what makes "this one is selected" readable without a
    /// second band to compare against.
    static func borderWidth(_ appearance: Appearance) -> Double {
        appearance == .expandedSelected ? 2 : 0
    }

    /// The selected band's edge colour: one step brighter than the fill it
    /// bounds, which is what makes an edge read as an edge rather than as a
    /// slightly denser part of the same wash. Still the same hue — the rule
    /// at the top of this file holds.
    static func border(_ appearance: Appearance) -> NSColor {
        appearance == .expandedSelected ? SnittPalette.redBright : base
    }
}
