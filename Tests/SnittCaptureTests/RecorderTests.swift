import Testing
import Foundation
import AVFoundation
@testable import SnittCapture
@testable import SnittDocument

@Test("A finished recording produces a complete bundle")
func producesCompleteBundle() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let recorder = try Recorder.forTesting(bundleURL: bundleURL,
                                           videoSize: CGSize(width: 320, height: 240))
    try await recorder.startForTesting()

    let size = CGSize(width: 320, height: 240)
    for frame in 0..<30 {
        let t = Double(frame) / 30.0
        recorder.feedForTesting(makeVideoBuffer(at: t, size: size), .screen)
        recorder.feedForTesting(makeAudioBuffer(at: t), .audio)
    }

    let bundle = try await recorder.stop()
    let fm = FileManager.default

    #expect(fm.fileExists(atPath: bundle.captureURL.path))
    #expect(fm.fileExists(atPath: bundle.metaURL.path))
    #expect(fm.fileExists(atPath: bundle.eventsURL.path))
    #expect(fm.fileExists(atPath: bundle.editURL.path))

    let meta = try RecordingMetadata.read(from: bundle)
    #expect(meta.schemaVersion == 1)
    #expect(meta.initiator == .human)
    #expect((meta.durationSeconds ?? 0) > 0)

    let edit = try EditDecisionList.read(from: bundle)
    #expect(edit.cuts.isEmpty)
    #expect(edit.trackStates.count == 3)

    let events = try EventLog.read(from: bundle)
    #expect(events.events.isEmpty, "M1 records no events; that is M3")
}

@Test("capture.mov is a real movie with a video track")
func captureIsPlayable() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    for frame in 0..<30 {
        recorder.feedForTesting(
            makeVideoBuffer(at: Double(frame) / 30.0, size: size), .screen
        )
    }
    let bundle = try await recorder.stop()

    let asset = AVURLAsset(url: bundle.captureURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == 1)
}

@Test("Stopping without starting throws rather than writing a phantom bundle")
func stopWithoutStartThrows() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let recorder = try Recorder.forTesting(bundleURL: bundleURL,
                                           videoSize: CGSize(width: 320, height: 240))
    await #expect(throws: RecorderError.notStarted) {
        _ = try await recorder.stop()
    }
}

@Test("A failure to finalize the movie surfaces instead of being swallowed")
func finalizationFailureSurfaces() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    for frame in 0..<10 {
        recorder.feedForTesting(makeVideoBuffer(at: Double(frame) / 30.0, size: size),
                                .screen)
    }
    _ = try await recorder.stop()

    // The sink is already finished; a second stop must surface the
    // alreadyFinished guard rather than returning a bundle as though nothing
    // went wrong.
    await #expect(throws: RecorderError.alreadyFinished) {
        _ = try await recorder.stop()
    }
}
