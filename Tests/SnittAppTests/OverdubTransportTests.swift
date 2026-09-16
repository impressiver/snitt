// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittApp
@testable import SnittDocument

/// The two transport buttons, while a take is being recorded (D102).
///
/// Four states, because record and play each mean something different
/// depending on what is already happening. Asserted here rather than in the
/// view because none of it is observable from outside a running app — and
/// scattered `if isRecording` checks across a view and a controller are what
/// nobody can write a test against, which is how "the + does nothing" shipped.
struct OverdubTransportTests {

    private func run(_ actions: [OverdubTransport.Action],
                     from state: OverdubTransport.State = .idle)
        -> (state: OverdubTransport.State, steps: [OverdubTransport.Step]) {
        var current = state
        var steps: [OverdubTransport.Step] = []
        for action in actions {
            let step = OverdubTransport.next(current, action)
            current = step.state
            steps.append(step)
        }
        return (current, steps)
    }

    // MARK: - Starting

    @Test("Record starts a count-in, and records nothing yet")
    func recordCountsIn() {
        // The picture must not move either: a count-in that played the video
        // would put the first beat over footage the take is not about.
        let step = OverdubTransport.next(.idle, .tapRecord)
        #expect(step.state == .countingIn(remaining: OverdubTransport.countInBeats))
        #expect(step.playTick, "the count-in is silent")
        #expect(!step.startRecording, "it started recording before counting in")
        #expect(!step.play, "it started playing before counting in")
    }

    @Test("Each beat ticks, and the last one starts the take AND playback")
    func countInEndsInRecording() {
        let (state, steps) = run([.tapRecord] + Array(repeating: .countInBeat,
                                                      count: OverdubTransport.countInBeats))
        #expect(state == .recording)
        // One tick per beat including the press, and none on the beat that
        // starts the take — that moment already has the microphone opening,
        // and a click there would be recorded into the take.
        #expect(steps.filter { $0.playTick }.count == OverdubTransport.countInBeats)
        let last = steps[steps.count - 1]
        #expect(last.startRecording)
        #expect(last.play, "the take started without the picture moving")
        #expect(!last.playTick, "a tick landed on the first frame of the take")
    }

    @Test("The record button reads as active from the moment it is pressed")
    func recordIsActiveThroughTheCountIn() {
        // A button that lit only once the count finished would leave the three
        // most uncertain seconds looking like nothing had happened.
        #expect(!OverdubTransport.State.idle.isRecordActive)
        #expect(OverdubTransport.State.countingIn(remaining: 3).isRecordActive)
        #expect(OverdubTransport.State.recording.isRecordActive)
        #expect(OverdubTransport.State.armedButPaused.isRecordActive)
    }

    // MARK: - Pausing, without ending the take

    @Test("Pause while recording keeps the take open and stops the playhead")
    func pauseKeepsTheTakeOpen() {
        // THE REQUIREMENT, stated: "pressing pause while recording keeps the
        // recording button active, but pauses the playhead". Abandoning a take
        // because somebody paused to think would make pause unusable during
        // the one operation it is most needed for.
        let step = OverdubTransport.next(.recording, .tapPlayPause)
        #expect(step.state == .armedButPaused)
        #expect(step.state.isRecordActive, "the record button went dark")
        #expect(step.pause, "the playhead kept running")
        #expect(step.pauseRecording)
        #expect(!step.stopRecording, "pausing ended the take")
    }

    @Test("Play again carries on into the SAME take")
    func resumeContinuesTheTake() {
        let step = OverdubTransport.next(.armedButPaused, .tapPlayPause)
        #expect(step.state == .recording)
        #expect(step.resumeRecording)
        #expect(step.play)
        #expect(!step.startRecording, "resuming started a second take")
    }

    @Test("A take survives being paused and resumed repeatedly")
    func pauseResumeIsStable() {
        let (state, steps) = run([.tapPlayPause, .tapPlayPause, .tapPlayPause, .tapPlayPause],
                                 from: .recording)
        #expect(state == .recording)
        #expect(!steps.contains { $0.stopRecording }, "a pause ended the take")
        #expect(!steps.contains { $0.startRecording }, "a resume began a new take")
    }

    // MARK: - Stopping

    @Test("Record while recording stops the take and pauses playback")
    func recordStopsAndPauses() {
        // The other stated requirement. Playback pauses rather than running
        // on, because the thing you do next is listen to what you just
        // recorded, and that starts from a standstill.
        let step = OverdubTransport.next(.recording, .tapRecord)
        #expect(step.state == .idle)
        #expect(step.stopRecording)
        #expect(step.pause, "the video kept playing after the take ended")
    }

