// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittBrand
import AppKit
import SwiftUI

/// Which editor surfaces follow the system appearance, and which do not.
///
/// The editor has two kinds of surface and they answer this question
/// differently, which is the whole content of the decision:
///
/// **Chrome follows the appearance** — the chapters rail, the transcript pane,
/// the toolbar, settings. These are system furniture and should look like the
/// rest of the user's Mac.
///
/// **Media surfaces do not** — the video well and the timeline. `TimelineView`
/// has said so since D56 (*"a timeline is a dark surface in every editor that
/// has one, because the content on it is what should carry the colour"*) and
/// `TimelinePaletteTests.surfacesDoNotFollowTheAppearance` enforces it. The
/// video well had no stated background at all, so it silently followed the
/// appearance — a near-white panel behind a picture under a light theme,
/// which is the one place the same argument applies most obviously.
///
/// The seam between the two is deliberate rather than accidental: a light rail
/// meeting a pinned-dark timeline with no edge treatment is what "two apps
/// stapled together" looks like, and that was the complaint this work started
/// from.
enum EditorChromePalette {

    /// The ground behind the picture: **white on light, black on dark**.
    ///
    /// This REVERSES the earlier decision that pinned it dark in both
    /// appearances (product-owner direction, 2026-09-10), and the tests that
    /// enforced that are updated rather than deleted — they now assert the new
    /// rule, so the reversal is recorded in the same place the old rule was.
    ///
    /// The previous argument was `TimelineView`'s: a media surface should not
    /// follow the appearance because the content on it should carry the
    /// colour. That still holds for the TIMELINE, whose content is waveforms
    /// and thumbnails drawn in a tuned palette. It holds less well for the
    /// well, whose content is somebody else's screen recording — usually of a
    /// light UI, which a black surround frames as a hole rather than as a
    /// mount.
    ///
    /// Pure black and pure white, not near-black: the point is a neutral
    /// ground that disappears, and an off-white that reads as grey against a
    /// white recording is the thing being avoided.
    static let mediaWell = NSColor(name: "mediaWell") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
    }

    /// The timeline panel's own ground, so the gutter beside it matches the
    /// instrument rather than the chrome. Pinned dark like the lanes — this is
    /// the surface the well's rule was changed AWAY from, deliberately, and
    /// the two are separate decisions now.
    static var timelineSurface: Color { SnittPalette.Swatch.ink0 }

    /// The rule where appearance-following chrome meets a pinned-dark media
    /// surface. Drawn on the chrome's side, so it reads as the panel's own
    /// edge rather than as a stray line on the video.
    static var mediaEdge: Color { Color(nsColor: .separatorColor) }

    /// "The playhead is here" — one colour for the chapters rail and the
    /// transcript, matching the timeline's marker amber in intent.
    ///
    /// It was `Color.yellow` in both panes: a fixed, fully-saturated system
    /// yellow at 25-35% opacity. On a light background that is a pale wash
    /// with almost no contrast against white, and it is a THIRD opinion about
    /// what "current" looks like, alongside the timeline's amber and the
    /// transcript's own selection blue.
    ///
    /// `NSColor.systemOrange` rather than yellow: it is the colour the
    /// timeline already draws waveforms and markers in, it carries real
    /// contrast on a white ground where yellow does not, and it adapts with
    /// the appearance instead of being pinned bright.
    /// Exposed as `NSColor` as well as `Color` so there is ONE value here, not
    /// a SwiftUI one for the app and a plausible-looking constant for a test
    /// to assert against. A test that named `.systemOrange` itself would keep
    /// passing after this property changed — which is exactly what happened,
    /// and a mutant that swapped it back to yellow survived.
    static let currentHighlightColor: NSColor = SnittPalette.amberText
    static var currentHighlight: Color { Color(nsColor: currentHighlightColor) }

    /// How strongly to wash the highlight behind text. Low enough to keep
    /// label text readable on top, high enough to see at a glance.
    static let currentHighlightOpacity: Double = 0.28
}
