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

/// A take lands on the MICROPHONE, and the export proves it (D102).
///
/// This suite used to assert the opposite — three audio tracks, narration on
/// its own — which was D93's model. Using the app showed that to be wrong: a
/// lane that only ever carries one thing, a mute and a gain nobody wants to
/// set separately, and three audio sources in a recording that has two.
///
/// The assertions are inverted rather than deleted because the same failure
/// shape still matters. `PreviewController.applyAudioMix` builds from the
/// composition's own tracks, so preview and export can disagree about what
/// exists — adjust a level, hear it change, export a file where it did not.
struct OverdubMixTests {

    private func bundleWithTake(muted: Bool = false,
                                gain: Double = 1.0,
                                takes: Int = 1) async throws -> (SnittBundle, EditDecisionList) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "overdub-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        // TWO audio tracks, because that is what `AssetWriterSink` always
        // writes. The default fixture has none, and a capture with no audio
        // makes this pass against a build that never places the take either.
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 3.0,
                                      audioTrackCount: 2, audioContent: .tone)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        var edl = EditDecisionList()
        edl.trackStates = [
            TrackState(track: "systemAudio"),
            TrackState(track: "microphone", muted: muted, gain: gain),
        ]
        for index in 0..<takes {
            // A REAL audio file per take: the composition only places one it
            // can load, so a stub would silently test the no-take path.
            let filename = "overdub-\(index).m4a"
            try await writeSyntheticMovie(to: bundle.url.appendingPathComponent(filename),
                                          seconds: 1.0, audioTrackCount: 1, audioContent: .tone)
            edl.overdubs.append(Overdub(
                filename: filename,
                durationSeconds: 1.0,
                segments: [OverdubSegment(takeStart: 0,
                                          sourceStart: 0.5 + Double(index),
                                          durationSeconds: 1.0)]))
        }
        return (bundle, edl)
    }

    @Test("A take adds NO audio track — it goes on the microphone")
    func takeDoesNotAddATrack() async throws {
        // THE D102 CHANGE, as the assertion that distinguishes it. Two, not
        // three: the recording has two audio sources and a take is a
        // re-recording of one of them.
        let (bundle, edl) = try await bundleWithTake()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        #expect(built.composition.tracks(withMediaType: .audio).count == 2)
    }

    @Test("Several takes still add no tracks")
    func manyTakesStillAddNoTracks() async throws {
        // A per-take track would have been the easy implementation and would
        // pass the single-take case above.
        let (bundle, edl) = try await bundleWithTake(takes: 3)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        #expect(built.composition.tracks(withMediaType: .audio).count == 2)
    }

    @Test("The microphone still runs the whole length of the recording")
    func microphoneIsNotShortened() async throws {
        // The failure mode of assembling a track from pieces: a gap where a
        // take was placed, or a tail lost because the cursor advanced twice.
        // A three-second capture must produce three seconds of microphone
        // whatever was recorded over it.
        let (bundle, edl) = try await bundleWithTake()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let audio = built.composition.tracks(withMediaType: .audio)
        let microphone = try #require(audio.last)
        #expect(abs(microphone.timeRange.duration.seconds - 3.0) < 0.1,
                "the microphone is \(microphone.timeRange.duration.seconds)s of a 3s recording")
    }

    @Test("Muting the microphone reaches the EXPORT, not only the preview")
    func mutedMicrophoneIsInTheExportedMix() async throws {
        let (bundle, edl) = try await bundleWithTake(muted: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        let mix = try #require(built.audioMix, "a muted track produced no mix at all")
        let audio = built.composition.tracks(withMediaType: .audio)
        // Parameters for the right NUMBER of tracks is what distinguishes
        // "the mix covers the recording" from "the mix covers something".
        #expect(mix.inputParameters.count == audio.count)
    }

    @Test("Gain reaches the export as well")
    func gainIsInTheExportedMix() async throws {
        // Mute and gain are different fields and a fix could reach one and not
        // the other — `needsMix` asks about both.
        let (bundle, edl) = try await bundleWithTake(gain: 0.25)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let mix = try #require(built.audioMix)
        #expect(mix.inputParameters.count
                == built.composition.tracks(withMediaType: .audio).count)
    }

    @Test("A take at unity still needs no mix")
    func unchangedTakeNeedsNoMix() async throws {
        // Nil and empty are different answers, and the exporter treats nil as
        // "nothing to apply" — so a take at unity must not force a mix, or
        // every over-dubbed recording would lose passthrough twice over.
        let (bundle, edl) = try await bundleWithTake()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        #expect(built.audioMix == nil)
    }

    @Test("A take still disqualifies passthrough")
    func takeDisqualifiesPassthrough() {
        // The samples for the stretch a take covers are not in `capture.mov`,
        // so there is nothing to copy — a different fact from a level change,
        // with a different remedy.
        var edl = EditDecisionList()
        edl.overdubs = [Overdub(filename: "t.m4a", durationSeconds: 1,
                                segments: [OverdubSegment(takeStart: 0, sourceStart: 0,
                                                          durationSeconds: 1)])]
        #expect(PassthroughEligibility.disqualifier(
            resolution: .source, maxSizeBytes: nil, clicks: [],
            edl: edl, hasAudioMix: false) == .overdub)
    }
}

