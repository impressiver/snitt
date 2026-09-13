// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import CoreGraphics
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// The bound that stops a GIF export crashing the app.
///
/// Reported 2026-09-13: exporting a GIF from the editor killed Snitt with
/// SIGSEGV inside `ColorQuantization::hist3d`, under
/// `GIFWritePlugin::writeAllFramesWithGlobalColorMap` in
/// `CGImageDestinationFinalize`.
///
/// The cause is the format, not the frames. GIF has no streaming write: ImageIO
/// quantises EVERY frame into one global colour map at finalize time. Snitt
/// records at native Retina resolution — 4112x2580 is ordinary here — so
/// fifteen frames a second for twenty seconds asks it to hold about 300 frames
/// of 42 megapixels at once. Nothing in the export path bounded that, because
/// the size ladder only runs when a size TARGET is set and a plain "export as
/// GIF" sets none.
struct GIFDimensionCapTests {

    @Test("A capture wider than the cap is scaled down to it")
    func retinaCaptureIsClamped() {
        // The real dimensions from the crash. A scale of 1.0 here is what
        // reached ImageIO, and what it could not encode.
        let scale = GIFExporter.fittingScale(forSourceWidth: 4112)
        #expect(scale < 1.0, "a 4112px capture was not scaled down at all")
        #expect(abs(4112 * scale - GIFExporter.maximumWidth) < 1,
                "clamped to \(4112 * scale)px, expected \(GIFExporter.maximumWidth)")
    }

    @Test("A capture already within the cap is left alone")
    func smallCaptureIsUntouched() {
        // Never ENLARGES. A GIF upscaled to the cap would be blurrier and
        // bigger for no reason, and the cap is a ceiling rather than a target.
        #expect(GIFExporter.fittingScale(forSourceWidth: 640) == 1.0)
        #expect(GIFExporter.fittingScale(forSourceWidth: GIFExporter.maximumWidth) == 1.0)
    }

    @Test("The cap is small enough to actually encode")
    func capIsWithinReach() {
        // Pinned as a number with a reason rather than left to taste: the
        // failure it prevents is a crash, so raising it is a decision that
        // should have to argue with this test. 1280 wide at 15fps for a minute
        // is roughly 900 frames of 0.9 megapixels — an order of magnitude
        // inside what killed the app.
        #expect(GIFExporter.maximumWidth <= 1920,
                "a cap this high risks the quantisation crash it exists to prevent")
        #expect(GIFExporter.maximumWidth >= 640,
                "a cap this low makes GIFs unreadable for a screen recording")
    }

    @Test("A GIF export of an oversized recording completes and is within the cap")
    func oversizedExportSucceeds() async throws {
        // End to end, at a width the old code would have handed to ImageIO
        // whole. Deliberately short — the crash needs both dimensions and
        // duration, and reproducing it exactly would take a test that risks
        // killing the runner.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gifcap-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0,
                                      size: CGSize(width: 2400, height: 1350))
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "gifcap-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await MovieExporter.export(bundle: bundle, edl: EditDecisionList(),
                                           scale: 1.0, to: out, format: "gif")

        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Double(frame.width) <= GIFExporter.maximumWidth + 2,
                "the GIF came out \(frame.width)px wide, above the cap")
        // And it is still a real animation rather than a single frame saved to
        // dodge the problem.
        #expect(CGImageSourceGetCount(source) > 1)
    }

    @Test("A reduced scale that is STILL oversized is clamped further, not widened")
    func reducedButStillOversizedScaleIsClampedFurther() async throws {
        // The case that distinguishes multiplying the scale from replacing it,
        // and the one a size ladder actually produces: a rung asked for 0.75
        // of a 2400px capture, which is 1800px and still past the cap.
        //
        // Multiplying gives 0.75 x (1280/1800) = 0.53, landing on the cap.
        // REPLACING gives 1280/1800 = 0.71, which is 1707px — still over the
        // cap, and still the crash. A first version of this file only tested a
        // scale that was already small enough, so the branch never ran and the
        // difference was invisible.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gifrung-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0,
                                      size: CGSize(width: 2400, height: 1350))
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "gifrung-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await MovieExporter.export(bundle: bundle, edl: EditDecisionList(),
                                           scale: 0.75, to: out, format: "gif")

        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Double(frame.width) <= GIFExporter.maximumWidth + 2,
                "0.75 of 2400 is 1800px and was not clamped: got \(frame.width)px")
    }

    @Test("A caller asking for a smaller scale still gets the smaller one")
    func explicitScaleIsNotOverridden() async throws {
        // The clamp is a ceiling, not an assignment. A size ladder rung that
        // asked for 0.35 must not be widened back to the cap — that would undo
        // the very shrinking the ladder walked down to achieve.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gifsmall-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0,
                                      size: CGSize(width: 2400, height: 1350))
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "gifsmall-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await MovieExporter.export(bundle: bundle, edl: EditDecisionList(),
                                           scale: 0.25, to: out, format: "gif")

        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Double(frame.width) < 700,
                "0.25 of 2400 should be about 600px, got \(frame.width)")
    }
}
