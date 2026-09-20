// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import AppKit
import Combine
import Foundation
import SnittDocument
import SnittExport
@testable import SnittApp

/// The transport button after playback runs off the end.
///
/// **The bug.** `isPlaying` was `controller.player.rate != 0`, read during a
/// render — and the only thing causing renders was the playhead changing on
/// the 20Hz tick. So when playback reached the end, the rate dropped to zero,
/// the playhead stopped moving, nothing re-rendered, and the transport kept
/// showing Pause over a stopped player. The button was correct right up until
/// the moment it mattered.
///
/// The fix is a published value. Every method here that starts or stops
/// playback refreshes it, so it is right immediately; the tick refreshes it
/// too, as the backstop for the one change nothing in the editor causes —
/// the player reaching the end of the recording.
///
/// These drive `updatePlayback(rate:)` rather than making a real player stop
/// on cue: the rule under test is "non-zero means playing, and the flag
/// follows", and a test that needed an `AVPlayer` to reach its end would be a
/// timing test wearing this one's clothes.
@Suite(.serialized)
@MainActor
struct PlaybackFlagTests {
    init() { _ = NSApplication.shared }

    private func makeState() async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        return EditorTimelineState(controller: controller,
                                   edl: EditDecisionList(), events: [])
    }

    @Test("The flag follows the rate down as well as up")
    func theFlagFollowsTheRate() async throws {
        let state = try await makeState()
        #expect(!state.isPlaying, "a fresh editor claims to be playing")

        state.updatePlayback(rate: 1)
        #expect(state.isPlaying)

        // THE REGRESSION — the end of the recording, which is the only way
        // playback stops without anything in the editor asking it to.
        state.updatePlayback(rate: 0)
        #expect(!state.isPlaying, "the transport still reads as playing after the end")
    }

    @Test("A rate that has not changed does not republish")
    func repeatedTicksAreQuiet() async throws {
        // The tick runs twenty times a second whether or not anything is
        // happening, and `@Published` notifies on every assignment — so an
        // unguarded write would re-render the whole editor, timeline and
        // transcript and rail, continuously while the player sat still.
        let state = try await makeState()
        var notifications = 0
        let token = state.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        for _ in 0..<20 { state.updatePlayback(rate: 0) }
        #expect(notifications == 0,
                "a stationary player is republishing \(notifications) times")

        state.updatePlayback(rate: 1)
        for _ in 0..<20 { state.updatePlayback(rate: 1) }
        #expect(notifications == 1, "only the change should publish")
    }

    @Test("Refreshing reads the player rather than being told")
    func refreshReadsThePlayer() async throws {
        // What makes the flag correct the instant a control is pressed rather
        // than up to a tick later — and what the three transport tests in
        // `EditorTransportTests` rely on, since none of them ticks.
        let state = try await makeState()
        state.togglePlayback()
        #expect(state.isPlaying)
        state.togglePlayback()
        #expect(!state.isPlaying)
    }
}