    @Test("Record while paused-but-armed also stops the take")
    func recordStopsFromPaused() {
        // Otherwise a take paused and then stopped would stay open for ever,
        // with the button lit and nothing recording.
        let step = OverdubTransport.next(.armedButPaused, .tapRecord)
        #expect(step.state == .idle)
        #expect(step.stopRecording)
    }

    @Test("Record during the count-in cancels it, and keeps nothing")
    func recordCancelsTheCountIn() {
        let step = OverdubTransport.next(.countingIn(remaining: 2), .tapRecord)
        #expect(step.state == .idle)
        #expect(!step.stopRecording, "it tried to stop a take that never started")
        #expect(!step.startRecording)
    }

    @Test("Play during the count-in abandons it and plays")
    func playCancelsTheCountIn() {
        // Swallowing the press to protect a take that has recorded nothing
        // would make the transport feel stuck.
        let step = OverdubTransport.next(.countingIn(remaining: 2), .tapPlayPause)
        #expect(step.state == .idle)
        #expect(step.play)
        #expect(!step.stopRecording)
    }

    // MARK: - Not recording

    @Test("Play does nothing special when no take is open")
    func idlePlayIsOrdinary() {
        // The machine has no opinion about a transport that is not recording —
        // the caller toggles playback as it always did. An opinion here would
        // be a second answer to a question already answered, and the two would
        // eventually disagree about which way to toggle.
        let step = OverdubTransport.next(.idle, .tapPlayPause)
        #expect(step.state == .idle)
        #expect(!step.play && !step.pause)
        #expect(!step.startRecording && !step.stopRecording)
    }

    @Test("A stray count-in beat changes nothing")
    func lateBeatIsIgnored() {
        // A timer can fire once more before it is cancelled. A stray tick must
        // not restart a count-in or interrupt a take.
        for state in [OverdubTransport.State.idle, .recording, .armedButPaused] {
            let step = OverdubTransport.next(state, .countInBeat)
            #expect(step.state == state, "a stray beat moved \(state) to \(step.state)")
            #expect(!step.startRecording && !step.stopRecording && !step.playTick)
        }
    }

    @Test("A full session ends where it started")
    func theRoundTrip() {
        // Press record, count in, record, pause, resume, stop. The state must
        // come back to idle with the take closed — a machine that leaked a
        // state here would leave the button lit with nothing recording.
        let (state, steps) = run([.tapRecord, .countInBeat, .countInBeat, .countInBeat,
                                  .tapPlayPause, .tapPlayPause, .tapRecord])
        #expect(state == .idle)
        #expect(steps.filter { $0.startRecording }.count == 1)
        #expect(steps.filter { $0.stopRecording }.count == 1)
    }
}

/// How long a take is, when the recorder cannot say.
///
/// Reported as "the punch in didn't actually record anything". It had: the
/// audio was written and the file was on disk. What came back was a length of
/// ZERO, so the guard that throws away accidental taps threw away the take.
///
/// `AVAudioRecorder.currentTime` is documented as 0 when the recorder is not
/// recording, and `pause()` makes it not recording — so a take that is paused
/// when it stops cannot be measured from the recorder at all.
struct TakeLengthTests {

    @Test("A running recorder's own time is the length")
    func runningRecorderReportsItself() {
        #expect(TakeClock().length(recorderTime: 4.2) == 4.2)
    }

    @Test("A PAUSED recorder reports zero, so the remembered length is used")
    func pausedRecorderUsesTheRemembered() {
        // THE BUG. `stop()` read `currentTime` from a recorder that had just
        // been paused, got 0, and the take was discarded as a mis-click.
        var clock = TakeClock()
        clock.pause(at: 4.2)
        #expect(clock.length(recorderTime: 0) == 4.2)
    }

    @Test("A take resumed after a pause uses the LIVE time, not the stale one")
    func resumedRecorderUsesTheLiveTime() {
        // The other direction, and the reason this is `max` rather than
        // "prefer the remembered one": after resuming, `pausedElapsed` is a
        // number from the middle of the take, and trusting it would truncate
        // everything said after the pause.
        var clock = TakeClock()
        clock.pause(at: 4.2)
        #expect(clock.length(recorderTime: 9.0) == 9.0)
    }

