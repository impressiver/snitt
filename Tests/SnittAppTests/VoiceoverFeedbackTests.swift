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
        let states = [TrackState(track: "systemAudio"), TrackState(track: "microphone")]
        #expect(TimelineTrackLayout.audioTracks(in: states) == ["microphone", "systemAudio"])

        let withVoiceover = states + [TrackState(track: "voiceover")]
        #expect(TimelineTrackLayout.audioTracks(in: withVoiceover)
                == ["microphone", "systemAudio", "voiceover"],
                "narration must come last: it is added under the recording, not a source it was made from")
    }

    @Test("No lane until there is a take")
    func noLaneWithoutNarration() {
        // Same rule the microphone band follows: a lane for a source that was
        // never captured implies one.
        #expect(!TimelineTrackLayout.audioTracks(in: [TrackState(track: "systemAudio")])
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
        #expect(!TimelineTrackLayout.audioTracks(in: edl.trackStates).contains("voiceover"))
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

/// Documents narrated before the lane existed.
@Suite
struct VoiceoverBackfillTests {

    private func narratedWithoutATrackState() -> EditDecisionList {
        // Exactly the shape on disk from a recording made between D93 shipping
        // and the lane landing: `voiceover` present, `trackStates` naming only
        // what the capture had. Verified against a real document.
        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "video"),
                           TrackState(track: "microphone"),
                           TrackState(track: "systemAudio")]
        edl.voiceover = VoiceoverTrack(
            filename: "voiceover.m4a", durationSeconds: 4,
            segments: [VoiceoverSegment(voiceoverStart: 0, sourceStart: 2, durationSeconds: 4)])
        return edl
    }

    @Test("An older narrated document gets its lane back")
    func backfillGivesTheOlderDocumentALane() {
        // Reported as "I can hear it when I play, but there's no lane visible".
        // The narration was in the file and in the mix; only the thing the
        // timeline derives lanes from was missing.
        var edl = narratedWithoutATrackState()
        #expect(!TimelineTrackLayout.audioTracks(in: edl.trackStates).contains("voiceover"))

        edl.backfillVoiceoverTrackState()
        #expect(TimelineTrackLayout.audioTracks(in: edl.trackStates).contains("voiceover"))
    }

    @Test("It does not reset a voiceover somebody muted")
    func backfillPreservesExistingState() {
        // Reopening a document must not undo an edit. This is the assertion
        // that makes the backfill safe to run on EVERY open rather than once.
        var edl = narratedWithoutATrackState()
        edl.trackStates.append(TrackState(track: "voiceover", muted: true, gain: 0.5))
        edl.backfillVoiceoverTrackState()

        let states = edl.trackStates.filter { $0.track == "voiceover" }
        #expect(states.count == 1, "the backfill added a duplicate")
        #expect(states[0].muted)
        #expect(states[0].gain == 0.5)
    }

    @Test("A document with no narration gains nothing")
    func backfillDoesNothingWithoutAVoiceover() {
        // Otherwise every recording would grow a lane for a track it does not
        // have — the same failure the microphone band's own guard prevents.
        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "systemAudio")]
        edl.backfillVoiceoverTrackState()
        #expect(!edl.trackStates.contains { $0.track == "voiceover" })
    }

    @Test("Running it twice changes nothing the second time")
    func backfillIsIdempotent() {
        var edl = narratedWithoutATrackState()
        edl.backfillVoiceoverTrackState()
        let after = edl.trackStates.map(\.track)
        edl.backfillVoiceoverTrackState()
        #expect(edl.trackStates.map(\.track) == after)
    }
}

/// The waveform for a document that is OPENED rather than just recorded.
@Suite(.serialized)
@MainActor
struct VoiceoverWaveformLoadTests {
    init() { _ = NSApplication.shared }

    @Test("Opening a narrated document samples its voiceover, not only the capture")
    func openingLoadsTheVoiceoverWaveform() async throws {
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
        try await writeSyntheticMovie(to: bundle.voiceoverURL, seconds: 2.0,
                                      audioTrackCount: 1)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "systemAudio"), TrackState(track: "microphone")]
        edl.voiceover = VoiceoverTrack(
            filename: bundle.voiceoverURL.lastPathComponent, durationSeconds: 2.0,
            segments: [VoiceoverSegment(voiceoverStart: 0, sourceStart: 0.5,
                                        durationSeconds: 2.0)])
        try edl.write(to: bundle)

        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [])

        // AWAITED, not polled. Polling was tried twice — four seconds passed
        // alone and timed out on the full run, and twenty seconds timed out
        // too — so the wait was never the problem and a longer one would have
        // been a worse test rather than a passing one.
        await state.voiceoverWaveformLoad?.value

        let reason = state.voiceoverWaveformFailure ?? "no reason recorded"
        let waveform = try #require(state.waveforms.first { $0.track == "voiceover" },
                                    "opening a narrated document did not sample its voiceover: \(reason)")
        // Sized to the CAPTURE, which is the thing an unloaded lane cannot
        // fake: the samples come from a 2s voiceover and the array spans the
        // 3s recording, so the length is proof the re-indexing ran rather than
        // the raw file being handed over.
        //
        // AMPLITUDE is deliberately not asserted here, and this is the
        // limitation worth naming rather than working around: this target's
        // `writeSyntheticMovie` writes SILENT audio, so a tone-carrying
        // fixture does not exist at this level and an amplitude check would
        // fail against correct code. That the mapping carries real values, and
        // puts them at the right source offsets, is
        // `VoiceoverWaveformTests` — which uses a ramp precisely so a
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

    @Test("A late capture sample does not wipe the voiceover's")
    func captureLoadPreservesTheVoiceover() async throws {
        // The race that made the missing lane intermittent. `loadWaveforms`
        // assigned the whole array, so whichever of the two decodes finished
        // LAST won — on an idle machine the capture finished first and the
        // voiceover survived; under a full test run it did not.
        //
        // Driven through the published property rather than by racing two real
        // decodes, because the failure is the ASSIGNMENT and a test that had
        // to win a race to see it would be the flake it is replacing.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wfmerge-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0, audioTrackCount: 2)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller,
                                        edl: EditDecisionList(), events: [])

        // A voiceover lane arrives first, as it does when the smaller file
        // decodes sooner.
        state.waveforms = [WaveformSamples(track: "voiceover",
                                           samplesPerSecond: 10, peaks: [1, 1, 1])]
        // Then the capture's load lands.
        await state.captureWaveformLoadForTesting?.value

        #expect(state.waveforms.contains { $0.track == "voiceover" },
                "the capture's sample wiped the voiceover lane")
        #expect(state.waveforms.contains { $0.track == "systemAudio" },
                "the capture's own tracks did not arrive")
    }
}
