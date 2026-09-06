#!/usr/bin/env swift
// Generates Resources/AppIcon.png — the single 1024x1024 source image
// `Scripts/make-app-icon.sh` slices into an `.iconset` and compiles into
// `Resources/AppIcon.icns` via `sips`/`iconutil`.
//
// Committed as a script rather than a hand-drawn asset so the icon is
// reproducible from source, not a mystery binary — the same standard this
// task's report holds `make-app.sh`'s generated Info.plist to.
//
// Motif: a slate rounded-square field (screen/monitor) with a red record
// dot ringed in white — a recording/capture motif distinctive at both Dock
// size and 16x16 Finder-list size, where fine detail disappears first.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let scale = CGFloat(size)

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else {
    FileHandle.standardError.write(Data("could not create CGContext\n".utf8))
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: scale, height: scale)

// Full-bleed background: modern macOS applies its own squircle mask to app
// icons at Dock/Finder/⌘-Tab render time, so the source art is a plain
// square, not pre-rounded — pre-rounding it would double-mask and leave a
// visible seam.
let backgroundColors = [
    CGColor(red: 0.11, green: 0.13, blue: 0.20, alpha: 1.0),
    CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1.0),
]
guard let gradient = CGGradient(colorsSpace: colorSpace, colors: backgroundColors as CFArray, locations: [0.0, 1.0]) else {
    exit(1)
}
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: scale),
    end: CGPoint(x: scale, y: 0),
    options: []
)

// A thin monitor-bezel rectangle: the "screen" half of screen recording.
let bezelInset = scale * 0.16
let bezelRect = CGRect(x: bezelInset, y: bezelInset * 1.05,
                        width: scale - bezelInset * 2, height: scale - bezelInset * 2.3)
let bezelPath = CGPath(roundedRect: bezelRect, cornerWidth: scale * 0.06, cornerHeight: scale * 0.06, transform: nil)
context.setStrokeColor(CGColor(red: 0.62, green: 0.66, blue: 0.75, alpha: 0.9))
context.setLineWidth(scale * 0.028)
context.addPath(bezelPath)
context.strokePath()

// The record dot: the "capture" half. A filled red circle with a white
// ring — recognizable at 16x16 where the bezel rectangle above has already
// dissolved into noise.
let dotRadius = scale * 0.145
let center = CGPoint(x: scale / 2, y: scale / 2 - scale * 0.02)

context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95))
context.addArc(center: center, radius: dotRadius + scale * 0.02, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.fillPath()

context.setFillColor(CGColor(red: 0.92, green: 0.18, blue: 0.22, alpha: 1.0))
context.addArc(center: center, radius: dotRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render CGImage\n".utf8))
    exit(1)
}

let outputURL = URL(fileURLWithPath: "Resources/AppIcon.png")
try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("could not create image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(outputURL.path)\n".utf8))
    exit(1)
}

print("Wrote \(outputURL.path)")
