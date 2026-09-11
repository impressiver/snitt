#!/usr/bin/env swift
// Renders the Snitt app icon (rev 5, W10).
//
// Writes `Resources/AppIcon.png` (1024, the reference rendition) and every
// size an `.iconset` needs, rendered AT that size rather than downscaled from
// one master. `Scripts/make-app-icon.sh` compiles the set with `iconutil`.
//
// **Per-size rendering is the point, not an optimisation.** `RecordingIcon`
// already records why for the poster badge — "supplying a single 512 and
// letting the system downscale gives a muddy 16 and 32, which are the sizes
// that matter most" — and this icon has more to lose: the specular wash and
// the pane's inner highlight are a few pixels tall at 16pt, so downscaling
// turns them into grey mush over the one shape that still has to read. At
// small sizes they are dropped and the shape carries it alone.
//
// Committed as a script rather than a drawn asset so the icon is reproducible
// from source, and so its record red can be asserted against the palette's
// instead of being a colour somebody matched by eye. It was not matching: the
// previous artwork used 0.92/0.18/0.22 while `RecordingIcon.recordRed` —
// which `SnittPalette` is pinned to — is 0.933/0.267/0.267.
//
// Motif, unchanged since v0.1.0: a window outline on deep ink with a ringed
// record dot. What rev 5 changes is the rendering, not the identity — the
// flat full-bleed square becomes the system squircle with layered, glass-lit
// artwork, which is the macOS 26+ idiom.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - The palette, in one place

/// Identical to `SnittPalette.recordRed` and `RecordingIcon.recordRed`.
/// `SnittPaletteTests.recordRedMatchesTheIcon` asserts the relationship.
let recordRed = (r: 0.933, g: 0.267, b: 0.267)
let groundTop = (r: 0.141, g: 0.173, b: 0.251)     // #242C40
let groundBottom = (r: 0.063, g: 0.078, b: 0.122)  // #10141F
let slate = (r: 0.659, g: 0.694, b: 0.761)         // the window outline


