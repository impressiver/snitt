import AppKit
import Foundation
import Testing
@testable import SnittApp

/// The timeline's surface stays dark, and the waveform stays orange, under
/// EITHER system appearance.
///
/// The bug these exist for: the bands were filled with `tertiaryLabelColor`
/// and the waveform drawn in `labelColor` — label colours used as background
/// fills. Label colours invert with the appearance, so in dark mode the audio
/// band rendered as a pale slab with a pale waveform sunk into it, which is
/// exactly when the rest of the window was already dark.
///
/// Asserting under BOTH appearances is the whole point. A test that only
/// checks the current one passes against any semantic colour, because
/// whichever appearance the test host happens to run under will give one
/// plausible answer.
@Suite(.serialized)
@MainActor
struct TimelinePaletteTests {
    init() { _ = NSApplication.shared }

    private func resolved(_ color: NSColor, under name: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    /// Perceived brightness, 0...1.
    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.299 * Double(c.redComponent)
             + 0.587 * Double(c.greenComponent)
             + 0.114 * Double(c.blueComponent)
    }

    @Test("Every surface stays dark under a LIGHT system appearance")
    func surfacesStayDarkInLightMode() {
        // `controlBackgroundColor` here is near-white, and
        // `tertiaryLabelColor` is a dark grey used as a fill — both wrong,
        // and both what this replaced.
        let surfaces: [(String, NSColor)] = [
            ("background", TimelineView.Palette.background),
            ("markerLane", TimelineView.Palette.markerLane),
            ("videoBand", TimelineView.Palette.videoBand),
            ("audioBand", TimelineView.Palette.audioBand),
            ("audioBandMuted", TimelineView.Palette.audioBandMuted),
        ]
        for (name, color) in surfaces {
            let l = luminance(resolved(color, under: .aqua))
            #expect(l < 0.35, "\(name) is \(l) under light appearance — not a dark surface")
        }
    }

    @Test("Surfaces are identical under both appearances")
    func surfacesDoNotFollowTheAppearance() {
        // The timeline commits to being dark. A colour that changes between
        // the two is a semantic one that slipped back in.
        for color in [TimelineView.Palette.background,
                      TimelineView.Palette.audioBand,
                      TimelineView.Palette.playhead] {
            let light = luminance(resolved(color, under: .aqua))
            let dark = luminance(resolved(color, under: .darkAqua))
            #expect(abs(light - dark) < 0.01,
                    "resolves to \(light) light and \(dark) dark — it follows the appearance")
        }
    }

    @Test("The playhead stays light, so it reads against the dark surface")
    func playheadContrastsWithTheSurface() {
        // It used to be `labelColor`, which under a LIGHT system appearance is
        // near-black — invisible on a now-permanently-dark timeline.
        let playhead = luminance(resolved(TimelineView.Palette.playhead, under: .aqua))
        let background = luminance(resolved(TimelineView.Palette.background, under: .aqua))
        #expect(playhead - background > 0.5, "playhead \(playhead) vs background \(background)")
    }

    @Test("The waveform is orange and clears its band by a wide margin")
    func waveformIsOrangeAndContrasts() {
        let wave = (TimelineView.Palette.waveform.usingColorSpace(.sRGB))!
        #expect(wave.redComponent > 0.8, "red \(wave.redComponent)")
        #expect(wave.greenComponent > 0.3 && wave.greenComponent < 0.8,
                "green \(wave.greenComponent) — orange sits between red and yellow")
        #expect(wave.blueComponent < 0.3, "blue \(wave.blueComponent)")
        // The complaint that started this: the waveform did not stand out from
        // what it was drawn on.
        #expect(luminance(wave) - luminance(TimelineView.Palette.audioBand) > 0.35)
    }

    @Test("A muted waveform is dimmer than an unmuted one but still visible")
    func mutedWaveformIsDimmerNotGone() {
        let loud = luminance(TimelineView.Palette.waveform)
        // Alpha-composited over the band it is actually drawn on, which is
        // what determines whether it can be seen — the raw alpha says nothing.
        let muted = TimelineView.Palette.waveformMuted
        let band = TimelineView.Palette.audioBandMuted.usingColorSpace(.sRGB)!
        let a = Double(muted.alphaComponent)
        let m = muted.usingColorSpace(.sRGB)!
        let composited = NSColor(srgbRed: m.redComponent * a + band.redComponent * (1 - a),
                                 green: m.greenComponent * a + band.greenComponent * (1 - a),
                                 blue: m.blueComponent * a + band.blueComponent * (1 - a),
                                 alpha: 1)
        let mutedL = luminance(composited)
        #expect(mutedL < loud - 0.2, "muted \(mutedL) is not visibly dimmer than \(loud)")
        #expect(mutedL - luminance(band) > 0.03,
                "muted waveform \(mutedL) vanishes into its band \(luminance(band))")
    }
}
