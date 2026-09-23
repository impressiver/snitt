// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AVFoundation
import CoreMedia
import ImageIO
@testable import SnittCapture
@testable import SnittDocument

/// Screenshots (M5e, D53's correlation primitive).
///
/// The property that matters is NOT "a PNG appeared". It is that the image and
/// its marker come from the same frame. `mark` stamps at IPC-processing time,
/// so a screenshot that returned an image and separately called mark would give
/// "what I saw" and "what I said about it" two independent call times, drifting
/// by however long the round trip took — the drift D49 named as its own revisit
/// trigger, and which D53 says is already structural.
@MainActor
struct ScreenshotTests {
    private func makeRecorder(
        size: CGSize = CGSize(width: 320, height: 240)) throws -> (Recorder, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        return (try Recorder.forTesting(bundleURL: url, videoSize: size), url)
    }

    @Test("A screenshot writes a real PNG of the recorded frame")
    func writesARealPNG() async throws {
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot()
        #expect(FileManager.default.fileExists(atPath: shot.url.path))

        // Decoded, not just present: an empty or truncated file exists too.
        let source = try #require(CGImageSourceCreateWithURL(shot.url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 240,
                "expected the recorded frame's dimensions, got \(image.width)x\(image.height)")
        _ = try await recorder.stop()
    }

    @Test("A LABELLED screenshot's marker lands at the frame's offset, not at call time")
    func markerSharesTheFrameOffset() async throws {
        // D53's actual requirement. A screenshot that marked "now" would place
        // its marker later than the frame it captured, by however long the call
        // took — and the whole point is that the two cannot drift.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot(label: "the toolbar, after the crop")
        let bundle = try await recorder.stop()
        let markers = try EventLog.read(from: bundle).events.filter { $0.kind == .marker }
        let marker = try #require(markers.first, "a labelled screenshot must still mark")
        #expect(marker.label == "the toolbar, after the crop")
        #expect(abs(marker.timeSeconds - shot.offsetSeconds) < 0.001,
                "marker at \(marker.timeSeconds)s, frame at \(shot.offsetSeconds)s")
    }

    @Test("An unlabelled screenshot leaves no marker behind")
    func anUnlabelledScreenshotDoesNotMark() async throws {
        // The reported defect. An agent looks at the screen to check its own
        // work, and it looks often; every look used to become a chapter on
        // export and a row in the editor's marker list, so a demo's waypoints
        // were mostly the agent clearing its throat.
        //
        // Three shots, because a change that merely renamed the label would
        // still leave three rows. Verified to fail by restoring the
        // `label ?? "Screenshot"` default.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        for _ in 0..<3 { _ = try await recorder.screenshot() }
        let bundle = try await recorder.stop()
        let markers = try EventLog.read(from: bundle).events.filter { $0.kind == .marker }
        #expect(markers.isEmpty, "unasked-for markers: \(markers.map(\.label))")
    }

    @Test("Looking costs nothing; the PNG and its offset still come back")
    func anUnlabelledScreenshotStillCorrelates() async throws {
        // THE CONTROL, and the reason this change is safe: D53's guarantee was
        // never carried by the marker. Dropping the marker must not drop the
        // correlation — the offset comes back from the call and the filename IS
        // that offset, both from the same frame.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot()
        #expect(FileManager.default.fileExists(atPath: shot.url.path))
        let name = shot.url.deletingPathExtension().lastPathComponent
        let parsed = try #require(Double(name))
        #expect(abs(parsed - shot.offsetSeconds) < 0.01,
                "an unlabelled shot lost its offset: filename \(name), offset \(shot.offsetSeconds)")
        _ = try await recorder.stop()
    }

    @Test("The filename is the offset, so it needs no accompanying note")
    func filenameCarriesTheOffset() async throws {
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot()
        let name = shot.url.deletingPathExtension().lastPathComponent
        let parsed = try #require(Double(name))
        #expect(abs(parsed - shot.offsetSeconds) < 0.01,
                "filename \(name) does not match offset \(shot.offsetSeconds)")
        _ = try await recorder.stop()
    }

    @Test("A screenshot before any frame fails loudly rather than writing nothing")
    func noFrameYetThrows() async throws {
        // Silently writing a blank PNG would hand an agent a black image it
        // would then describe as the app's state.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        await #expect(throws: ScreenshotError.noFrameYet) {
            _ = try await recorder.screenshot()
        }
    }

    @Test("A screenshot works while paused")
    func worksWhilePaused() async throws {
        // The case an agent actually hits: it paused precisely in order to
        // look at something.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)
        await recorder.pause()
        recorder.feedForTesting(makeVideoBuffer(at: 1, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot()
        #expect(FileManager.default.fileExists(atPath: shot.url.path))
        _ = try await recorder.stop()
    }

    @Test("An inline screenshot returns PNG data without being asked twice")
    func inlineReturnsPNGData() async throws {
        // The file on disk and the bytes returned come from ONE frame, so
        // "what the agent saw" and "what was archived" cannot disagree.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot(inline: true)
        let png = try #require(shot.inlinePNG, "inline: true must return the frame")
        // Decoded, not just non-empty: a truncated blob has a length too.
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 240)
        _ = try await recorder.stop()
    }

    @Test("Without inline, no image data is produced at all")
    func noInlineDataByDefault() async throws {
        // Discriminates against encoding the frame every time and merely
        // withholding it: that would pay the CPU on every screenshot in a
        // running recording, competing with the encoder §12.1 protects.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot()
        #expect(shot.inlinePNG == nil)
        _ = try await recorder.stop()
    }

    @Test("A frame larger than the cap is downscaled; the archived file is not")
    func inlineDownscalesButTheFileKeepsFullResolution() async throws {
        // 2560 wide is a Retina 1280pt window, the ordinary case, and twice the
        // cap. The point of the cap is that an inline frame is returned into a
        // model's context repeatedly; the point of leaving the FILE alone is
        // that it is the archival copy a person may open.
        let (recorder, url) = try makeRecorder(size: CGSize(width: 2560, height: 1440))
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 2560, height: 1440)), .screen)

        let shot = try await recorder.screenshot(inline: true)
        let png = try #require(shot.inlinePNG)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let inlineImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(inlineImage.width == 1280,
                "expected the 1280 cap, got \(inlineImage.width)")
        #expect(inlineImage.height == 720, "aspect ratio must be preserved")

        let fileSource = try #require(CGImageSourceCreateWithURL(shot.url as CFURL, nil))
        let fileImage = try #require(CGImageSourceCreateImageAtIndex(fileSource, 0, nil))
        #expect(fileImage.width == 2560, "the archived file keeps full capture resolution")
        _ = try await recorder.stop()
    }

    @Test("A frame already under the cap is not enlarged")
    func inlineNeverEnlarges() async throws {
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot(inline: true)
        let png = try #require(shot.inlinePNG)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320, "asking for less than the cap keeps what there is")
        _ = try await recorder.stop()
    }
}