/// sRGB, explicitly — never `CGColor(red:green:blue:alpha:)`.
///
/// That convenience initialiser creates a colour in the GENERIC RGB space, and
/// drawing it into an sRGB context converts it: the components that land in
/// the PNG are not the ones written here. It is the same trap
/// `TimelineView.Palette` documents for `NSColor(white:)`, and it is why the
/// previous artwork's dot never matched `RecordingIcon.recordRed` no matter
/// what number the script contained — the drift was in the colour space, not
/// in the value. `AppIconArtworkTests` reads the rendered file back and would
/// catch it returning.
func srgb(_ space: CGColorSpace, _ r: Double, _ g: Double, _ b: Double,
          _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

// MARK: - Geometry, as fractions of the side

/// Proportions preserved from the shipped mark so the Dock swap reads as a
/// polish rather than a rebrand.
enum Geometry {
    static let squircleInset = 0.055      // transparent margin, like every macOS icon
    static let cornerRadius = 0.225       // the system squircle
    static let paneSideMargin = 0.15
    static let paneTopMargin = 0.19
    static let paneCorner = 0.045
    static let paneStroke = 0.023
    static let dotDiameter = 0.31
    static let ringWidth = 0.021
}

func render(side: Int) -> CGImage? {
    let s = CGFloat(side)
    // Below this, a specular wash and a one-pixel inner highlight are noise
    // rather than depth — they average into the ground and dull the shape.
    let detailed = side >= 64

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let inset = s * Geometry.squircleInset
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * Geometry.cornerRadius
    let squircle = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

    // A soft ground shadow, so the tile sits on the desktop rather than being
    // pasted onto it. Dropped at small sizes, where it only fogs the edge.
    if detailed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                      blur: s * 0.03,
                      color: srgb(space, 0, 0, 0, 0.35))
        ctx.setFillColor(srgb(space, groundBottom.r, groundBottom.g, groundBottom.b, 1))
        ctx.addPath(squircle)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Layer 1 — the ink ground.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: space, colors: [
        srgb(space, groundTop.r, groundTop.g, groundTop.b, 1),
        srgb(space, groundBottom.r, groundBottom.g, groundBottom.b, 1),
    ] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: tile.maxY),
                               end: CGPoint(x: 0, y: tile.minY),
                               options: [])
    }

    // Layer 2 — the glass light, from the top. This is the whole difference
    // between "dark tile" and "lit object", and it is the first thing to go
    // when the raster gets small.
    if detailed, let specular = CGGradient(colorsSpace: space, colors: [
        srgb(space, 1, 1, 1, 0.22),
        srgb(space, 1, 1, 1, 0.04),
        srgb(space, 1, 1, 1, 0),
    ] as CFArray, locations: [0, 0.34, 1]) {
        ctx.drawLinearGradient(specular,
                               start: CGPoint(x: 0, y: tile.maxY),
                               end: CGPoint(x: 0, y: tile.midY),
                               options: [])
    }
    ctx.restoreGState()

    // Layer 3 — the window pane: a glass rectangle, not a drawn outline.
    let pane = CGRect(x: tile.minX + tile.width * Geometry.paneSideMargin,
                      y: tile.minY + tile.height * Geometry.paneTopMargin,
                      width: tile.width * (1 - Geometry.paneSideMargin * 2),
                      height: tile.height * (1 - Geometry.paneTopMargin * 2))
    let paneRadius = tile.width * Geometry.paneCorner
    let panePath = CGPath(roundedRect: pane, cornerWidth: paneRadius,
                          cornerHeight: paneRadius, transform: nil)
    ctx.setFillColor(srgb(space, slate.r, slate.g, slate.b, 0.07))
    ctx.addPath(panePath)
    ctx.fillPath()
    ctx.setStrokeColor(srgb(space, slate.r, slate.g, slate.b, 0.75))
    ctx.setLineWidth(tile.width * Geometry.paneStroke)
    ctx.addPath(panePath)
    ctx.strokePath()

    // Layer 4 — the record dot. Centred, and the only saturated thing here.
    let dotRadius = tile.width * Geometry.dotDiameter / 2
    let centre = CGPoint(x: tile.midX, y: tile.midY)

    // The white ring, drawn as a disc UNDER the dot rather than as a stroke:
    // at 16pt a stroke straddles its own path and vanishes to grey, while a
    // disc with the dot laid on top keeps a crisp edge at every size.
    //
    // No gap between ring and dot. The mock had one, showing the ground
    // through — which works against a mid navy and does not here: filled with
    // the ground's own darkest stop it read as a black halo, and filled with
    // anything else it would have to know the gradient's value at that exact
    // height. The shipped mark has never had one.
    ctx.setFillColor(srgb(space, 0.961, 0.965, 0.973, 0.94))
    ctx.addArc(center: centre, radius: dotRadius + tile.width * Geometry.ringWidth,
               startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // The dot is FLAT brand red, with the light laid on top of it rather than
    // blended into it.
    //
    // A radial gradient from a lighter red down to a darker one looked right
    // and was not: sampled across the disc, almost none of it was actually
    // `recordRed` — the visible colour ran 0.96/0.45/0.40 where the brand
    // value is 0.933/0.267/0.267. An icon whose red only resembles the app's
    // red is the drift this whole rev is about. Flat fill plus a soft
    // highlight keeps the material and leaves the dot unambiguously the
    // palette's colour, checkable with any colour picker.
    ctx.setFillColor(srgb(space, recordRed.r, recordRed.g, recordRed.b, 1))
    ctx.addArc(center: centre, radius: dotRadius, startAngle: 0, endAngle: .pi * 2,
               clockwise: false)
    ctx.fillPath()

    if detailed {
        ctx.saveGState()
        ctx.addArc(center: centre, radius: dotRadius, startAngle: 0, endAngle: .pi * 2,
                   clockwise: false)
        ctx.clip()
        // Light from up-left, matching the ground's specular. Confined to the
        // upper third so the dot's own colour is what the eye reads.
        if let sheen = CGGradient(colorsSpace: space, colors: [
            srgb(space, 1, 1, 1, 0.30),
            srgb(space, 1, 1, 1, 0),
        ] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(
                sheen,
                startCenter: CGPoint(x: centre.x - dotRadius * 0.34,
                                     y: centre.y + dotRadius * 0.42),
                startRadius: 0,
                endCenter: CGPoint(x: centre.x - dotRadius * 0.34,
                                   y: centre.y + dotRadius * 0.42),
                endRadius: dotRadius * 0.95, options: [])
        }
        // And a whisper of shade along the lower edge, so it reads as a sphere
        // rather than a sticker.
        if let shade = CGGradient(colorsSpace: space, colors: [
            srgb(space, 0, 0, 0, 0),
            srgb(space, 0, 0, 0, 0.18),
        ] as CFArray, locations: [0.45, 1]) {
            ctx.drawLinearGradient(shade,
                                   start: CGPoint(x: centre.x, y: centre.y + dotRadius),
                                   end: CGPoint(x: centre.x, y: centre.y - dotRadius),
                                   options: [])
        }
        ctx.restoreGState()
    }

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("could not create \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        exit(1)
    }
}

// The reference rendition, committed so the icon can be looked at without
// running anything.
guard let master = render(side: 1024) else {
    FileHandle.standardError.write(Data("could not render 1024\n".utf8))
    exit(1)
}
write(master, to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print("Wrote Resources/AppIcon.png")

// And the iconset, every entry rendered at its own size.
let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
for base in [16, 32, 128, 256, 512] {
    for (suffix, side) in [("", base), ("@2x", base * 2)] {
        guard let image = render(side: side) else {
            FileHandle.standardError.write(Data("could not render \(side)\n".utf8))
            exit(1)
        }
        write(image, to: iconset.appendingPathComponent(
            "icon_\(base)x\(base)\(suffix).png"))
    }
}
print("Wrote \(iconset.path) — 10 renditions, each drawn at its own size")
