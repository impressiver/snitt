// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

/// Which audio tracks a recording actually has (D110).
///
/// `EditDecisionList.fullRange()` writes a `TrackState` for BOTH audio
/// sources, and `Recorder` writes it at `start()` — before a single sample has
/// arrived. So track presence has never said anything about whether a source
/// was captured, and a recording made with the microphone off drew an empty
/// microphone lane that looked exactly like a recording of someone saying
/// nothing.
///
/// **The evidence is `CaptureHealth`, and what makes it usable is `nil`.**
/// `CaptureSession.start()` adds the `.microphone` and `.audio` stream outputs
/// only when each option is on, so a source that was never enabled delivers no
/// buffers, `HealthSampler` counts no samples, and the RMS is `nil`. A source
/// that WAS enabled has an RMS, possibly zero. Those are different facts and
/// the lane rule turns on exactly that difference.
///
/// **A lane is hidden only for a source that was never captured.** Enabling
/// the microphone is a choice a person made, and the answer to "what did it
/// get" is worth showing even when the answer is room tone, or nothing at all
/// from a muted device — that is the case where seeing the lane matters most.
@Suite("Audio track visibility")
struct AudioTrackVisibilityTests {

    /// The states a real recording carries: `fullRange()`'s, minus the video
    /// entry that is not an audio track.
    private let bothSources = [
        TrackState(track: "video"),
        TrackState(track: "microphone"),
        TrackState(track: "systemAudio"),
    ]

