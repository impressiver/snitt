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

@Test("An agent-initiated recording is stamped as such in metadata.json")
func agentProvenanceReachesTheBundle() async throws {
    // Closes finding 6 one layer deeper than `initiator(isAgent:)` can. Every
    // recording shipped as `.human` because `Recorder.init` defaulted to it, so
    // `.agent` had zero references outside its own declaration — including in
    // any bundle Snitt had ever written.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size,
                                           initiator: .agent)
    try await recorder.startForTesting()
    for frame in 0..<5 {
        recorder.feedForTesting(
            makeVideoBuffer(at: Double(frame) / 30.0, size: size), .screen)
    }
    let bundle = try await recorder.stop()

    #expect(try RecordingMetadata.read(from: bundle).initiator == .agent,
            "provenance is the one field whose whole purpose is telling the two apart")
}

@Test("A marker added immediately before stop is in the written bundle")
func markJustBeforeStopSurvives() async throws {
    // The common agent sequence is `record mark` then `record stop`, and this
    // pins that path end to end.
    //
    // It does NOT discriminate the fire-and-forget version this replaced:
    // restoring `Task { await markers.add(...) }` and running this 110 times,
    // including a 20-way concurrent variant, produced no failures. A
    // non-detached Task created inside an actor-isolated method inherits that
    // actor's context, so the write was enqueued ahead of the later stop(),
    // and both operations then serialised on MarkerLog's executor in enqueue
    // order. Neither is guaranteed — actors are reentrant and their executors
    // are not specified FIFO — so the old code worked by scheduler behaviour,
    // not by construction. The ordering guarantee now lives in `mark` being
    // awaited; this test guards the end-to-end path, not that guarantee.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    recorder.feedForTesting(makeVideoBuffer(at: 0, size: size), .screen)

    _ = await recorder.mark(label: "last thing")
    let bundle = try await recorder.stop()

    let events = try EventLog.read(from: bundle).events
    #expect(events.contains { $0.label == "last thing" && $0.kind == .marker })
}
