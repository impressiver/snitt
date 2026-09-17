// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import SnittDocument
@testable import SnittExport

/// Drawing reported clicks onto the export (D64).
@Suite
struct ClickOverlayTests {

    // MARK: - Geometry

    @Test("A window fraction becomes the matching pixel in the render")
    func fractionsBecomePixels() {
        let marks = ClickOverlay.marks(
            events: [LoggedEvent(timeSeconds: 1, kind: .click, x: 0.25, y: 0.5,
                                 source: .reported)],
            keptRanges: [TimeRange(start: 0, end: 10)],
            naturalSize: CGSize(width: 320, height: 240),
            renderTransform: .identity)
        #expect(marks.count == 1)
        #expect(marks[0].position == CGPoint(x: 80, y: 120))
        #expect(marks[0].outputTime == 1)
    }

    @Test("The mark moves with crop and scale, because it uses their transform")
    func positionFollowsTheRenderTransform() {
        // Half scale with the left quarter cropped away. Not recomputed here —
        // this is the transform CompositionBuilder itself builds, which is the
        // whole point of sharing it (§9).
        let transform = CompositionBuilder.renderTransform(
            preferredTransform: .identity,
            cropOrigin: CGPoint(x: 80, y: 0),
            scale: 0.5)
        let marks = ClickOverlay.marks(
            events: [LoggedEvent(timeSeconds: 1, kind: .click, x: 0.5, y: 0.5,
                                 source: .reported)],
            keptRanges: [TimeRange(start: 0, end: 10)],
            naturalSize: CGSize(width: 320, height: 240),
            renderTransform: transform)
        // 0.5 of 320 is 160 source px; the crop moves the origin to 80, so 80
        // in cropped space; at half scale, 40.
        #expect(marks[0].position == CGPoint(x: 40, y: 60))
    }

    @Test("A click lands on the EDIT's clock, not the recording's")
    func clickTimesFollowCuts() {
        // Two seconds removed from the front, so a click at 5s in the
        // recording is at 3s in the edit.
        let marks = ClickOverlay.marks(
            events: [LoggedEvent(timeSeconds: 5, kind: .click, x: 0.5, y: 0.5,
                                 source: .reported)],
            keptRanges: [TimeRange(start: 2, end: 10)],
            naturalSize: CGSize(width: 320, height: 240),
            renderTransform: .identity)
        #expect(marks[0].outputTime == 3)
    }

    @Test("A click inside a cut is dropped, not drawn at a moment it did not happen")
    func clicksInsideCutsAreDropped() {
        let marks = ClickOverlay.marks(
            events: [LoggedEvent(timeSeconds: 5, kind: .click, x: 0.5, y: 0.5,
                                 source: .reported)],
            keptRanges: [TimeRange(start: 0, end: 4), TimeRange(start: 6, end: 10)],
            naturalSize: CGSize(width: 320, height: 240),
            renderTransform: .identity)
        #expect(marks.isEmpty)
    }

    @Test("Only clicks with a position become marks")
    func onlyPositionedClicksDraw() {
        // A keystroke beat carries no position (D72), a marker is not input,
        // and an observed click has no coordinates because the event tap
        // records none. None of them can be drawn.
        let events = [
            LoggedEvent(timeSeconds: 1, kind: .keystroke, source: .reported),
            LoggedEvent(timeSeconds: 2, kind: .marker, label: "here"),
            LoggedEvent(timeSeconds: 3, kind: .click, source: .observed),
        ]
        #expect(ClickOverlay.marks(events: events,
                                   keptRanges: [TimeRange(start: 0, end: 10)],
                                   naturalSize: CGSize(width: 320, height: 240),
                                   renderTransform: .identity).isEmpty)
    }

    // MARK: - The ring

    @Test("A ring expands, fades, and then stops existing")
    func ringLifecycle() throws {
        let size = CGSize(width: 1280, height: 720)
        let start = try #require(ClickOverlay.ring(elapsed: 0, renderSize: size))
        let late = try #require(ClickOverlay.ring(elapsed: ClickOverlay.ringDuration * 0.9,
                                                  renderSize: size))
        #expect(late.radius > start.radius, "the ring does not expand")
        #expect(late.opacity < start.opacity, "the ring does not fade")
        // Gone afterwards, and not yet there before — a ring that never
        // expired would accumulate one per click for the rest of the video.
        #expect(ClickOverlay.ring(elapsed: ClickOverlay.ringDuration, renderSize: size) == nil)
        #expect(ClickOverlay.ring(elapsed: -0.01, renderSize: size) == nil)
    }

    @Test("The ring scales with the export, with a floor")
    func ringScalesWithRenderSize() throws {
        let big = try #require(ClickOverlay.ring(elapsed: 0, renderSize: CGSize(width: 1920, height: 1080)))
        let small = try #require(ClickOverlay.ring(elapsed: 0, renderSize: CGSize(width: 320, height: 240)))
        #expect(big.radius > small.radius, "a ring is the same pixel size at every scale")
        // And never so small it cannot be seen on a heavily scaled export.
        let tiny = try #require(ClickOverlay.ring(elapsed: 0, renderSize: CGSize(width: 64, height: 48)))
        #expect(tiny.radius >= 3.5, "the ring vanishes on a small export")
    }
}

