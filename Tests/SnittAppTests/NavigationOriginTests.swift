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

/// What mark navigation reasons from after a seek it did not make itself.
///
/// Reported from the app: "some clicks don't register when clicking prev/next
/// marker buttons". They registered — they seeked to where the playhead was
/// already going.
///
/// `MarkerNavigation.origin` exists precisely to stop that, and its doc
/// comment describes the symptom exactly ("Next advanced once and then
/// appeared stuck"). The hole was in what ARMED it: only `jump(toMarkAt:)`
/// did, and every other seek in the editor set it to nil. So navigation was
/// protected from its own in-flight seek and from nothing else — a scrub, a
/// rewind, a typed timecode, a click on a marker row all left it reading a
/// player clock that had not moved yet.
///
/// Asserted on the ARMED TARGET rather than on where the player ends up, and
/// that is the point: by the time the player has arrived there is nothing left
/// to get wrong. The defect lives entirely in the beat before that, so a test
/// that waited for the seek would pass against the broken code.
@Suite(.serialized)
@MainActor
struct NavigationOriginTests {

    private func makeState(seconds: Double = 30.0,
                           marks: [Double] = []) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        // Marks reach the controller as EVENTS, the way the app makes them —
        // `jumpPoints` is `private(set)` and recomputed from events against
        // the current cuts, so assigning it directly would be a fixture the
        // app cannot produce.
        let events = marks.enumerated().map { index, time in
            LoggedEvent(timeSeconds: time, kind: .marker, label: "mark \(index)", x: nil, y: nil)
        }
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        try await controller.apply(edl: EditDecisionList(), events: events)
        return EditorTimelineState(controller: controller, edl: EditDecisionList(), events: events)
    }

    @Test("A plain seek records where it is going")
    func seekArmsTheTarget() async throws {
        // The one line the defect turned on. Before this, `seek(toOutput:)`
        // set the target to NIL, so anything pressing Next in the beat after a
        // seek reasoned from the player's pre-seek position.
        let state = try await makeState()
        state.seek(toOutput: 12.5)
        #expect(state.pendingSeekTargetForTesting == 12.5)
    }

    @Test("A marker-pane click records where it is going, nudge included")
    func markerSeekArmsTheNudgedTarget() async throws {
        // Specifically the NUDGED value, not the marker's own time: navigation
        // has to reason from where the playhead will actually be, or the very
        // next Prev press is computed against a position nothing is heading to.
        let state = try await makeState()
        state.seekToMarker(atOutput: 8.0)
        #expect(state.pendingSeekTargetForTesting == 8.0,
                "with no banners there is no nudge, so the target is the marker itself")
    }

    @Test("A scrub records its destination rather than clearing it")
    func scrubArmsTheTarget() async throws {
        // A scrub used to CLEAR the target, on the reasoning that it
        // supersedes a jump in flight. It does supersede it — and it is itself
        // a destination, which is what the old code failed to say.
        let state = try await makeState()
        state.onScrub(9.0)
        #expect(state.pendingSeekTargetForTesting == 9.0)
    }

    @Test("A rewind records zero, so Next steps from the start")
    func rewindArmsZero() async throws {
        let state = try await makeState()
        state.seek(toOutput: 20)
        state.rewind()
        #expect(state.pendingSeekTargetForTesting == 0,
                "Next straight after a rewind would step from wherever the playhead had not yet left")
    }

    @Test("The target is dropped once the player is actually there")
    func arrivalDropsTheTarget() async throws {
        // Otherwise a stale intention outlives its seek and playback moving
        // the head elsewhere never takes over — the mirror-image defect, and
        // the reason this is a pending target rather than a remembered one.
        let state = try await makeState()
        state.seek(toOutput: 5.0)
        try await Task.sleep(nanoseconds: 600_000_000)

        // Reading navigation is what drops it; `jumpPoints` is empty, so this
        // steps nowhere and is purely the read.
        state.goToNextMark()
        #expect(state.pendingSeekTargetForTesting == nil,
                "the player arrived and the intention was still armed")
    }

    @Test("Next steps past the mark a seek is still travelling to")
    func nextStepsFromTheTargetNotTheStaleClock() async throws {
        // The reported symptom, end to end and WITHOUT waiting for the seek —
        // the wait is what makes the broken code look correct.
        //
        // Verified against the pre-fix code: restoring `pendingSeekTarget =
        // nil` in `seek(toOutput:)` makes this fail, because the origin falls
        // back to a player clock still sitting at zero and `next` answers with
        // the mark at 10 — the one already being travelled to.
        let state = try await makeState(marks: [10, 20])
        #expect(state.controller.jumpPoints.count == 2, "the fixture has no marks to step between")
        state.seek(toOutput: 10)
        state.goToNextMark()

        #expect(state.pendingSeekTargetForTesting == 20,
                "Next reasoned from the stale clock and re-seeked to the mark already in flight")
    }
}
