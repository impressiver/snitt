import Testing
import Foundation
import AVFoundation
@testable import SnittExport
@testable import SnittDocument

/// The extractor exists because of a trap the S6 probe hit for real: the
/// recognizer takes the FIRST audio track, and for a mic-only screen recording
/// that is silence — a confident empty transcript, indistinguishable from
/// "nothing was said".
@Suite
struct MicrophoneTrackExtractorTests {
    private func makeBundle(audioTracks: Int) async throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mic-extract-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0,
                                      audioTrackCount: audioTracks,
                                      audioContent: .tone)
        return bundle
    }

    @Test("The SECOND track is extracted — the microphone, not system audio")
    func extractsTheMicrophoneTrack() async throws {
        let bundle = try await makeBundle(audioTracks: 2)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let url = try #require(try await MicrophoneTrackExtractor.extract(from: bundle))
        defer { try? FileManager.default.removeItem(at: url) }

        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1, "the extract should carry exactly the mic track")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 2.0) < 0.3, "duration \(duration) — wrong span extracted")
    }

    @Test("A recording without a microphone yields nil, not an error")
    func noMicIsNil() async throws {
        // Mic off is a normal recording, not a failure — the caller skips
        // transcription rather than reporting anything.
        let bundle = try await makeBundle(audioTracks: 1)   // systemAudio only
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(try await MicrophoneTrackExtractor.extract(from: bundle) == nil)
    }

    @Test("The extract lands in scratch, never inside the bundle")
    func extractStaysOutOfTheBundle() async throws {
        // A sidecar nobody wrote to the schema would look like data on a
        // future read — §7's package holds the recording, not intermediates.
        let bundle = try await makeBundle(audioTracks: 2)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let url = try #require(try await MicrophoneTrackExtractor.extract(from: bundle))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!url.path.hasPrefix(bundle.url.path))
    }
}
