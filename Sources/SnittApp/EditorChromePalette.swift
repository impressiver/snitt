// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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

    /// The media well behind the picture. Fixed in both appearances.
    ///
    /// Not black: a true black well makes letterboxing invisible, so a 16:9
    /// recording in a 16:10 window looks like a mis-sized picture rather than
    /// a correctly-fitted one. Near-black keeps the frame's edge readable.
    static let mediaWell = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)

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
    static let currentHighlightColor: NSColor = .systemOrange
    static var currentHighlight: Color { Color(nsColor: currentHighlightColor) }

    /// How strongly to wash the highlight behind text. Low enough to keep
    /// label text readable on top, high enough to see at a glance.
    static let currentHighlightOpacity: Double = 0.28
}
