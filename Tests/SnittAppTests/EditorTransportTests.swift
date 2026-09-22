// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import AppKit
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The editor's transport: rewind, and what a scrub does to playback.
///
/// Both assertions are on the PLAYER — where the playhead actually ended up
/// and whether the picture is still moving — rather than on "pause() was
/// called". A test that counted calls would pass against a `rewind()` routed
/// through `onScrub`, which is precisely the implementation these rule out.
@Suite(.serialized)
@MainActor
struct EditorTransportTests {

    private func makeState(seconds: Double = 6.0,
                           edl: EditDecisionList = EditDecisionList())
    async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        try await controller.apply(edl: edl, events: [])
        return EditorTimelineState(controller: controller, edl: edl, events: [])
    }

    private func currentSeconds(_ state: EditorTimelineState) -> Double {
        state.controller.player.currentTime().seconds
    }

    @Test("Rewind puts the playhead back at the start")
    func rewindReturnsToTheStart() async throws {
        let state = try await makeState()
        await state.controller.seek(toSeconds: 4.0)
        #expect(currentSeconds(state) > 3.0, "the fixture never moved off zero")

        state.rewind()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(currentSeconds(state) < 0.05, "landed at \(currentSeconds(state))")
    }

    @Test("Rewind works when the recording starts with a cut")
    func rewindWorksWithACutAtTheStart() async throws {
        // Zero in OUTPUT time is always the start of the edit. Resolving a
        // rewind through `keptRanges` as if it were a SOURCE time would land
        // it at the first kept edge — the same place here, but the mapping is
        // an extra way to be wrong for no benefit, and this pins the case
        // that would expose it.
        let state = try await makeState(
            edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 2))]))
        await state.controller.seek(toSeconds: 3.0)

        state.rewind()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(currentSeconds(state) < 0.05, "landed at \(currentSeconds(state))")
    }

    @Test("Scrubbing the timeline stops playback")
    func scrubbingStopsPlayback() async throws {
        // The reported problem: the picture kept moving after a click, so the
        // playhead walked away from where it had just been put and the click
        // read as ignored.
        let state = try await makeState()
        // Started through `togglePlayback` rather than `controller.play()`.
        // Playing is the state's own published fact now — it has to be, or
        // nothing can tell the transport that playback ran off the end — and
        // reaching past the state to the player leaves that fact unset. What
        // each test asserts about the act that follows is unchanged.
        state.togglePlayback()
        #expect(state.isPlaying, "the fixture never started playing")

        state.onScrub(2.0)

        #expect(state.isPlaying == false)
    }

    @Test("Rewind does NOT stop playback")
    func rewindKeepsPlaying() async throws {
        // This is the assertion that rules out `rewind() { onScrub(0) }` —
        // the obvious implementation, and one that reuses the code path that
        // now pauses. A rewind pressed while watching is a replay, not a stop.
        let state = try await makeState()
        // Started through `togglePlayback` rather than `controller.play()`.
        // Playing is the state's own published fact now — it has to be, or
        // nothing can tell the transport that playback ran off the end — and
        // reaching past the state to the player leaves that fact unset. What
        // each test asserts about the act that follows is unchanged.
        state.togglePlayback()
        #expect(state.isPlaying, "the fixture never started playing")

        state.rewind()

        #expect(state.isPlaying, "rewind paused playback")
    }

    @Test("A chapter or transcript click stops playback too")
    func seekingFromAPaneStopsPlayback() async throws {
        // `seek(toOutput:)` and `seek(toWord:)` both route through `onScrub`
        // on purpose — same act, different target. Pausing only on the
        // timeline's own path would leave the panes behaving differently from
        // the lane for no reason a user could predict.
        let state = try await makeState()
        // Started through `togglePlayback` rather than `controller.play()`.
        // Playing is the state's own published fact now — it has to be, or
        // nothing can tell the transport that playback ran off the end — and
        // reaching past the state to the player leaves that fact unset. What
        // each test asserts about the act that follows is unchanged.
        state.togglePlayback()
        #expect(state.isPlaying)

        state.seek(toOutput: 2.0)

        #expect(state.isPlaying == false)
    }
}

/// The clock's two halves count in the same units.
///
/// **They did not.** The current time is the playhead, which is OUTPUT time;
/// the total was `displayState.duration`, which is the SOURCE length. So a
/// recording trimmed from 58 seconds to 25 read `0:16 / 0:58` — the left half
/// describing the edit and the right half describing the footage it came from.
///
/// It is the same shape as the `editor select` units bug: two numbers printed
/// side by side, in different clocks, with nothing to make the mismatch
/// visible. This one had been on screen the whole time, and shipped in the
/// README's hero GIF, where it says a 25-second demo is 58 seconds long.
///
/// The timeline keeps the source length deliberately. Its x-axis IS source
/// time, so a fold has to be drawn where it sits in the original.
@Suite(.serialized)
@MainActor
struct TransportClockUnitsTests {
    init() { _ = NSApplication.shared }

    /// Six seconds of footage with two cut away, built so the composition and
    /// the edit agree — otherwise output equals source and nothing is proved.
    private func trimmedState() async throws -> EditorTimelineState {
        var edl = EditDecisionList.fullRange()
        edl.cuts = [Cut(range: TimeRange(start: 0, end: 2))]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 6)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        return EditorTimelineState(
            controller: PreviewController(built: built, jumpPoints: [],
                                          bundle: bundle, scale: 1.0),
            edl: edl, events: [])
    }

    @Test("The total is what the edit runs for, not what was recorded")
    func theTotalIsOutputTime() async throws {
        let state = try await trimmedState()

        // Four seconds survive of six. The old code reported six.
        #expect(abs(state.outputDurationSeconds - 4) < 0.35,
                "the clock's total is \(state.outputDurationSeconds), expected about 4")

        // And the source length is still available, because the timeline needs
        // it. Losing that would be the opposite mistake.
        let source = state.displayState(playhead: 0).duration
        #expect(abs(source - 6) < 0.35,
                "the timeline lost the source length it draws folds against: \(source)")
        #expect(source > state.outputDurationSeconds,
                "output and source are the same, so this fixture proves nothing")
    }

    @Test("An untrimmed recording reads the same either way")
    func nothingChangesWhenNothingIsCut() async throws {
        // The control. A change that simply reported a different number would
        // pass the test above; this pins that the two agree when there is no
        // edit between them, which is the common case and the one a reader
        // would notice being wrong.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 5)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let state = EditorTimelineState(
            controller: PreviewController(built: built, jumpPoints: [],
                                          bundle: bundle, scale: 1.0),
            edl: EditDecisionList(), events: [])

        #expect(abs(state.outputDurationSeconds
                    - state.displayState(playhead: 0).duration) < 0.05,
                "uncut, the two clocks disagree")
    }
}
