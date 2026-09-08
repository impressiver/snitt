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
    private func makeRecorder() throws -> (Recorder, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        return (try Recorder.forTesting(bundleURL: url,
                                        videoSize: CGSize(width: 320, height: 240)), url)
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

    @Test("The marker lands at the frame's offset, not at call time")
    func markerSharesTheFrameOffset() async throws {
        // D53's actual requirement. A screenshot that marked "now" would place
        // its marker later than the frame it captured, by however long the call
        // took — and the whole point is that the two cannot drift.
        let (recorder, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.startForTesting()
        recorder.feedForTesting(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), .screen)

        let shot = try await recorder.screenshot()
        let bundle = try await recorder.stop()
        let markers = try EventLog.read(from: bundle).events.filter { $0.kind == .marker }
        let marker = try #require(markers.first)
        #expect(abs(marker.timeSeconds - shot.offsetSeconds) < 0.001,
                "marker at \(marker.timeSeconds)s, frame at \(shot.offsetSeconds)s")
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
}
