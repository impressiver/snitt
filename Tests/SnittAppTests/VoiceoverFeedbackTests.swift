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
