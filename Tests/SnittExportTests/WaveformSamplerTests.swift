// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AVFoundation
@testable import SnittExport
@testable import SnittDocument

/// Peak sampling for the timeline's audio tracks.
///
/// The assertion that matters is that a tone reads LOUD and silence reads
/// QUIET. A sampler that returned zeros, or ones, or a constant would produce a
/// perfectly plausible-looking flat waveform, and every structural check —
/// right number of tracks, right names, right length — would still pass.
@Suite
struct WaveformSamplerTests {
    private func movie(audioTracks: Int, content: SyntheticAudioContent) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "waveform-\(UUID().uuidString).mov")
        try await writeSyntheticMovie(to: url, seconds: 2.0,
                                      audioTrackCount: audioTracks, audioContent: content)
        return url
    }

    @Test("A tone reads loud and silence reads quiet")
    func toneAndSilenceDiffer() async throws {
        let loud = try await movie(audioTracks: 1, content: .tone)
        defer { try? FileManager.default.removeItem(at: loud) }
        let quiet = try await movie(audioTracks: 1, content: .silent)
        defer { try? FileManager.default.removeItem(at: quiet) }

        let loudPeaks = try #require(try await WaveformSampler.sample(movieAt: loud).first)
        let quietPeaks = try #require(try await WaveformSampler.sample(movieAt: quiet).first)
        #expect(!loudPeaks.peaks.isEmpty, "no samples read at all")

        let loudMax = loudPeaks.peaks.max() ?? 0
        let quietMax = quietPeaks.peaks.max() ?? 0
        #expect(loudMax > 0.1, "a sine wave sampled as near-silent: \(loudMax)")
        #expect(quietMax < loudMax / 4, "silence sampled as loud as a tone: \(quietMax) vs \(loudMax)")
    }

    @Test("Sample count matches the requested rate and the recording's length")
    func sampleCountTracksDuration() async throws {
        let url = try await movie(audioTracks: 1, content: .tone)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try #require(try await WaveformSampler.sample(movieAt: url, samplesPerSecond: 20).first)
        // 2 seconds at 20/sec. Encoders pad, so this is a range, not equality —
        // but an order-of-magnitude miss means the bucketing arithmetic is
        // wrong, which is what this catches.
        #expect(samples.peaks.count > 25 && samples.peaks.count < 60,
                "expected ~40 samples, got \(samples.peaks.count)")
        #expect(samples.samplesPerSecond == 20)
    }

    @Test("Tracks are named from the canonical order, not guessed")
    func tracksAreNamedCanonically() async throws {
        // AssetWriterSink writes [systemAudio, microphone]; index-matching
        // against EditDecisionList's own ["video", "microphone", "systemAudio"]
        // is the defect that once made muting system audio do nothing.
        let url = try await movie(audioTracks: 2, content: .tone)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try await WaveformSampler.sample(movieAt: url)
        #expect(samples.map(\.track) == AudioTrackOrder.canonical)
    }

    @Test("A movie with no audio yields no waveforms rather than failing")
    func noAudioIsEmpty() async throws {
        let url = try await movie(audioTracks: 0, content: .silent)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try await WaveformSampler.sample(movieAt: url).isEmpty)
    }
}
