// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import SwiftUI

/// Snitt's brand colours — the whole of them, in one place (rev 5, W1).
///
/// Every custom colour in the app resolves here. Before this file the app was
/// stock AppKit wearing three unrelated opinions: `NSColor.systemOrange`
/// waveforms, `NSColor.systemRed` cuts, and a tuned-but-neutral grey ramp for
/// the timeline — none of which had anything to do with the app icon, which
/// had a specific identity all along.
///
/// **Everything here is derived from the icon.** `recordRed` is not "a red" —
/// it is `RecordingIcon.recordRed`'s exact components, and `SnittPaletteTests`
/// asserts that relationship rather than re-typing the literal, so the two
/// cannot drift apart. The ink ramp is the icon's navy ground; the slate is
/// its window outline.
///
/// The grammar the rest of the app follows:
///
/// - **Ink is the instrument.** Four navy-biased steps: the timeline, the
///   transport and the HUD are built from these and nothing else.
/// - **Amber is time.** Waveforms, marks, timecodes, the current marker, the
///   current word. If it glows amber it is about *now*.
/// - **Red is recording and removal.** The record dot, the armed menu-bar
///   item, cuts. Red never decorates.
/// - **Slate is structure.** Lane labels, rulers, hairlines, quiet text.
/// - **Chrome stays the user's Mac** — system materials and the system accent
///   for selection. This palette deliberately does not repaint Aqua.
///
/// **Two rules, both learned the hard way.**
///
/// *One property per token.* Each colour is a stored `NSColor` with a `Color`
/// derived from it, never two parallel declarations. `EditorChromePalette`
/// records why: a test that named `.systemOrange` itself kept passing after
/// the property it was meant to pin had changed, and a mutant swapping the
/// value back survived. Tests here assert the property, never a literal that
/// happens to match it today.
///
/// *sRGB, never `NSColor(white:)`.* The convenience initialiser lands in a
/// generic gray space whose numbers do not correspond to the hex they look
/// like — the timeline's first grey ramp came out markedly darker than the
/// values read. Every component below is sRGB, and a test asserts it.
public enum SnittPalette {

    // MARK: - Ink: the instrument

    /// The timeline and transport ground, and the HUD's outer field.
    /// Replaces the old `grey(0.13)`.
    public static let ink0 = NSColor(srgbRed: 0.078, green: 0.090, blue: 0.118, alpha: 1)

    /// One step up: the video band behind the filmstrip, a muted audio band,
    /// the HUD's inner field. Replaces `grey(0.17)`.
    public static let ink1 = NSColor(srgbRed: 0.102, green: 0.118, blue: 0.153, alpha: 1)

    /// Audio bands, the transport cluster, quiet buttons on ink, word chips.
    /// Replaces `grey(0.22)`.
    public static let ink2 = NSColor(srgbRed: 0.137, green: 0.157, blue: 0.204, alpha: 1)

    /// Separators and borders drawn *on* ink. Replaces `grey(0.34)`.
    public static let ink3 = NSColor(srgbRed: 0.227, green: 0.255, blue: 0.314, alpha: 1)

    // MARK: - Amber: time

    /// Waveforms, mark ticks, the current marker and the current word — the
    /// one colour that means "now". Replaces `NSColor.systemOrange`.
    public static let signal = NSColor(srgbRed: 1.000, green: 0.624, blue: 0.180, alpha: 1)

    /// Hover and selection within the amber family, and the one filled
    /// control in the transport (play/pause).
    public static let signalBright = NSColor(srgbRed: 1.000, green: 0.722, blue: 0.302, alpha: 1)

    /// Instrument readouts: the HUD clock and the transport's timecode
    /// digits. Paler than `signal` because a readout is read, not noticed.
    public static let clockAmber = NSColor(srgbRed: 1.000, green: 0.851, blue: 0.627, alpha: 1)

    // MARK: - Red: recording and removal

    /// The record dot, the armed menu-bar item, and every cut.
    ///
    /// These are `RecordingIcon.recordRed`'s components exactly. The icon is
    /// the source of truth; if its red ever moves, this moves with it in the
    /// same change — `SnittPaletteTests` asserts the equality so the two
    /// cannot drift silently.
    ///
    /// **Never use this as text on a light ground**: 3.79:1 against white is
    /// below AA. On light chrome it may be a fill or a ≥3:1 glyph; anything
    /// that reads as text uses `redText`.
    public static let recordRed = NSColor(srgbRed: 0.933, green: 0.267, blue: 0.267, alpha: 1)

    /// Red that survives being *text* on ink (6.5:1 on `ink0`, where
    /// `recordRed` manages only 4.7:1), and the selected cut's edge.
    public static let redBright = NSColor(srgbRed: 1.000, green: 0.420, blue: 0.420, alpha: 1)

    // MARK: - Slate and the playhead

    /// Lane labels, ruler timecodes, hairlines, and quiet text on ink.
    public static let slateText = NSColor(srgbRed: 0.604, green: 0.639, blue: 0.710, alpha: 1)

    /// The playhead line and its caret — the brightest thing on the
    /// instrument, because it outranks everything it crosses. Replaces
    /// `grey(0.97)`.
    public static let playheadInk = NSColor(srgbRed: 0.961, green: 0.965, blue: 0.973, alpha: 1)

    // MARK: - Chrome-side text

    /// Amber that means "time" on chrome that follows the appearance — marker
    /// timecodes, mostly.
    ///
    /// Dynamic, because chrome is the one place this palette bends to the
    /// user's Mac: on a light window `signal` is a 2.2:1 wash and unreadable,
    /// so light resolves to a dark amber at 6.2:1 on white, while dark
    /// resolves to `signal` itself.
    public static let amberText = NSColor(name: "amberText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? signal
            : NSColor(srgbRed: 0.612, green: 0.290, blue: 0.000, alpha: 1)
    }

    /// Red that means "removal" as *text*, on either appearance. Same reason
    /// as `amberText`: `recordRed` fails AA on white, `redBright` fails it
    /// harder, so light gets its own darker resolution.
    public static let redText = NSColor(name: "redText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? redBright
            : NSColor(srgbRed: 0.769, green: 0.239, blue: 0.239, alpha: 1)
    }

    // MARK: - SwiftUI

    /// SwiftUI views take their colours from here, so there is still exactly
    /// one declaration per token.
    public enum Swatch {
        public static var ink0: Color { Color(nsColor: SnittPalette.ink0) }
        public static var ink1: Color { Color(nsColor: SnittPalette.ink1) }
        public static var ink2: Color { Color(nsColor: SnittPalette.ink2) }
        public static var ink3: Color { Color(nsColor: SnittPalette.ink3) }
        public static var signal: Color { Color(nsColor: SnittPalette.signal) }
        public static var signalBright: Color { Color(nsColor: SnittPalette.signalBright) }
        public static var clockAmber: Color { Color(nsColor: SnittPalette.clockAmber) }
        public static var recordRed: Color { Color(nsColor: SnittPalette.recordRed) }
        public static var redBright: Color { Color(nsColor: SnittPalette.redBright) }
        public static var slateText: Color { Color(nsColor: SnittPalette.slateText) }
        public static var playheadInk: Color { Color(nsColor: SnittPalette.playheadInk) }
        public static var amberText: Color { Color(nsColor: SnittPalette.amberText) }
        public static var redText: Color { Color(nsColor: SnittPalette.redText) }
    }
}
