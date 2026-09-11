// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import SwiftUI
@testable import SnittApp
@testable import SnittExport

// The brand palette (rev 5, W1).
//
// These assert the PROPERTIES of the tokens and the RELATIONSHIPS between
// them — never a hex literal re-typed from the spec. A test that re-declares
// the value it is checking passes against any value, including a wrong one;
// `EditorChromePalette` carries the scar from the last time that happened
// here, where a test naming `.systemOrange` kept passing after the property
// it was meant to pin had moved, and a mutant swapping it back survived.
@Suite
struct SnittPaletteTests {

    private func srgb(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private func luminance(_ color: NSColor) -> Double {
        let c = srgb(color)
        return 0.299 * Double(c.redComponent)
             + 0.587 * Double(c.greenComponent)
             + 0.114 * Double(c.blueComponent)
    }

    private func resolved(_ color: NSColor, under name: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { out = srgb(color) }
        return out
    }

    /// Contrast ratio per WCAG 2.x, from relative luminance.
    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func relative(_ color: NSColor) -> Double {
            let c = srgb(color)
            func channel(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent)
                 + 0.7152 * channel(c.greenComponent)
                 + 0.0722 * channel(c.blueComponent)
        }
        let (x, y) = (relative(a), relative(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test("The record red IS the app icon's red, not a colour that resembles it")
    func recordRedMatchesTheIcon() throws {
        // The icon is the source of truth and this is the only place the
        // relationship is stated. Asserting a literal here instead would let
        // the two drift apart while both tests stayed green — which is the
        // whole failure this file exists to prevent.
        let icon = try #require(RecordingIcon.recordRed.components)
        let brand = srgb(SnittPalette.recordRed)
        #expect(abs(Double(brand.redComponent) - Double(icon[0])) < 0.001,
                "red \(brand.redComponent) vs icon \(icon[0])")
        #expect(abs(Double(brand.greenComponent) - Double(icon[1])) < 0.001,
                "green \(brand.greenComponent) vs icon \(icon[1])")
        #expect(abs(Double(brand.blueComponent) - Double(icon[2])) < 0.001,
                "blue \(brand.blueComponent) vs icon \(icon[2])")
    }