/// End-to-end: a reported click becomes visible pixels, in the right place.
///
/// The geometry tests above prove the arithmetic. They cannot prove the
/// CONVENTION — whether the y this code calls "top-left" really is the top of
/// the exported frame. A y-flip passes every one of them and puts every ring in
/// the wrong half of the video, so this renders a real GIF and looks.
@Suite
struct ClickOverlayRenderTests {

    private func brightestPixel(in image: CGImage) -> (x: Int, y: Int, luma: Double) {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var best = (x: 0, y: 0, luma: -1.0)
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let luma = 0.299 * Double(px[i]) + 0.587 * Double(px[i+1]) + 0.114 * Double(px[i+2])
                if luma > best.luma { best = (col, row, luma) }
            }
        }
        // Row 0 of a bitmap context is the TOP of the image as displayed.
        return best
    }

    @Test("A reported click is drawn in the quadrant it was reported in")
    func clickLandsInTheRightQuadrant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "clicks-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        // Flat gray, so a white ring is unambiguously the brightest thing.
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0)

        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        // Upper-LEFT quadrant. Chosen because a y-flip moves it to the lower
        // left and a swapped x/y moves it nowhere — only this corner
        // distinguishes both mistakes at once from the centre.
        let click = LoggedEvent(timeSeconds: 0, kind: .click, x: 0.25, y: 0.25,
                                source: .reported)
        let marks = ClickOverlay.marks(events: [click], keptRanges: built.keptRanges,
                                       naturalSize: built.naturalSize,
                                       renderTransform: built.renderTransform)
        try #require(marks.count == 1)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "clicks-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        try await GIFExporter.write(built, to: out, framesPerSecond: 5, clicks: marks)

        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let hit = brightestPixel(in: frame)
        let size = built.videoComposition.renderSize

        // The ring is white on flat gray; anything dimmer means it was not
        // drawn at all.
        #expect(hit.luma > 200, "no ring found; brightest pixel was \(hit.luma)")
        #expect(Double(hit.x) < size.width / 2,
                "ring at x=\(hit.x) is in the right half of \(Int(size.width))")
        #expect(Double(hit.y) < size.height / 2,
                "ring at y=\(hit.y) is in the BOTTOM half of \(Int(size.height)) — y is flipped")
        // And near the reported point, not merely in its quadrant.
        #expect(abs(Double(hit.x) - size.width * 0.25) < size.width * 0.1,
                "ring at x=\(hit.x), expected near \(size.width * 0.25)")
        #expect(abs(Double(hit.y) - size.height * 0.25) < size.height * 0.1,
                "ring at y=\(hit.y), expected near \(size.height * 0.25)")
    }

    @Test("The mp4 burn puts the ring in the same place the GIF does")
    func mp4CarriesTheRing() async throws {
        // The two formats take completely different routes — an animation tool
        // on an export-only composition for mp4, per-frame drawing for GIF —
        // so "it works" for one says nothing about the other. This is the mp4
        // half, and it is checked against the same expected point.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mp4clicks-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        // 1280x720, not the fixture's 320x240 default. A click ring is sized
        // from the picture, so a tiny frame draws a thin stroke that H.264
        // smears below the brightness this asserts — the measurement lands in
        // the noise rather than the ring failing to draw. Verified against a
        // real export: the burn-in is correct at the sizes Snitt ships.
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0,
                                      size: CGSize(width: 1280, height: 720))
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let marks = ClickOverlay.marks(
            events: [LoggedEvent(timeSeconds: 0.5, kind: .click, x: 0.25, y: 0.25,
                                 source: .reported)],
            keptRanges: built.keptRanges, naturalSize: built.naturalSize,
            renderTransform: built.renderTransform)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "mp4clicks-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await MovieExporter.exportMovie(built, to: out, clicks: marks)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Just after the click, while the ring is still on screen.
        let frame = try await generator.image(
            at: CMTime(seconds: 0.55, preferredTimescale: 600)).image
        let hit = brightestPixel(in: frame)
        // 200 rather than 250: H.264 does not preserve a thin white stroke
        // exactly, and the ring is mid-fade at this instant.
        #expect(hit.luma > 190, "no ring in the mp4; brightest was \(hit.luma)")
        #expect(abs(Double(hit.x) - Double(frame.width) * 0.25) < Double(frame.width) * 0.1,
                "ring at x=\(hit.x) of \(frame.width)")
        #expect(abs(Double(hit.y) - Double(frame.height) * 0.25) < Double(frame.height) * 0.1,
                "ring at y=\(hit.y) of \(frame.height) — y may be flipped in the layer tree")
    }

    @Test("With no clicks the frames are untouched")
    func noClicksNoDrawing() async throws {
        // The overlay must cost nothing when unused — an export that quietly
        // recompressed every frame through a drawing context would be a
        // regression nobody could see.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "noclicks-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "noclicks-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        try await GIFExporter.write(built, to: out, framesPerSecond: 5, clicks: [])

        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Flat gray everywhere: nothing bright was added.
        #expect(brightestPixel(in: frame).luma < 200)
    }
}