    @Test("A microphone that was never enabled gets no lane")
    func anUnusedMicrophoneIsNotDrawn() {
        // The bug this exists for. WRONG IMPLEMENTATION: deriving the lane
        // from `trackStates` alone, which is what shipped — `fullRange()`
        // writes the microphone state unconditionally at `start()`, so the
        // filter it went through could never remove anything.
        let health = CaptureHealth(micRMS: nil, systemAudioRMS: 0.2)
        #expect(AudioTrackOrder.recorded(in: bothSources, health: health,
                                         overdubbed: false) == ["systemAudio"])
    }

    @Test("A microphone that heard only the room keeps its lane")
    func roomToneIsStillAudioSomebodyAskedFor() {
        // The product ruling, and the reason this is not a threshold. A live
        // microphone in a quiet room has a noise floor, so any "is it loud
        // enough to bother drawing" test would collapse the lane for a
        // recording whose microphone worked perfectly — and the person who
        // switched it on would have no way to tell that from it being off.
        let health = CaptureHealth(micRMS: 0.0004, systemAudioRMS: nil)
        #expect(AudioTrackOrder.recorded(in: bothSources, health: health,
                                         overdubbed: false) == ["microphone"])
    }

    @Test("A microphone that was on and captured pure silence keeps its lane")
    func aDeadMicrophoneIsWorthSeeing() {
        // The case a `> 0` test would get backwards, and the most useful lane
        // in this file: buffers arrived and every sample was zero, which is a
        // muted or dead input device. Hiding it would report "you did not ask
        // for a microphone" about a recording where the microphone was the
        // whole point.
        //
        // It is also why the rule is `nil`, not `== 0`. Digital silence
        // through a float conversion is not reliably bit-exact, so an equality
        // test against zero would fire on some silent recordings and not
        // others — worse than not testing for it at all.
        let health = CaptureHealth(micRMS: 0, systemAudioRMS: 0.2)
        #expect(AudioTrackOrder.recorded(in: bothSources, health: health,
                                         overdubbed: false)
                == ["systemAudio", "microphone"])
    }

    @Test("Over-dubbing brings the microphone lane back")
    func aTakeRestoresTheLane() {
        // D102: a take lands on the MICROPHONE track. So a recording captured
        // with the microphone off and narrated afterwards has microphone audio
        // that no `CaptureHealth` will ever mention — it was not there at
        // capture time, and `meta.json` is written once.
        //
        // WRONG IMPLEMENTATION: consulting health alone, which hides the lane
        // holding the take that was just recorded into it.
        let health = CaptureHealth(micRMS: nil, systemAudioRMS: 0.2)
        #expect(AudioTrackOrder.recorded(in: bothSources, health: health,
                                         overdubbed: true)
                == ["systemAudio", "microphone"])
    }

    @Test("System audio follows the same rule, with no special case")
    func systemAudioIsNotExempt() {
        // Symmetry is the point: `capturesAudio` is an option too, and a
        // recording made without it should not spend a lane saying so. A
        // recording made WITH it that happened to be silent still gets one,
        // for the same reason the microphone does.
        let never = CaptureHealth(micRMS: 0.2, systemAudioRMS: nil)
        #expect(AudioTrackOrder.recorded(in: bothSources, health: never,
                                         overdubbed: false) == ["microphone"])

        let silent = CaptureHealth(micRMS: 0.2, systemAudioRMS: 0)
        #expect(AudioTrackOrder.recorded(in: bothSources, health: silent,
                                         overdubbed: false)
                == ["systemAudio", "microphone"])
    }

    @Test("A recording with no health at all keeps every lane it has")
    func absentEvidenceIsNotEvidenceOfAbsence() {
        // Bundles written before `CaptureHealth` existed, and videos brought
        // in through `VideoImporter`, have no health to consult.
        //
        // WRONG IMPLEMENTATION: treating a missing `health` as missing audio,
        // which collapses every lane on every recording that predates the
        // field — turning a display fix into silent data loss as far as
        // anybody looking at the window can tell.
        #expect(AudioTrackOrder.recorded(in: bothSources, health: nil,
                                         overdubbed: false)
                == ["systemAudio", "microphone"])
    }

    @Test("A source with no TrackState is still absent, however loud")
    func presenceIsStillRequired() {
        // The health test NARROWS the old rule; it does not replace it. A
        // recording whose states list no microphone has no microphone lane
        // even if `micRMS` says otherwise, because the states are what the
        // mix and the gutter address.
        let states = [TrackState(track: "video"), TrackState(track: "systemAudio")]
        let health = CaptureHealth(micRMS: 0.9, systemAudioRMS: 0.2)
        #expect(AudioTrackOrder.recorded(in: states, health: health,
                                         overdubbed: false) == ["systemAudio"])

        // And an over-dub cannot conjure a lane the document does not carry.
        // A lane without a `TrackState` behind it would draw a mute button and
        // a gain slider wired to nothing, since the gutter and the export mix
        // both address the STATES. Committing a take appends to `overdubs` and
        // adds no state, so this pairing is reachable only for a document that
        // lists no microphone at all — an imported video, which writes
        // `EditDecisionList()` rather than `fullRange()`.
        #expect(AudioTrackOrder.recorded(in: states, health: health,
                                         overdubbed: true) == ["systemAudio"])
    }

    @Test("A voiceover lane is presence-gated only — no health field describes it")
    func voiceoverIsUnaffected() {
        // D93's track is composition-only; the recorder never writes it, so
        // `CaptureHealth` has nothing to say about it. It must pass through
        // rather than be hidden for want of a measurement that cannot exist.
        let states = bothSources + [TrackState(track: "voiceover")]
        let health = CaptureHealth(micRMS: nil, systemAudioRMS: nil)
        #expect(AudioTrackOrder.recorded(in: states, health: health,
                                         overdubbed: false) == ["voiceover"])
    }

    @Test("The surviving lanes keep the canonical order")
    func orderSurvivesFiltering() {
        // `canonical` is the order the tracks exist in the FILE, which is the
        // order a mix addresses. Filtering must not become a reordering.
        let shuffled = [
            TrackState(track: "voiceover"),
            TrackState(track: "microphone"),
            TrackState(track: "video"),
            TrackState(track: "systemAudio"),
        ]
        let health = CaptureHealth(micRMS: 0.1, systemAudioRMS: 0.1)
        #expect(AudioTrackOrder.recorded(in: shuffled, health: health,
                                         overdubbed: false)
                == AudioTrackOrder.canonical)
    }
}