    @Test("Every token is sRGB, not the generic gray space")
    func everyTokenIsSRGB() {
        // `NSColor(white:)` lands in a generic gray space whose components do
        // not correspond to the hex they look like — the timeline's first
        // grey ramp came out markedly darker than the values read. This is
        // the assertion that stops that initialiser coming back.
        let tokens: [(String, NSColor)] = [
            ("ink0", SnittPalette.ink0), ("ink1", SnittPalette.ink1),
            ("ink2", SnittPalette.ink2), ("ink3", SnittPalette.ink3),
            ("signal", SnittPalette.signal), ("signalBright", SnittPalette.signalBright),
            ("clockAmber", SnittPalette.clockAmber), ("recordRed", SnittPalette.recordRed),
            ("redBright", SnittPalette.redBright), ("slateText", SnittPalette.slateText),
            ("playheadInk", SnittPalette.playheadInk),
        ]
        for (name, color) in tokens {
            // Component type first, and not merely for tidiness: a catalog
            // colour like `NSColor.systemRed` raises on `.colorSpace` rather
            // than returning something wrong, so asking directly turns a
            // failed assertion into a crashed bundle — and a crashed bundle
            // is the one failure mode this project cannot read (`swift test`
            // exits 0 on it). Assert the type, then the space.
            #expect(color.type == .componentBased, "\(name) is a \(color.type) colour")
            if color.type == .componentBased {
                #expect(color.colorSpace == .sRGB,
                        "\(name) is in \(color.colorSpace.localizedName ?? "an unnamed space")")
            }
        }
    }

    @Test("The ink ramp climbs, and every step is a dark surface")
    func inkRampIsOrderedAndDark() {
        // Ordering is the property the ramp exists for: a band must read as
        // sitting ON the ground rather than under it, and a separator must
        // clear the band it divides. Asserting the four values individually
        // would pass on a ramp that had been shuffled.
        let ramp = [SnittPalette.ink0, SnittPalette.ink1,
                    SnittPalette.ink2, SnittPalette.ink3]
        for (lower, upper) in zip(ramp, ramp.dropFirst()) {
            #expect(luminance(lower) < luminance(upper),
                    "\(luminance(lower)) is not below \(luminance(upper))")
        }
        for (index, step) in ramp.enumerated() {
            #expect(luminance(step) < 0.35, "ink\(index) is \(luminance(step)) — not dark")
        }
    }

    @Test("The ink ramp is navy, not grey")
    func inkRampIsNavy() {
        // The whole point of rev 5's ramp is that it comes from the icon's
        // ground rather than from neutral grey. A ramp that had been flattened
        // back to grey would still be ordered and still be dark, so those
        // assertions cannot see this; the blue bias is what identifies it.
        for (index, step) in [SnittPalette.ink0, SnittPalette.ink1,
                              SnittPalette.ink2, SnittPalette.ink3].enumerated() {
            let c = srgb(step)
            #expect(c.blueComponent > c.redComponent * 1.2,
                    "ink\(index) blue \(c.blueComponent) vs red \(c.redComponent) — this is grey")
        }
    }

    @Test("Instrument tokens do NOT follow the appearance")
    func instrumentTokensArePinned() {
        // The timeline is an instrument: its surfaces are the same in both
        // appearances, and `TimelinePaletteTests` has enforced that since D56.
        // This is the same rule stated one level down, at the source.
        for (name, color) in [("ink0", SnittPalette.ink0),
                              ("ink2", SnittPalette.ink2),
                              ("signal", SnittPalette.signal),
                              ("recordRed", SnittPalette.recordRed),
                              ("playheadInk", SnittPalette.playheadInk)] {
            let light = luminance(resolved(color, under: .aqua))
            let dark = luminance(resolved(color, under: .darkAqua))
            #expect(abs(light - dark) < 0.001,
                    "\(name) resolves to \(light) light and \(dark) dark — it follows the appearance")
        }
    }

    @Test("Chrome text tokens DO follow the appearance")
    func chromeTextTokensAdapt() {
        // The other half of the split: chrome bends to the user's Mac. A
        // "make everything consistent" pass that pinned these would make
        // amber unreadable on a light window, which is the case they exist for.
        for (name, color) in [("amberText", SnittPalette.amberText),
                              ("redText", SnittPalette.redText)] {
            let light = luminance(resolved(color, under: .aqua))
            let dark = luminance(resolved(color, under: .darkAqua))
            #expect(abs(light - dark) > 0.05,
                    "\(name) resolves the same in both appearances — it stopped adapting")
        }
    }

    @Test("Chrome text clears AA against the ground it actually sits on")
    func chromeTextMeetsAA() {
        // Computed against white, because that is the light chrome these are
        // drawn on — not against an abstract mid-grey. `recordRed` itself
        // manages only 3.79:1 there, which is exactly why `redText` exists.
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        #expect(contrast(resolved(SnittPalette.amberText, under: .aqua), white) >= 4.5,
                "amberText on white is \(contrast(resolved(SnittPalette.amberText, under: .aqua), white)):1")
        #expect(contrast(resolved(SnittPalette.redText, under: .aqua), white) >= 4.5,
                "redText on white is \(contrast(resolved(SnittPalette.redText, under: .aqua), white)):1")
        // And the trap this pair was introduced to avoid, asserted so nobody
        // "simplifies" redText away to recordRed later.
        #expect(contrast(SnittPalette.recordRed, white) < 4.5,
                "recordRed now passes on white — check this before using it as text anyway")
    }

    @Test("Amber and slate clear AA on the ink they are drawn on")
    func instrumentTextMeetsAA() {
        // Lane labels and waveforms sit on ink0 and ink2 respectively, and
        // those are the grounds the ratios must be computed against — the
        // rev-4 accessibility pass found three tokens failing precisely
        // because they had been checked against the wrong background.
        #expect(contrast(SnittPalette.signal, SnittPalette.ink0) >= 4.5)
        #expect(contrast(SnittPalette.signal, SnittPalette.ink2) >= 4.5)
        #expect(contrast(SnittPalette.slateText, SnittPalette.ink0) >= 4.5)
        #expect(contrast(SnittPalette.slateText, SnittPalette.ink2) >= 4.5)
        #expect(contrast(SnittPalette.redBright, SnittPalette.ink0) >= 4.5)
    }

    @Test("Every surface that used to own a colour now forwards to the brand")
    func migratedAuthoritiesForwardToTheBrand() {
        // The three authorities this palette replaced kept their own
        // vocabulary — `Palette.videoBand` reads better at a draw site than
        // `SnittPalette.ink1` — so what has to be pinned is the FORWARDING,
        // not the value. Without this, swapping `waveform` back to
        // `NSColor.systemOrange` passes every other test in the suite:
        // system orange is still orange, still clears its band, still sits
        // between red and yellow. Only identity catches it.
        #expect(TimelineView.Palette.background == SnittPalette.ink0)
        #expect(TimelineView.Palette.videoBand == SnittPalette.ink1)
        #expect(TimelineView.Palette.audioBand == SnittPalette.ink2)
        #expect(TimelineView.Palette.audioBandMuted == SnittPalette.ink1)
        #expect(TimelineView.Palette.separator == SnittPalette.ink3)
        #expect(TimelineView.Palette.playhead == SnittPalette.playheadInk)
        #expect(TimelineView.Palette.waveform == SnittPalette.signal)
        #expect(TimelineView.Palette.chip == SnittPalette.ink2)
        #expect(TimelineView.Palette.mark == SnittPalette.signal)
        #expect(TimelineView.Palette.clipping == SnittPalette.recordRed)
        #expect(FoldPalette.base == SnittPalette.recordRed)
        #expect(FoldPalette.border(.expandedSelected) == SnittPalette.redBright)
        #expect(EditorChromePalette.currentHighlightColor == SnittPalette.amberText)
    }

    @Test("A cut's selected edge is brighter than the fill it bounds")
    func selectedCutEdgeIsBrighterThanItsFill() {
        // The reason `border` exists at all. An edge drawn in the same red as
        // the wash inside it is not an edge — and the previous code did
        // exactly that, reaching for `base` in both places.
        let fill = FoldPalette.fill(.expandedSelected)
        let edge = FoldPalette.border(.expandedSelected)
        #expect(luminance(edge) > luminance(fill))
    }

    @Test("The SwiftUI swatches are derived from the NSColors, not declared twice")
    func swatchesAreDerived() {
        // One property per token is the rule. Two parallel declarations is
        // how a palette drifts: the AppKit half moves, the SwiftUI half does
        // not, and nothing fails.
        let pairs: [(String, Color, NSColor)] = [
            ("ink0", SnittPalette.Swatch.ink0, SnittPalette.ink0),
            ("signal", SnittPalette.Swatch.signal, SnittPalette.signal),
            ("recordRed", SnittPalette.Swatch.recordRed, SnittPalette.recordRed),
            ("slateText", SnittPalette.Swatch.slateText, SnittPalette.slateText),
        ]
        for (name, swatch, token) in pairs {
            #expect(srgb(NSColor(swatch)) == srgb(token), "\(name) disagrees with its NSColor")
        }
    }
}

