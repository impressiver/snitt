// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Seeking to an OUTPUT instant arrives at that instant (2026-09-11).
///
/// Reported from use: "the marker prev/next doesn't line up with the actual
/// markers". `seek(toOutput:)` routed through `onScrub`, which takes SOURCE
/// time and converts it with `nearestTrimmedTime(toSourceTime:)` — so a time
/// that was already output got converted a second time and landed EARLY by the
/// length of everything cut before it.
///
/// It was not only mark navigation: a marker row in the rail passes
/// `chapter.outputTime`, and a timecode typed into the transport is the one
/// the transport displays. All three drifted, and only once a recording had a
/// cut in it — with none, the two clocks agree and it looked right.
///
/// The markers are DRAWN at `x(atOutput:)`, which is why the jump and the mark
/// visibly disagreed rather than both being wrong together.
@Suite(.serialized)
@MainActor
struct SeekToOutputTests {

    private func editor(cutting cut: TimeRange?, of seconds: Double) async throws
        -> (EditorTimelineState, PreviewController) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds,
                                      audioTrackCount: 0)
        let edl = EditDecisionList(cuts: cut.map { [Cut(range: $0)] } ?? [])
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        // The state rather than the whole window: `seek(toOutput:)` lives
        // here, and building a window would drag a hosting view into a test
        // about arithmetic.
        return (EditorTimelineState(controller: controller, edl: edl, events: []), controller)
    }

    /// Where the player actually is, after giving the async seek a chance.
    private func settled(_ controller: PreviewController) async -> Double {
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            let now = controller.player.currentTime().seconds
            if now.isFinite, now > 0.001 { return now }
        }
        return controller.player.currentTime().seconds
    }

    @Test("With a cut present, seeking to an output instant lands on it")
    func seekLandsOnTheOutputInstant() async throws {
        // Six seconds with 1s–3s removed: output runs 0–4, and output 3.0 is
        // source 5.0. Converting 3.0 as though it were SOURCE gives output
        // 1.0 — two seconds early, exactly the length of the cut before it.
        let (editor, controller) = try await editor(cutting: TimeRange(start: 1, end: 3),
                                                    of: 6)
        editor.seek(toOutput: 3.0)
        let landed = await settled(controller)
        #expect(abs(landed - 3.0) < 0.2,
                "asked for output 3.0 and landed at \(landed) — the cut was subtracted twice")
    }

    @Test("With no cuts, seeking is unchanged — which is why this hid")
    func seekIsUnchangedWithoutCuts() async throws {
        // The reason the defect survived: with nothing removed, source and
        // output are the same clock and the double conversion is the identity.
        let (editor, controller) = try await editor(cutting: nil, of: 6)
        editor.seek(toOutput: 3.0)
        let landed = await settled(controller)
        #expect(abs(landed - 3.0) < 0.2, "landed at \(landed)")
    }
}
