// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import CoreGraphics
@testable import SnittExport

/// The slab a burned-in caption sits on.
///
/// **A shadow cannot do this job and no amount of tuning makes it.** It
/// darkens the pixels immediately around each glyph, which rescues white text
/// over a busy but middling background and fails completely over a bright one:
/// white text with a soft dark edge, on a white document, is white on white.
/// Snitt records screens, and screens are mostly bright documents, so that is
/// the common case rather than the awkward one.
///
/// A plate fixes the contrast instead of improving it. Whatever is behind, the
/// text is on a known dark ground.
@Suite
struct CaptionPlateTests {
    private let picture = CGRect(x: 0, y: 0, width: 1280, height: 720)

    private func cue(_ text: String,
                     _ placement: SubtitleCue.Placement = .alone) -> SubtitleCue {
        SubtitleCue(start: 0, end: 2, text: text,
                    track: placement == .narration ? "voiceover" : "microphone",
                    placement: placement)
    }

    /// Every pixel of the rendered caption, as straight RGBA bytes.
    private func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    @Test("There is a dark, translucent plate behind the words")
    func aPlateIsDrawn() throws {
        // THE REGRESSION, and it is a pixel test because it has to be: the
        // caption's text, font, colour, timing and position were all correct
        // before this and are all correct after. What changed is what is
        // UNDERNEATH, and nothing about the geometry reports that.
        let (image, _) = try #require(
            TextOverlayFrame.captionImage(cue("Recording the editor window"),
                                          picture: picture))
        let (bytes, width, height) = try #require(pixels(image))

        // A plate pixel: substantially opaque, and dark. Not fully opaque —
        // the picture has to show through, or the caption reads as a hole
        // punched in the video rather than as part of it.
        // Counted among the PLATE's own pixels, not the image's. The first
        // version asked whether any fully-opaque pixel existed and failed on
        // the white text sitting on top of the plate — which is opaque by
        // design and says nothing about what is under it.
        var plate = 0, opaquePlate = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 60 else { continue }
            let luma = (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
            guard luma < 90 else { continue }
            plate += 1
            if alpha > 250 { opaquePlate += 1 }
        }
        #expect(plate > width * height / 20,
                "almost nothing dark was drawn: \(plate) of \(width * height)")
        #expect(opaquePlate * 10 < plate,
                "the plate is opaque, so the picture cannot show through it")
    }

    @Test("The plate hugs the words rather than spanning the frame")
    func thePlateIsNotABar() throws {
        // A full-width slab is what a broadcast burn-in looks like. tvOS sizes
        // it to the words, which is why a short caption reads as a label and
        // not as a letterbox — and it is the difference between a caption that
        // sits IN the picture and one that covers it.
        let (image, box) = try #require(
            TextOverlayFrame.captionImage(cue("Two words"), picture: picture))
        let (bytes, width, height) = try #require(pixels(image))

        var leftmost = width, rightmost = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                guard Int(bytes[index + 3]) > 60 else { continue }
                leftmost = min(leftmost, x); rightmost = max(rightmost, x)
            }
        }
        let drawn = Double(rightmost - leftmost + 1)
        #expect(rightmost > 0, "nothing was drawn at all")
        #expect(drawn < Double(width) * 0.6,
                "a two-word caption covers \(Int(drawn)) of \(width) points: that is a bar")
        // And it is centred when the caption is alone, not shoved to one side.
        let leftGap = Double(leftmost), rightGap = Double(width - 1 - rightmost)
        #expect(abs(leftGap - rightGap) < Double(width) * 0.04,
                "a lone caption's plate is off centre by \(Int(abs(leftGap - rightGap)))")
        #expect(box.width > drawn, "the box is no wider than the plate, so nothing hugs")
    }

    @Test("Two speakers get two plates, offset the way their text is")
    func theTwoSpeakerOffsetSurvives() {
        // `captionAlignment` ragged-rights the recorded voice and ragged-lefts
        // the narration so a pair reads as two speakers. A plate that ignored
        // that would put two identical bars on screen and undo it.
        let width = 1000.0
        let recorded = OverlayLayout.captionPlateOrigin(
            alignment: OverlayLayout.captionAlignment(.recorded),
            plateWidth: 300, availableWidth: width)
        let narration = OverlayLayout.captionPlateOrigin(
            alignment: OverlayLayout.captionAlignment(.narration),
            plateWidth: 300, availableWidth: width)
        #expect(recorded != narration, "both speakers' plates sit in the same place")

        let alone = OverlayLayout.captionPlateOrigin(
            alignment: OverlayLayout.captionAlignment(.alone),
            plateWidth: 300, availableWidth: width)
        #expect(alone == (width - 300) / 2, "a lone caption's plate is not centred")
    }

    @Test("A plate wider than the frame is pinned, not pushed off the edge")
    func anOversizeCaptionStaysInside() {
        // The arithmetic is `available - plate`, which goes NEGATIVE for a
        // caption that fills the width. Unclamped, a centred one would start
        // at a negative x and lose its left end off the frame.
        let origin = OverlayLayout.captionPlateOrigin(
            alignment: .center, plateWidth: 1200, availableWidth: 1000)
        #expect(origin == 0, "an oversize plate starts at \(origin), off the frame")
    }
}
