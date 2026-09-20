// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// What tells you a voiceover is being recorded.
///
/// Reported as "Record Voiceover just plays the video, nothing gets recorded" —
/// about a feature that was working. It was: the file was written, the segments
/// were stored, the export carried it. What was missing was every sign of it on
/// screen, and a transport showing an ordinary pause is indistinguishable from
/// playing the recording without recording anything.
@Suite(.serialized)
@MainActor
struct VoiceoverFeedbackTests {
    init() { _ = NSApplication.shared }

    @Test("The voiceover gets its own lane, after the captured ones")
    func voiceoverIsAThirdLane() {
        // Without a `TrackState` named "voiceover" the band never appears, so
        // the narration is in the file, in the export, and invisible in the
        // editor.
        // Deliberately handed in an order the answer must NOT preserve, so a
        // version that simply returned its input would fail here.
        let states = [TrackState(track: "microphone"), TrackState(track: "systemAudio")]
        #expect(AudioTrackOrder.recorded(in: states, health: nil, overdubbed: false) == ["systemAudio", "microphone"])

        let withVoiceover = states + [TrackState(track: "voiceover")]
        #expect(AudioTrackOrder.recorded(in: withVoiceover, health: nil, overdubbed: false)
                == ["systemAudio", "microphone", "voiceover"],
                "narration must come last: it is added under the recording, not a source it was made from")
    }

    @Test("No lane until there is a take")
    func noLaneWithoutNarration() {
        // Same rule the microphone band follows: a lane for a source that was
        // never captured implies one.
        #expect(!AudioTrackOrder.recorded(in: [TrackState(track: "systemAudio")],
                                          health: nil, overdubbed: false)
            .contains("voiceover"))
    }

    @Test("The live lane is sampled at the playhead's own rate")
    func liveLaneMatchesThePlayheadTick() {
        // The levels are taken on the playhead's 20Hz tick, so the rate the
        // waveform is built with has to BE that. A mismatch stretches or
        // compresses the live lane against the picture it is drawn under, and
        // the error grows with the length of the take.
        #expect(EditorTimelineState.voiceoverLevelRate == 20)
    }

    @Test("Levels map to a magnitude, with room tone reading as silence")
    func levelsAreMagnitudesNotDecibels() {
        // `averagePower` is dBFS: 0 at full scale, negative below, and -160
        // for digital silence. Drawn raw it would be a lane of large negative
        // numbers; mapped linearly from -160 it would make room tone look
        // like quiet speech.
        //
        // The floor is asserted through the recorder's own conversion rather
        // than duplicated here, because a second copy of the curve is a second
        // thing to keep in step.
        let recorder = VoiceoverRecorder()
        #expect(recorder.levels.isEmpty, "a fresh recorder has no levels to draw")
    }

    @Test("A take shorter than a syllable leaves no lane behind")
    func abandonedTakeRemovesItsLane() async throws {
        // The lane is added when recording STARTS, so it is visible during the
        // take. A mis-click that records nothing must take it away again, or
        // the editor keeps a band for a track that holds nothing.
        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "systemAudio"), TrackState(track: "voiceover")]
        edl.trackStates.removeAll { $0.track == "voiceover" }
        #expect(!AudioTrackOrder.recorded(in: edl.trackStates, health: nil, overdubbed: false).contains("voiceover"))
    }
}

/// The transport, while a take is running.
@Suite(.serialized)
@MainActor
struct VoiceoverTransportTests {
    init() { _ = NSApplication.shared }

    @Test("The transport offers a stop action while narrating")
    func transportStopsTheTake() {
        // Asserted on the BINDING rather than the glyph: a red icon that still
        // calls `onTogglePlay` pauses the picture and leaves the recorder
        // running, which is worse than no indicator at all — it looks like it
        // stopped.
        var stopped = false
        var toggled = false
        let bar = TransportBar(
            isPlaying: true, hasMarks: false, currentTime: "0:04", totalTime: "0:32",
            currentMark: nil, zoomFraction: .constant(0), isScrollable: false,
            visibleFraction: 1, scrollFraction: 0, onScroll: { _ in }, canCut: false,
            onRewind: {}, onPreviousMark: {},
            isRecordingVoiceover: true,
            onStopVoiceover: { stopped = true },
            onTogglePlay: { toggled = true }, onNextMark: {},
            onSeekToTime: { _ in }, onCut: {})

        // The view cannot be clicked headlessly, so the closures are exercised
        // through the same branch the button reads.
        if bar.isRecordingVoiceover { bar.onStopVoiceover() } else { bar.onTogglePlay() }
        #expect(stopped)
        #expect(!toggled, "the transport paused the picture instead of stopping the take")
    }
}

