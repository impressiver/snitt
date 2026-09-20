// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
    //
    // AVAssetWriterInput silently drops a buffer when it is not ready for
    // more media data (§4.5 — capture delivery must never block on the
    // encoder). Under CPU contention most appends can be refused, so a
    // fixed count of `append` calls does not guarantee any particular
    // amount of media time actually reaches the writer: far less than the
    // 1s `movieFragmentInterval` can land, no fragment is ever flushed,
    // and the file stays at 0 bytes forever — no amount of polling helps,
    // because the flush this test waits for is never coming.
    //
    // Retry each frame until the sink's own accepted-frame counter
    // confirms it was actually taken, so the media that lands always
    // spans enough presentation time to cross the fragment interval,
    // regardless of how many attempts that needs under load. This never
    // blocks a thread: `Task.yield()` cooperatively suspends so the
    // writer's internal queue gets a chance to drain and flip readiness
    // back on.
    // WHAT IS ACTUALLY REQUIRED is enough accepted PRESENTATION TIME to cross
    // the fragment interval. A frame count stood in for that, and the stand-in
    // is what flaked: CI accepted 112 frames where the test demanded 120 and
    // failed — though 112 frames at 60fps is 1.85s, which clears the 1s
    // interval comfortably. The property held; the proxy for it did not.
    //
    // Both the loop and the assertion are in seconds now, derived from the
    // sink's own interval rather than a second copy of it.
    let framesPerSecond = 60.0
    let fragmentInterval = AssetWriterSink.movieFragmentInterval.seconds
    let requiredSpan = fragmentInterval * 1.5
    // Frame n sits at n/60, so N accepted frames span (N-1)/60: the first
    // contributes a timestamp, not a duration.
    func acceptedSpan() -> Double {
        max(0, Double(sink.acceptedVideoFrameCount() - 1)) / framesPerSecond
    }

    var frame = 0
    // Generous, because it only binds when something is wrong: the loop leaves
    // the moment the span is reached, so a fast machine pays nothing for the
    // headroom. Ten seconds was a false economy that turned a slow runner into
    // a red build — CI is virtualised, the GPU is paravirtualised, and frame
    // acceptance there is an order of magnitude slower than on a developer's
    // machine.
    let retryDeadline = ContinuousClock.now + .seconds(45)
    while acceptedSpan() < requiredSpan {
        if ContinuousClock.now >= retryDeadline { break }
        let acceptedBefore = sink.acceptedVideoFrameCount()
        try sink.append(makeVideoBuffer(at: Double(frame) / framesPerSecond, size: size),
                        to: .video)
        if sink.acceptedVideoFrameCount() > acceptedBefore {
            frame += 1
        } else {
            await Task.yield()
        }
    }
    #expect(acceptedSpan() >= requiredSpan,
            """
            accepted \(sink.acceptedVideoFrameCount()) frames spanning \(acceptedSpan())s, \
            need \(requiredSpan)s to be sure the \(fragmentInterval)s fragment interval \
            was crossed
            """)

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

    // HONESTY, because this assertion is weaker than its name (#203).
    //
    // `size > 0` does NOT prove a fragment was flushed. Measured while fixing
    // the flake above: the file is 811 bytes with `movieFragmentInterval` set
    // and 811 bytes with it removed, and it never grows past that — 4s of
    // media, 4s of wall time, unchanged either way. Those bytes are the header
    // `AVAssetWriter` writes at `begin`. Deleting the line this test exists to
    // protect leaves it green, which is the definition of a test that is not
    // testing.
    //
    // Left in place rather than deleted: it still pins that `begin` writes
    // SOMETHING and that the sink survives an unfinalized teardown. What it
    // cannot tell you is whether a crashed recording is recoverable, which is
    // the question #203 asks with a real capture instead of synthetic buffers.
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
