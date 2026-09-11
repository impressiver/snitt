// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import SwiftUI
@testable import SnittApp

// The transport is part of the INSTRUMENT, not the chrome (rev 5, W2).
//
// These RENDER the bar and read pixels back, rather than asserting a constant
// the view might not use. That distinction is the whole point here: the bar
// previously drew on `.bar`, a material that follows the system appearance,
// and a test naming the token it was supposed to use instead would have passed
// against a body that still said `.bar`. This project has logged 27 tests that
// checked a property adjacent to the one that mattered; a colour constant with
// no pixels behind it is exactly that shape.
@Suite(.serialized)
@MainActor
struct TransportSurfaceTests {

    /// The test host has no `NSApp` until something touches it, and rendering
    /// a hosting view needs one.
    init() { _ = NSApplication.shared }

    private func bar() -> TransportBar {
        TransportBar(isPlaying: false,
                     hasMarks: true,
                     currentTime: "0:08.27",
                     totalTime: "0:26.32",
                     currentMark: "Fix the off-by-one",
                     zoomFraction: .constant(0.2),
                     isScrollable: false,
                     visibleFraction: 1,
                     scrollFraction: 0,
                     onScroll: { _ in },
                     canCut: false,
                     onRewind: {},
                     onPreviousMark: {},
                     onTogglePlay: {},
                     onNextMark: {},
                     onSeekToTime: { _ in },
                     onCut: {})
    }

    /// Renders the bar under one appearance and returns the colour of a pixel
    /// in its lower-left corner — below the controls, so what is sampled is
    /// the bar's own ground rather than something drawn on it.
    private func groundColour(under name: NSAppearance.Name) throws -> NSColor {
        let host = NSHostingView(rootView: bar())
        host.appearance = NSAppearance(named: name)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 40)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.colorAt(x: 3, y: 3)?.usingColorSpace(.sRGB))
    }

    private func luminance(_ c: NSColor) -> Double {
        0.299 * Double(c.redComponent)
            + 0.587 * Double(c.greenComponent)
            + 0.114 * Double(c.blueComponent)
    }

    @Test("The transport's ground is the same under both appearances")
    func transportDoesNotFollowTheAppearance() throws {
        // The seam rev 4 left open and named: light chrome above, permanently
        // dark lanes below, and — until this — a strip between them that
        // flipped with the system theme. `TimelinePaletteTests` has asserted
        // this for the lanes since D56; the transport is drawn on the same
        // panel and answers to the same rule.
        let light = try groundColour(under: .aqua)
        let dark = try groundColour(under: .darkAqua)
        #expect(abs(luminance(light) - luminance(dark)) < 0.01,
                "light \(luminance(light)) vs dark \(luminance(dark)) — the transport follows the appearance")
    }

    @Test("The transport's ground is the instrument's ink, not a chrome material")
    func transportGroundIsInk() throws {
        // Pixels, not a constant. A `.bar` material under a light appearance
        // lands near white; ink0 is 0.09. Naming the expected token and
        // comparing against what was actually drawn is what ties the two
        // together.
        let drawn = try groundColour(under: .aqua)
        let expected = SnittPalette.ink0.usingColorSpace(.sRGB)!
        #expect(abs(Double(drawn.redComponent) - Double(expected.redComponent)) < 0.02
                && abs(Double(drawn.greenComponent) - Double(expected.greenComponent)) < 0.02
                && abs(Double(drawn.blueComponent) - Double(expected.blueComponent)) < 0.02,
                "drew \(drawn), expected ink0 \(expected)")
    }

    @Test("The transport is dark enough for the lanes to continue into it")
    func transportIsDarkUnderEitherAppearance() throws {
        // The property that actually matters to a viewer, stated
        // independently of which token supplies it: whatever the transport
        // draws, it must not be a pale band wedged above dark lanes.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let l = luminance(try groundColour(under: name))
            #expect(l < 0.2, "the transport is \(l) under \(name.rawValue) — that is a light strip")
        }
    }
}
