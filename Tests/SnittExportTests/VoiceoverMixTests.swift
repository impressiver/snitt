// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// Is the voiceover an INDEPENDENT track — one that mute and gain reach?
///
/// It is a separate file in the bundle, a separate composition track, and a
/// separate lane with its own `TrackState`. It was not, however, in the
/// exported mix: `build` assembled that from `audioTrackPairs`, which pairs
/// the CAPTURE's sources with their destinations, and a voiceover is a
/// destination with no source in that asset.
///
/// The failure shape is the dangerous one. `PreviewController.applyAudioMix`
/// builds from the composition's own tracks and so saw all three — adjust the
/// level, hear it change, export a file where it did not.
struct VoiceoverMixTests {

    private func bundleWithVoiceover(muted: Bool = false,
                                     gain: Double = 1.0) async throws -> (SnittBundle, EditDecisionList) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "vomix-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        // TWO audio tracks, because that is what `AssetWriterSink` always
        // writes and what the voiceover's index-2 slot depends on. The default
        // fixture has none, and a capture with no audio makes this test pass
        // against a build that never adds the voiceover either.
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 3.0,
                                      audioTrackCount: 2, audioContent: .tone)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        // A real audio file for the voiceover: the composition only adds the
        // track when it can load one, so a stub would silently test the
        // no-voiceover path and pass.
        try await writeSyntheticMovie(to: bundle.voiceoverURL, seconds: 2.0,
                                      audioTrackCount: 1, audioContent: .tone)

        var edl = EditDecisionList()
        edl.trackStates = [
            TrackState(track: "systemAudio"),
            TrackState(track: "microphone"),
            TrackState(track: "voiceover", muted: muted, gain: gain),
        ]
        edl.voiceover = VoiceoverTrack(
            filename: bundle.voiceoverURL.lastPathComponent,
            durationSeconds: 2.0,
            segments: [VoiceoverSegment(voiceoverStart: 0, sourceStart: 0.5,
                                        durationSeconds: 2.0)])
        return (bundle, edl)
    }

    @Test("The composition carries the voiceover as its own audio track")
    func voiceoverIsItsOwnCompositionTrack() async throws {
        let (bundle, edl) = try await bundleWithVoiceover()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        // Three, not two-with-narration-mixed-in. §4.5 makes `capture.mov`
        // immutable, so narration cannot be folded into an existing track.
        #expect(built.composition.tracks(withMediaType: .audio).count == 3)
    }

    @Test("Muting the voiceover reaches the EXPORT, not only the preview")
    func mutedVoiceoverIsInTheExportedMix() async throws {
        // The defect, stated as the assertion that would have caught it. The
        // built mix had parameters for two tracks and the voiceover was the
        // third, so a muted narration exported at full volume.
        let (bundle, edl) = try await bundleWithVoiceover(muted: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        let mix = try #require(built.audioMix, "a muted track produced no mix at all")
        let audio = built.composition.tracks(withMediaType: .audio)
        let voiceoverTrackID = try #require(audio.last).trackID
        #expect(mix.inputParameters.contains { $0.trackID == voiceoverTrackID },
                "the exported mix has no parameters for the voiceover track")
        // Count, too: parameters for the right NUMBER of tracks is what
        // distinguishes "the voiceover was added" from "something was".
        #expect(mix.inputParameters.count == audio.count)
    }

    @Test("Gain on the voiceover reaches the export as well")
    func gainedVoiceoverIsInTheExportedMix() async throws {
        // Mute and gain are different fields and a fix could reach one and not
        // the other — `needsMix` asks about both, so a mix built for a gain
        // change has to cover the same tracks.
        let (bundle, edl) = try await bundleWithVoiceover(gain: 0.25)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        let mix = try #require(built.audioMix)
        let audio = built.composition.tracks(withMediaType: .audio)
        #expect(mix.inputParameters.count == audio.count)
    }

    @Test("A document with narration at unity still needs no mix")
    func unchangedVoiceoverNeedsNoMix() async throws {
        // Nil and empty are different answers, and the exporter treats nil as
        // "nothing to apply" — so a voiceover at unity must not force a mix,
        // or every narrated recording would lose passthrough twice over.
        let (bundle, edl) = try await bundleWithVoiceover()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        #expect(built.audioMix == nil)
    }
}