/// That the take's AUDIO is actually in the microphone track.
///
/// Reported as "it doesn't play the overdubbed tracks". Every assertion in
/// `OverdubMixTests` above is about the SHAPE of the composition — how many
/// tracks, how long, what the mix covers — and a composition can have exactly
/// the right shape while playing none of the take.
///
/// `AVCompositionTrack.segments` names the file behind every stretch, which is
/// the difference between "the microphone is three seconds long" and "these
/// three seconds come from the take".
struct OverdubPlaybackTests {

    private func bundleWithTake() async throws -> (SnittBundle, EditDecisionList, String) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "playback-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 6.0,
                                      audioTrackCount: 2, audioContent: .tone)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        let filename = "overdub-take.m4a"
        try await writeSyntheticMovie(to: bundle.url.appendingPathComponent(filename),
                                      seconds: 2.0, audioTrackCount: 1, audioContent: .tone)
        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "systemAudio"), TrackState(track: "microphone")]
        edl.overdubs = [Overdub(filename: filename, durationSeconds: 2.0,
                                segments: [OverdubSegment(takeStart: 0, sourceStart: 2.0,
                                                          durationSeconds: 2.0)])]
        return (bundle, edl, filename)
    }

    @Test("The microphone track actually plays the take's file")
    func microphoneCarriesTheTakeAudio() async throws {
        let (bundle, edl, filename) = try await bundleWithTake()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        let audio = built.composition.tracks(withMediaType: .audio)
        let microphone = try #require(audio.last)
        let sources = microphone.segments.compactMap { $0.sourceURL?.lastPathComponent }
        #expect(sources.contains(filename),
                "the microphone plays \(sources) — the take's audio is not in it")
    }

    @Test("And the capture is still there either side of it")
    func captureSurvivesAroundTheTake() async throws {
        let (bundle, edl, filename) = try await bundleWithTake()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        let microphone = try #require(built.composition.tracks(withMediaType: .audio).last)
        let sources = microphone.segments.compactMap { $0.sourceURL?.lastPathComponent }
        #expect(sources.contains("capture.mov"), "the capture vanished: \(sources)")
        #expect(sources.contains(filename))
        // Three stretches: capture, take, capture — an empty segment in the
        // middle would mean the take was skipped and the gap left silent.
        #expect(microphone.segments.allSatisfy { !$0.isEmpty },
                "the microphone has an empty stretch where the take should be")
    }
}

/// That a take REPLACES in place, rather than lengthening the microphone.
///
/// Reported as "the original microphone transcription gets offset by the
/// length of the overdub". The transcript maps source time to output through
/// `keptRanges` alone — it knows nothing about takes — so if a take made the
/// microphone track longer than the picture, every captured word after it
/// would be heard late by exactly the take's length while the caption stayed
/// put. Which is the reported symptom, stated as a duration.
struct OverdubTimingTests {

