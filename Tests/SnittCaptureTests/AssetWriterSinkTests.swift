import Testing
import Foundation
import AVFoundation
@testable import SnittCapture

private func tempMovieURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")
}

/// `AVAssetWriter` flushes movie fragments to disk on its own internal
/// queue; appending samples does not make the write happen synchronously,
/// nor within any fixed wall-clock delay. There is no completion callback
/// for this (the writer's fragment-flush is distinct from the segment-data
/// delegate used for HLS-style fMP4 output), so the only honest way to
/// observe "bytes eventually landed on disk" is to poll for the condition
/// with a generous timeout rather than assume a fixed sleep is enough.
/// This never blocks a thread — each iteration suspends via `Task.sleep`.
private func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(20),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if condition() { return true }
        if ContinuousClock.now >= deadline { return condition() }
        try? await Task.sleep(for: pollInterval)
    }
}

@Test("Writes a movie containing one video and two audio tracks")
func writesThreeTracks() async throws {
    let url = tempMovieURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let size = CGSize(width: 320, height: 240)
    let sink = try AssetWriterSink(outputURL: url, videoSize: size)
    try sink.begin(at: .zero)

    for frame in 0..<30 {
        let t = Double(frame) / 30.0
        try sink.append(makeVideoBuffer(at: t, size: size), to: .video)
        try sink.append(makeAudioBuffer(at: t), to: .systemAudio)
        try sink.append(makeAudioBuffer(at: t), to: .microphone)
    }

    let written = try await sink.finish()
    let asset = AVURLAsset(url: written)

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(videoTracks.count == 1)
    #expect(audioTracks.count == 2)

    let duration = try await asset.load(.duration)
    #expect(duration.seconds > 0)
}

@Test("Appending before begin throws notStarted")
func rejectsAppendBeforeBegin() throws {
    let url = tempMovieURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let size = CGSize(width: 320, height: 240)
    let sink = try AssetWriterSink(outputURL: url, videoSize: size)

    #expect(throws: SinkError.notStarted) {
        try sink.append(makeVideoBuffer(at: 0, size: size), to: .video)
    }
}

@Test("An unfinalized file still has bytes on disk, because fragments are written")
func unfinalizedFileHasBytesOnDisk() async throws {
    let url = tempMovieURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let size = CGSize(width: 320, height: 240)
    let sink = try AssetWriterSink(outputURL: url, videoSize: size)
    try sink.begin(at: .zero)

    // Write two seconds without ever calling finish(), simulating a crash.
    for frame in 0..<120 {
        try sink.append(makeVideoBuffer(at: Double(frame) / 60.0, size: size),
                        to: .video)
    }
    // A fragment flush happens asynchronously on the writer's own queue, so
    // "bytes are on disk" is not true at any deterministic moment right
    // after appending — poll for it instead of assuming a fixed delay
    // suffices (see `waitUntil`).
    let sawBytesOnDisk = await waitUntil {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int ?? 0
        return size > 0
    }
    #expect(sawBytesOnDisk, "a crash must leave bytes on disk, not an empty file")
}

@Test("A rejected buffer is not folded into the health metrics")
func rejectedBuffersAreNotMeasured() async throws {
    // `health.observe` ran BEFORE the `guard started` / `guard !finished`
    // checks, so buffers the sink refused — appended before `begin`, or after
    // `finish` — were still measured. §12.1's numbers are meant to describe
    // what is IN the recording.
    let url = tempMovieURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let size = CGSize(width: 320, height: 240)
    let sink = try AssetWriterSink(outputURL: url, videoSize: size)

    // Before begin: refused.
    #expect(throws: SinkError.notStarted) {
        try sink.append(makeVideoBuffer(at: 0, size: size), to: .video)
    }
    #expect(throws: SinkError.notStarted) {
        try sink.append(makeAudioBuffer(at: 0), to: .microphone)
    }
    #expect(sink.health.result().meanFrameVariance == nil,
            "a frame the sink refused is not part of the recording's health")
    #expect(sink.health.result().micRMS == nil)

    try sink.begin(at: .zero)
    try sink.append(makeVideoBuffer(at: 0, size: size), to: .video)
    _ = try await sink.finish()

    // After finish: refused too.
    #expect(throws: SinkError.alreadyFinished) {
        try sink.append(makeAudioBuffer(at: 1), to: .microphone)
    }
    #expect(sink.health.result().micRMS == nil,
            "audio appended after finalization is in no file and in no metric")
}
