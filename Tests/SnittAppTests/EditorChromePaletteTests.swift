// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// Which editor surfaces follow the system appearance, and which do not.
///
/// Mirrors `TimelinePaletteTests`, which asserts the same property one surface
/// over. The two of them together are the whole "chrome themes, media
/// surfaces don't" decision, expressed as tests rather than as a comment.
@Suite(.serialized)
@MainActor
struct EditorChromePaletteTests {
    init() { _ = NSApplication.shared }

    private func resolved(_ color: NSColor, under name: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.299 * Double(c.redComponent)
             + 0.587 * Double(c.greenComponent)
             + 0.114 * Double(c.blueComponent)
    }

    @Test("The media well is WHITE under a light appearance")
    func wellIsWhiteInLightMode() {
        // Reverses this suite's earlier assertion that the well stayed dark in
        // both. Updated rather than deleted: the old rule was recorded here,
        // so the new one belongs here too, and a reader comparing the two sees
        // a decision changed rather than a test quietly removed.
        let light = luminance(resolved(EditorChromePalette.mediaWell, under: .aqua))
        #expect(light > 0.95, "the well is \(light) under a light appearance")
    }

    @Test("The media well is BLACK under a dark appearance")
    func wellIsBlackInDarkMode() {
        let dark = luminance(resolved(EditorChromePalette.mediaWell, under: .darkAqua))
        #expect(dark < 0.05, "the well is \(dark) under a dark appearance")
    }

    @Test("The media well DOES follow the appearance")
    func wellFollowsTheAppearance() {
        // The exact inverse of what this file asserted before, and the reason
        // `PlayerLayerView` needs `viewDidChangeEffectiveAppearance`: a layer
        // background is a resolved `CGColor`, so nothing re-resolves it on a
        // theme change unless something asks.
        let light = luminance(resolved(EditorChromePalette.mediaWell, under: .aqua))
        let dark = luminance(resolved(EditorChromePalette.mediaWell, under: .darkAqua))
        #expect(abs(light - dark) > 0.9, "the well did not change with the appearance")
    }

    @Test("The timeline still does NOT follow the appearance")
    func timelineIsUnaffectedByTheWellChange() {
        // The well's rule changed; the timeline's did not, and the two are
        // easy to conflate now they disagree. `TimelinePaletteTests` owns this
        // properly — this is the guard that a later "make the media surfaces
        // consistent" pass does not sweep the timeline along with the well.
        let light = luminance(resolved(TimelineView.Palette.background, under: .aqua))
        let dark = luminance(resolved(TimelineView.Palette.background, under: .darkAqua))
        #expect(abs(light - dark) < 0.01)
        #expect(light < 0.3, "the timeline surface stopped being dark")
    }

    @Test("The current-playhead highlight carries contrast on a LIGHT ground")
    func highlightIsVisibleOnWhite() {
        // It was `Color.yellow` at 25% opacity. Fully-saturated system yellow
        // has a luminance near 0.9 — on a near-white row that is a wash with
        // almost nothing to see, which is why the highlight was picked by
        // luminance rather than by taste.
        // Read from the PALETTE, not from `.systemOrange`. The first version
        // named the colour directly, so swapping the palette back to yellow
        // left it passing — a mutant proved it.
        let chosen = resolved(EditorChromePalette.currentHighlightColor, under: .aqua)
        let yellow = resolved(.systemYellow, under: .aqua)
        #expect(luminance(chosen) < luminance(yellow),
                "the chosen highlight is no darker than the yellow it replaced")
        #expect(luminance(chosen) < 0.75)
    }

    @Test("The highlight adapts, unlike the media surfaces")
    func highlightFollowsTheAppearance() {
        // Chrome follows the appearance; media surfaces do not. This is the
        // other half of that split, and asserting it stops a later "make
        // everything consistent" pass from pinning the chrome too.
        let light = luminance(resolved(EditorChromePalette.currentHighlightColor, under: .aqua))
        let dark = luminance(resolved(EditorChromePalette.currentHighlightColor, under: .darkAqua))
        #expect(abs(light - dark) > 0.001, "the highlight stopped following the appearance")
    }

    @Test("The highlight is faint enough to read label text through")
    func highlightDoesNotDrownItsLabel() {
        // It sits behind a chapter's own words. Opaque enough to see, faint
        // enough that the sentence on top stays the thing you read.
        #expect(EditorChromePalette.currentHighlightOpacity > 0.1)
        #expect(EditorChromePalette.currentHighlightOpacity < 0.5)
    }
}