    private func bundleWithTake(takeSeconds: Double,
                                atSource: Double) async throws -> (SnittBundle, EditDecisionList) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "timing-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 6.0,
                                      audioTrackCount: 2, audioContent: .tone)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        let filename = "overdub-timing.m4a"
        try await writeSyntheticMovie(to: bundle.url.appendingPathComponent(filename),
                                      seconds: takeSeconds, audioTrackCount: 1,
                                      audioContent: .tone)
        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "systemAudio"), TrackState(track: "microphone")]
        edl.overdubs = [Overdub(filename: filename, durationSeconds: takeSeconds,
                                segments: [OverdubSegment(takeStart: 0, sourceStart: atSource,
                                                          durationSeconds: takeSeconds)])]
        return (bundle, edl)
    }

    @Test("The microphone is exactly as long as the picture")
    func microphoneMatchesTheVideo() async throws {
        // THE REPORTED BUG, as the one number that states it. A take that
        // INSERTED rather than replaced would make this longer by the take's
        // length, and everything after it would play late.
        let (bundle, edl) = try await bundleWithTake(takeSeconds: 2.0, atSource: 2.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        let video = try #require(built.composition.tracks(withMediaType: .video).first)
        let microphone = try #require(built.composition.tracks(withMediaType: .audio).last)
        let mic = microphone.timeRange.duration.seconds
        let pic = video.timeRange.duration.seconds
        #expect(abs(mic - pic) < 0.05, "microphone \(mic)s vs picture \(pic)s")
    }

    @Test("Both audio tracks stay the same length as each other")
    func audioTracksAgree() async throws {
        // System audio is built by the untouched kept-range loop, so it is the
        // control: the microphone drifting away from it is the drift.
        let (bundle, edl) = try await bundleWithTake(takeSeconds: 2.0, atSource: 2.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let audio = built.composition.tracks(withMediaType: .audio)
        #expect(audio.count == 2)
        #expect(abs(audio[0].timeRange.duration.seconds
                    - audio[1].timeRange.duration.seconds) < 0.05,
                "\(audio[0].timeRange.duration.seconds)s vs \(audio[1].timeRange.duration.seconds)s")
    }

    @Test("The capture after a take resumes at the right OUTPUT second")
    func captureResumesOnTime() async throws {
        // Where the drift would actually be audible. The take covers source
        // 2-4 of a 6s recording with no cuts, so the tail must start at output
        // 4 — not at 6, which is where it lands if the take was inserted.
        let (bundle, edl) = try await bundleWithTake(takeSeconds: 2.0, atSource: 2.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

        let microphone = try #require(built.composition.tracks(withMediaType: .audio).last)
        let tail = try #require(microphone.segments.last)
        #expect(abs(tail.timeMapping.target.start.seconds - 4.0) < 0.05,
                "the capture resumes at output \(tail.timeMapping.target.start.seconds)s, not 4s")
        // And it plays the right SOURCE seconds: 4-6, not 2-4 again.
        #expect(abs(tail.timeMapping.source.start.seconds - 4.0) < 0.05,
                "the tail replays source \(tail.timeMapping.source.start.seconds)s")
    }

    @Test("A longer take does not stretch anything")
    func aLongTakeStillReplaces() async throws {
        // Scaled up, because "offset by the length of the overdub" means the
        // error grows with the take — a 4s take would push everything 4s late.
        let (bundle, edl) = try await bundleWithTake(takeSeconds: 4.0, atSource: 1.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let video = try #require(built.composition.tracks(withMediaType: .video).first)
        let microphone = try #require(built.composition.tracks(withMediaType: .audio).last)
        let mic = microphone.timeRange.duration.seconds
        let pic = video.timeRange.duration.seconds
        #expect(abs(mic - pic) < 0.05,
                "a 4s take left the microphone \(mic)s against a \(pic)s picture")
    }
}
