import Testing
import Foundation
import AVFoundation
@testable import SnittCapture

private func tempMovieURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")
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
    try await Task.sleep(for: .milliseconds(500))

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size_ = attributes[.size] as! Int
    #expect(size_ > 0, "a crash must leave bytes on disk, not an empty file")
}