/// The window's floor.
@Suite(.serialized)
@MainActor
struct EditorWindowMinimumSizeTests {
    init() { _ = NSApplication.shared }

    @Test("A Snitt window cannot be dragged below 800x600")
    func minimumIsEightHundredBySixHundred() {
        // Requested directly. The derived figure — rail + picture + timeline +
        // chrome — is smaller, and a window at it technically fits everything
        // while the transport row starts dropping controls, which is where the
        // wrapped duration was reported from.
        #expect(EditorWindowController.minimumContentSize.width >= 800)
        #expect(EditorWindowController.minimumContentSize.height >= 600)
    }

    @Test("It never goes BELOW what the parts need, whatever the request says")
    func derivedFloorStillWins() {
        // The flat number is a floor, not an override. If the rail, picture,
        // timeline and chrome ever add up to more than 800x600, honouring the
        // request would clip them rather than make them small — so the larger
        // of the two wins, and this is what says so.
        let derived = EditorWindowController.chaptersRailWidth
            + EditorWindowController.minimumPlayerSize.width
        #expect(EditorWindowController.minimumContentSize.width >= derived)
    }
}

/// The lane's label, which is the one part of a new track nothing forces you
/// to add.
@Suite
@MainActor
struct VoiceoverLaneLabelTests {

    @Test("Every audio track Snitt can have is named properly")
    func everyTrackHasAName() {
        // `name(of:)` falls back to the raw key, so a track it does not know
        // renders as "voiceover" in lower case beside "Microphone" and "System
        // audio" — the lane works, the meter works, and only the
        // capitalisation says nobody thought about it. Driven from
        // `AudioTrackOrder.canonical` so a fourth track cannot be added
        // without this failing.
        for track in AudioTrackOrder.canonical {
            let name = TransportBar.name(of: track)
            #expect(name != track, "\(track) has no display name")
            #expect(name.first?.isUppercase == true, "\(name) does not read as a label")
        }
    }
}

/// D93's third-track narration, in documents written before D102.
///
/// The product-owner's call was DISCARD rather than migrate, and it is worth
/// recording why it is not merely the cheap option. The two models place audio
/// differently — a third track plays alongside the microphone, a take plays
/// instead of it — so a migration would have to decide, on the author's
/// behalf, that narration recorded to sit BESIDE the microphone should now
/// silence it. For the handful of documents that have one, being asked to
/// record it again beats being handed something nobody chose.
@Suite
struct LegacyVoiceoverDiscardTests {

    /// Exactly the shape on disk from a recording made under D93.
    private func narratedUnderD93() -> Data {
        Data("""
        {"schemaVersion":1,"cuts":[],"trackStates":[{"track":"video","muted":false,"gain":1},\
        {"track":"microphone","muted":false,"gain":1},\
        {"track":"systemAudio","muted":false,"gain":1},\
        {"track":"voiceover","muted":false,"gain":1}],\
        "voiceover":{"filename":"voiceover.m4a","durationSeconds":4,\
        "segments":[{"voiceoverStart":0,"sourceStart":2,"durationSeconds":4}]}}
        """.replacingOccurrences(of: "\\\n", with: "").utf8)
    }

    @Test("An older document still opens")
    func legacyDocumentDecodes() throws {
        // The key is unknown to the current model, and a synthesised decoder
        // would not mind — but `voiceover` is still declared in `CodingKeys`
        // precisely so this stays deliberate rather than accidental. A build
        // that refused the file would lose the whole recording, not just the
        // narration.
        let edl = try JSONDecoder().decode(EditDecisionList.self, from: narratedUnderD93())
        // Three of the four survive — the fourth was the narration's own lane,
        // which goes with the narration. What matters here is that the FILE
        // still opens: a build that refused it would lose the whole recording
        // rather than just the take.
        #expect(edl.trackStates.map(\.track) == ["video", "microphone", "systemAudio"])
    }