// The icon ARTWORK, not just the constant (rev 5, W10).
//
// `SnittPaletteTests.recordRedMatchesTheIcon` pins the palette to
// `RecordingIcon.recordRed` — two constants agreeing with each other. Neither
// of them had ever been checked against the file the Dock actually shows, and
// they did not match it: the artwork was drawn in 0.92/0.18/0.22 while both
// constants said 0.933/0.267/0.267. Three things claiming to be "Snitt red",
// two of them agreeing, and the one anybody can see disagreeing with both.
@Suite
struct AppIconArtworkTests {

    private func artwork() throws -> NSBitmapImageRep {
        // From this file's own location, so the test does not depend on which
        // directory the runner happened to start in — the project closed a
        // current-directory race structurally and this must not reopen it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SnittAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("Resources/AppIcon.png")
        let data = try Data(contentsOf: url)
        return try #require(NSBitmapImageRep(data: data))
    }

    @Test("The icon generator draws its dot in the palette's record red")
    func generatorUsesTheBrandRed() throws {
        // Reads the GENERATOR's declared constant, not the rendered pixels.
        //
        // Sampling the artwork was tried first and abandoned, which is worth
        // recording. Even with every colour constructed in an explicit sRGB
        // space — a real bug, found this way and fixed: `CGColor(red:green:
        // blue:alpha:)` creates a GENERIC RGB colour whose components shift
        // when drawn into an sRGB context, the same trap `TimelineView.Palette`
        // documents for `NSColor(white:)` — the value read back out of the
        // PNG and the .icns still differs from the value written, by more than
        // the drift this test exists to catch. Colour management between
        // CoreGraphics, `iconutil` and `NSImage` is not something a unit test
        // can pin down, and a tolerance loose enough to pass would also have
        // passed the artwork this replaced.
        //
        // The generator is the artwork's source, so that is where the claim
        // can be made honestly: the number the icon is drawn from is the
        // number the app is painted from. Nobody can edit one without the
        // other now — which is exactly what had happened, leaving the icon at
        // 0.92/0.18/0.22 while both constants said 0.933/0.267/0.267.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Scripts/generate-app-icon.swift"), encoding: .utf8)
        let line = try #require(
            source.split(separator: "\n").first { $0.hasPrefix("let recordRed = ") },
            "the generator no longer declares `recordRed` where this can find it")
        let numbers = line.split(whereSeparator: { !"0123456789.".contains($0) })
            .compactMap { Double($0) }
        #expect(numbers.count == 3, "could not read three components from: \(line)")
        let brand = SnittPalette.recordRed.usingColorSpace(.sRGB)!
        let expected = [Double(brand.redComponent), Double(brand.greenComponent),
                        Double(brand.blueComponent)]
        for (drawn, painted) in zip(numbers, expected) {
            #expect(abs(drawn - painted) < 0.001,
                    "the icon is drawn in \(numbers), the app is painted in \(expected)")
        }
    }

    @Test("The icon is not a full-bleed square — it has the system's margin")
    func artworkIsASquircle() throws {
        // The rev 5 rendering sits the mark on the standard squircle with a
        // transparent margin, rather than painting the whole tile. A corner
        // pixel is the cheapest way to tell the two apart, and it is the
        // change most likely to be silently lost by an edit to the generator.
        let rep = try artwork()
        let corner = try #require(rep.colorAt(x: 2, y: 2))
        #expect(corner.alphaComponent < 0.1,
                "the icon paints its own corners — it is a square, not a squircle")
    }
}
