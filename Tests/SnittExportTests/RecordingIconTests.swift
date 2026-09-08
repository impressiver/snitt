import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import SnittDocument
@testable import SnittExport

/// `RecordingIcon` composes the Finder icon for a `.snitt` bundle.
///
/// These assert what the icon LOOKS LIKE — specific pixels at specific places —
/// rather than that the drawing calls ran. "A CGImage came back" passes against
/// a composition that drew nothing, drew the badge off-screen, letterboxed the
/// frame into black bars, or forgot the rounded corners; each of those is a
/// visible defect and each has its own assertion below.
@Suite
struct RecordingIconTests {

    // MARK: - Helpers

    /// A solid image of one colour, as the stand-in for a captured frame.
    private func solid(_ color: NSColor, width: Int = 640, height: Int = 360) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// One pixel, addressed from the TOP-left as the image is displayed.
    ///
    /// Bitmap rows are stored top-first while `CGContext` measures y from the
    /// bottom, and conflating the two is how an assertion ends up checking the
    /// opposite corner from the one it names.
    private func pixel(_ image: CGImage, col: Int, rowFromTop: Int)
        -> (r: Int, g: Int, b: Int, a: Int) {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (rowFromTop * w + col) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
    }

    // MARK: - Choosing the frame

    @Test("A blank frame scores far below a detailed one")
    func detailScoreDiscriminates() {
        let flat = solid(.gray, width: 64, height: 64)
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<8 {
            for y in 0..<8 {
                ctx.setFillColor((x + y).isMultiple(of: 2) ? NSColor.black.cgColor
                                                           : NSColor.white.cgColor)
                ctx.fill(CGRect(x: x * 8, y: y * 8, width: 8, height: 8))
            }
        }
        let checker = ctx.makeImage()!
        #expect(RecordingIcon.detailScore(of: flat) < 1)
        #expect(RecordingIcon.detailScore(of: checker) > 1000)
    }

    @Test("The poster comes from the part of the recording that has content")
    func posterSkipsTheBlankOpening() async throws {
        // Flat for the first half, high-contrast bands for the second — the
        // shape of a real screen recording, which opens before anything has
        // happened.
        let url = FileManager.default.temporaryDirectory
            .appending(path: "poster-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeSyntheticMovie(to: url, seconds: 2.0, content: .blankThenBands)

        let poster = try #require(try await RecordingIcon.posterFrame(movieAt: url))
        // Taking frame zero — or any frame from the first half — scores near
        // nothing, because every pixel there is the same gray.
        #expect(RecordingIcon.detailScore(of: poster) > 100,
                "poster came from the blank half")
    }

    @Test("A kept offset resolves past the material a cut removed")
    func keptOffsetSkipsCuts() {
        let kept = [TimeRange(start: 0, end: 5), TimeRange(start: 10, end: 15)]
        // Seven seconds INTO what survives is 12s in the source, not 7s —
        // 7s in the source is inside the cut.
        let t = try? #require(RecordingIcon.sourceTime(atKeptOffset: 7, in: kept))
        #expect(t == 12)
        #expect(RecordingIcon.sourceTime(atKeptOffset: 2, in: kept) == 2)
    }

    // MARK: - Composition

    @Test("The record dot is drawn in the bottom-right corner")
    func badgeIsDrawnAndIsRed() throws {
        let icon = try #require(RecordingIcon.compose(poster: solid(.blue), side: 512))
        // The badge centre, by the same fractions the composition uses.
        let at = Int(512 * (1 - RecordingIcon.badgeInsetFraction))
        let p = pixel(icon, col: at, rowFromTop: at)
        #expect(p.r > 200 && p.g < 100 && p.b < 100,
                "expected record red at the badge centre, got \(p)")
    }

    @Test("The corners are rounded, not square")
    func cornersAreTransparent() throws {
        let icon = try #require(RecordingIcon.compose(poster: solid(.blue), side: 512))
        // Well outside a 115pt corner radius. A square icon would put opaque
        // poster here.
        #expect(pixel(icon, col: 2, rowFromTop: 2).a == 0)
        #expect(pixel(icon, col: 509, rowFromTop: 2).a == 0)
    }

    @Test("The frame fills the icon instead of being letterboxed")
    func posterIsAspectFilled() throws {
        // Deliberately extreme: aspect-FIT would put this 6.4:1 frame in a
        // narrow band across the middle and leave the rest empty.
        let icon = try #require(RecordingIcon.compose(poster: solid(.blue, width: 640, height: 100),
                                                      side: 512))
        let near = pixel(icon, col: 256, rowFromTop: 60)
        #expect(near.a > 250, "top of the icon is empty — the frame was letterboxed")
        #expect(near.b > near.r && near.b > near.g,
                "expected the frame's colour near the top, got \(near)")
    }

    @Test("The scrim darkens the bottom without hiding the frame")
    func scrimIsAGradient() throws {
        let icon = try #require(RecordingIcon.compose(poster: solid(.blue), side: 512))
        let top = pixel(icon, col: 256, rowFromTop: 130)
        let bottom = pixel(icon, col: 256, rowFromTop: 470)
        #expect(bottom.b < top.b, "bottom should be darker than top")
        #expect(top.b > 150, "the frame should still read clearly at the top")
    }

    @Test("Every Finder size is rendered rather than resampled from one")
    func iconCarriesAllSizes() throws {
        let image = try #require(RecordingIcon.iconImage(poster: solid(.blue)))
        let sides = Set(image.representations.map { Int($0.pixelsWide) })
        // Named literally, NOT compared against `renderedSides` — a test that
        // asserts a constant equals itself passes no matter what the constant
        // becomes, including a single 512 that the Finder would resample into
        // a muddy 16.
        #expect(sides.isSuperset(of: [16, 32, 128, 512]),
                "rendered \(sides.sorted()); the small sizes must be drawn, not resampled")
        // And every declared size must actually have produced a rep.
        #expect(sides.count == RecordingIcon.renderedSides.count)
    }

    // MARK: - Stamping

    @Test("Stamping gives the bundle an icon and leaves it readable")
    func stampWritesTheIconAndKeepsTheBundleValid() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "icon-\(UUID().uuidString).snitt")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0, content: .noise)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)

        #expect(try await RecordingIcon.stamp(bundle: bundle) == true)

        // The custom icon for a package lives in a file named "Icon\r" inside
        // it. Asserting the file rather than "setIcon returned true" — the
        // return value is true on paths that write nothing the Finder reads.
        let iconFile = root.appending(path: "Icon\r")
        #expect(FileManager.default.fileExists(atPath: iconFile.path),
                "no Icon file was written into the bundle")

        // The bundle gained a file it does not know about. Everything that
        // reads it must be unbothered — a beautiful icon that breaks opening
        // the recording is a bad trade.
        let reopened = try SnittBundle(opening: root)
        _ = try EditDecisionList.read(from: reopened)
        _ = try RecordingMetadata.read(from: reopened)
    }
}