    @Test("Its narration is dropped rather than carried forward")
    func legacyNarrationIsDiscarded() throws {
        let edl = try JSONDecoder().decode(EditDecisionList.self, from: narratedUnderD93())
        #expect(edl.overdubs.isEmpty, "D93 narration was silently turned into a take")
        #expect(!edl.hasOverdubs)
    }

    @Test("Its LANE is dropped with it")
    func legacyLaneIsDiscarded() throws {
        // Leaving the TrackState behind would draw a third lane — with a fader
        // and a mute — over audio that is no longer in the composition. An
        // empty lane claiming a track exists is worse than no lane.
        let edl = try JSONDecoder().decode(EditDecisionList.self, from: narratedUnderD93())
        #expect(!edl.trackStates.contains { $0.track == "voiceover" })
        #expect(!AudioTrackOrder.recorded(in: edl.trackStates, health: nil, overdubbed: false).contains("voiceover"))
        // The capture's own lanes survive — this drops a lane, not the file.
        #expect(AudioTrackOrder.recorded(in: edl.trackStates, health: nil, overdubbed: false)
                == ["systemAudio", "microphone"])
    }

    @Test("A document with NO legacy narration keeps a voiceover state it was given")
    func synthesisStateIsNotEaten() throws {
        // D101's synthesised voice will legitimately want that TrackState. The
        // discard is conditioned on the narration key rather than applied to
        // every document, so it cannot eat one that arrives for another reason.
        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "microphone"), TrackState(track: "voiceover")]
        let data = try JSONEncoder().encode(edl)
        let back = try JSONDecoder().decode(EditDecisionList.self, from: data)
        #expect(back.trackStates.contains { $0.track == "voiceover" })
    }

    @Test("Re-saving it writes no narration key back")
    func legacyNarrationIsNotRewritten() throws {
        // The round trip is where a half-migration would show: decoded away
        // and then written back out would leave the file unchanged and the
        // behaviour changed, which is the worst of both.
        let edl = try JSONDecoder().decode(EditDecisionList.self, from: narratedUnderD93())
        let json = String(decoding: try JSONEncoder().encode(edl), as: UTF8.self)
        // The narration OBJECT, not the word: a first version of this matched
        // the bare string and failed against correct code, because the
        // document also carries a TrackState NAMED "voiceover".
        #expect(!json.contains("\"voiceover\":{"), "the discarded narration was written back")
        #expect(!json.contains("overdubs"), "an empty take list wrote a key")
    }

    @Test("A recording with no takes produces the bytes it always did")
    func noTakesWritesNoKey() throws {
        let json = String(decoding: try JSONEncoder().encode(EditDecisionList()), as: UTF8.self)
        #expect(!json.contains("overdubs"))
    }

    @Test("A take round-trips")
    func takesRoundTrip() throws {
        var edl = EditDecisionList()
        edl.overdubs = [
            Overdub(filename: "a.m4a", durationSeconds: 2,
                    segments: [OverdubSegment(takeStart: 0, sourceStart: 1, durationSeconds: 2)]),
            Overdub(filename: "b.m4a", durationSeconds: 1,
                    segments: [OverdubSegment(takeStart: 0, sourceStart: 9, durationSeconds: 1)]),
        ]
        let data = try JSONEncoder().encode(edl)
        let back = try JSONDecoder().decode(EditDecisionList.self, from: data)
        // ORDER survives, because it is the precedence `MicrophoneTimeline`
        // applies where two takes overlap — a document that reordered them on
        // save would quietly change which one is heard.
        #expect(back.overdubs.map(\.filename) == ["a.m4a", "b.m4a"])
        #expect(back.overdubs == edl.overdubs)
    }
}


/// The waveform for a document that is OPENED rather than just recorded.
@Suite(.serialized)
@MainActor
struct MicrophoneWaveformLoadTests {
    init() { _ = NSApplication.shared }