    @Test("A take that really is empty still reads as empty")
    func genuinelyEmptyStaysEmpty() {
        // The mis-click guard has to keep working: a tap that started and
        // stopped a take without recording anything must still be discarded,
        // or every stray click would leave a silent span over the microphone.
        #expect(TakeClock().length(recorderTime: 0) == 0)
    }

    @Test("Pausing REMEMBERS the length, rather than merely reporting it")
    func pauseStoresTheLength() {
        // The assertion that was missing: the rule was covered and the
        // remembering was not, so a mutant that stored 0 survived. That is the
        // whole defect — the number is unrecoverable once the recorder has
        // paused, so failing to keep it is failing to record.
        var clock = TakeClock()
        #expect(clock.pausedElapsed == 0)
        clock.pause(at: 3.5)
        #expect(clock.pausedElapsed == 3.5, "the pause did not keep the length")
    }

    @Test("A second pause supersedes the first")
    func laterPauseWins() {
        // Pause, resume, pause again: the file is longer now, and keeping the
        // first number would truncate everything said in between.
        var clock = TakeClock()
        clock.pause(at: 2.0)
        clock.pause(at: 6.0)
        #expect(clock.length(recorderTime: 0) == 6.0)
    }
}

/// What is actually being CAPTURED, as opposed to what is open.
///
/// Reported as "pausing the record doesn't stop the recording from overlaying
/// the waveform". The level meter guarded on "is a take open", which stays
/// true through a pause — so it went on metering with the recorder stopped,
/// the level array kept growing, and the lane drew a take getting longer while
/// nothing was being recorded.
struct CapturingAudioTests {

    @Test("Only the recording state captures audio")
    func onlyRecordingCaptures() {
        #expect(OverdubTransport.State.recording.isCapturingAudio)
        #expect(!OverdubTransport.State.armedButPaused.isCapturingAudio,
                "a paused take still meters the microphone")
        #expect(!OverdubTransport.State.countingIn(remaining: 2).isCapturingAudio,
                "the count-in meters before the take has started")
        #expect(!OverdubTransport.State.idle.isCapturingAudio)
    }

    @Test("It is NOT the same question as whether the button is lit")
    func capturingDiffersFromActive() {
        // The distinction that was missing. A paused take is open — the button
        // stays lit, the file is waiting — and nothing is being written.
        let paused = OverdubTransport.State.armedButPaused
        #expect(paused.isRecordActive)
        #expect(!paused.isCapturingAudio)
        #expect(paused.isRecordActive != paused.isCapturingAudio)
    }
}

/// The live lane's runs, while a take is still being written.
///
/// The file cannot be decoded while it is open, so the lane counts LEVEL
/// readings instead — a different clock from the recorder's own elapsed time.
struct LiveRunTests {

    @Test("One run is as long as the levels sampled so far")
    func oneRun() {
        let runs = OverdubPlacement.liveRuns(outputStarts: [10], levelStarts: [0],
                                             levelCount: 40, levelsPerSecond: 20)
        #expect(runs == [OverdubPlacement.TakeRun(outputStart: 10, durationSeconds: 2)])
    }

    @Test("An earlier run ends where the next one began")
    func earlierRunsAreClosed() {
        // The defect this catches: a first run that kept growing would draw
        // over the pause, claiming audio for seconds nothing was recorded in.
        let runs = OverdubPlacement.liveRuns(outputStarts: [10, 30], levelStarts: [0, 40],
                                             levelCount: 60, levelsPerSecond: 20)
        #expect(runs[0].durationSeconds == 2, "the first run did not stop at the pause")
        #expect(runs[1].durationSeconds == 1)
        #expect(runs[1].outputStart == 30)
    }

    @Test("Nothing sampled yet is a zero-length run, not a negative one")
    func nothingSampled() {
        // A run opened by a resume, before the next tick has landed.
        let runs = OverdubPlacement.liveRuns(outputStarts: [10, 30], levelStarts: [0, 40],
                                             levelCount: 40, levelsPerSecond: 20)
        #expect(runs[1].durationSeconds == 0)
    }

    @Test("Mismatched inputs produce nothing rather than a wrong answer")
    func mismatchedInputs() {
        // The two arrays are maintained by different call sites; if they ever
        // disagree, drawing nothing is honest and drawing a guess is not.
        #expect(OverdubPlacement.liveRuns(outputStarts: [10], levelStarts: [0, 40],
                                          levelCount: 60, levelsPerSecond: 20).isEmpty)
        #expect(OverdubPlacement.liveRuns(outputStarts: [10], levelStarts: [0],
                                          levelCount: 60, levelsPerSecond: 0).isEmpty)
    }
}