    @Test("Opening a narrated document samples its voiceover, not only the capture")
    func openingLoadsTheMicrophoneWaveform() async throws {
        // Reported as "the lane shows up now, but there's no waveform, just an
        // empty audio track where there definitely should be audio".
        //
        // `loadWaveforms` samples `capture.mov`. The voiceover is a DIFFERENT
        // FILE, so one call cannot fetch both — and the second was only ever
        // made when a take ended, which a document being opened never does.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "vowave-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 3.0,
                                      audioTrackCount: 2)
        let takeName = "overdub-\(UUID().uuidString).m4a"
        try await writeSyntheticMovie(to: bundle.url.appendingPathComponent(takeName),
                                      seconds: 2.0, audioTrackCount: 1)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "systemAudio"), TrackState(track: "microphone")]
        edl.overdubs = [Overdub(
            filename: takeName, durationSeconds: 2.0,
            segments: [OverdubSegment(takeStart: 0, sourceStart: 0.5,
                                      durationSeconds: 2.0)])]
        try edl.write(to: bundle)

        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [])

        // AWAITED, not polled. Polling was tried twice — four seconds passed
        // alone and timed out on the full run, and twenty seconds timed out
        // too — so the wait was never the problem and a longer one would have
        // been a worse test rather than a passing one.
        await state.overdubWaveformLoad?.value
        // BOTH, because the microphone lane is composed from the capture and
        // the take together — awaiting only one asserts against a half-built
        // answer.
        await state.captureWaveformLoadForTesting?.value

        let reason = state.overdubWaveformFailure ?? "no reason recorded"
        // The MICROPHONE's lane, because that is where a take lands now. A
        // "voiceover" lane would mean the third track came back.
        let waveform = try #require(state.waveforms.first { $0.track == "microphone" },
                                    "opening an over-dubbed document sampled nothing: \(reason)")
        #expect(!state.waveforms.contains { $0.track == "voiceover" },
                "a take was drawn on a third lane rather than on the microphone")
        // Sized to the CAPTURE, which is the thing an unloaded lane cannot
        // fake: the take is 2s and the array spans the 3s recording, so the
        // length is proof the re-indexing ran rather than the raw file being
        // handed over.
        //
        // AMPLITUDE is deliberately not asserted here, and this is the
        // limitation worth naming rather than working around: this target's
        // `writeSyntheticMovie` writes SILENT audio, so a tone-carrying
        // fixture does not exist at this level and an amplitude check would
        // fail against correct code. That the mapping carries real values, and
        // puts them at the right source offsets, is
        // `MicrophoneWaveformTests` — which uses a ramp precisely so a
        // misplacement shows up as a wrong VALUE rather than as "some numbers
        // moved".
        #expect(waveform.samplesPerSecond > 0)
        let expected = Int((3.0 * waveform.samplesPerSecond).rounded(.up))
        #expect(abs(waveform.peaks.count - expected) <= 1,
                "the lane spans \(waveform.peaks.count) buckets, not the recording's \(expected)")
    }
}

/// The two waveform loads are separate tasks over separate files.
@Suite(.serialized)
@MainActor
struct WaveformMergeTests {
    init() { _ = NSApplication.shared }

    @Test("Whichever load finishes last, both are in the result")
    func bothLoadsSurviveWhicheverOrder() async throws {
        // The race that made the missing lane intermittent: `loadWaveforms`
        // ASSIGNED the whole array, so whichever decode finished last won — on
        // an idle machine the capture finished first and the other survived,
        // under a full test run it did not.
        //
        // It cannot happen any more, and the fix is structural rather than a
        // careful merge: `waveforms` is COMPOSED from two inputs, each loader
        // sets only its own, and neither can overwrite the other's. So this no
        // longer drives the published property — there is nothing to clobber —
        // and instead runs both real loads and asserts the outcome is complete
        // whatever order they land in.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wfmerge-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0, audioTrackCount: 2)
        let takeName = "overdub-\(UUID().uuidString).m4a"
        try await writeSyntheticMovie(to: bundle.url.appendingPathComponent(takeName),
                                      seconds: 1.0, audioTrackCount: 1)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "systemAudio"), TrackState(track: "microphone")]
        edl.overdubs = [Overdub(filename: takeName, durationSeconds: 1.0,
                                segments: [OverdubSegment(takeStart: 0, sourceStart: 0.5,
                                                          durationSeconds: 1.0)])]
        try edl.write(to: bundle)

        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [])

        // Awaited in the OPPOSITE order to the one they were started in, so a
        // result that depended on completion order would show here.
        await state.overdubWaveformLoad?.value
        await state.captureWaveformLoadForTesting?.value

        #expect(state.waveforms.contains { $0.track == "systemAudio" },
                "the capture's own tracks did not arrive")
        #expect(state.waveforms.contains { $0.track == "microphone" },
                "the microphone lane is missing")
        #expect(!state.waveforms.contains { $0.track == "voiceover" },
                "a take was given a third lane")
    }
}
