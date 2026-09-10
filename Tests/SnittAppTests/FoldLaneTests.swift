// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// The fold lane, and the y-gate that goes with it.
///
/// **Every existing fold test uses a 40pt-tall view**, which is shorter than a
/// fold lane can exist in — so all of them exercise the ungated fallback and
/// none of them touches the gate. These use a realistic height on purpose;
/// without that they would look like coverage and assert nothing about the
/// behaviour they name.
@MainActor
struct FoldLaneTests {
    private let width = 800.0
    private let duration = 20.0
    /// Tall enough for marks (24) + fold lane (24) + a usable video band (36).
    private let tallEnough = 140.0

    private func makeView(height: Double) -> (TimelineView, Cut, CGFloat) {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let geometry = TimelineGeometry(
            width: width,
            timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)
        return (view, cut, CGFloat(geometry.x(atFold: cut)))
    }

    @Test("A hit inside the fold lane finds the fold")
    func foldLaneHitFindsTheFold() {
        let (view, cut, foldX) = makeView(height: tallEnough)
        let range = try! #require(view.foldLaneRangeForTesting)
        #expect(range.contains(36), "expected the fold lane to span 24...48, got \(range)")
        #expect(view.foldHitForTesting(at: NSPoint(x: foldX, y: 36))?.id == cut.id)
    }

    @Test("The SAME x below the fold lane is not a fold hit")
    func belowTheFoldLaneIsNotAFold() {
        // The whole reason the gate exists. `foldHit` took no y and a fold's
        // line is drawn full height on purpose, so before this a hit on the
        // audio band at a fold's x resolved to that fold instead of falling
        // through to scrub — and every lane added below Video multiplies the
        // collision.
        let (view, _, foldX) = makeView(height: tallEnough)
        #expect(view.foldHitForTesting(at: NSPoint(x: foldX, y: 120)) == nil,
                "a hit on the audio band resolved to a fold")
    }

    @Test("The marker lane above the fold lane is not a fold hit either")
    func aboveTheFoldLaneIsNotAFold() {
        let (view, _, foldX) = makeView(height: tallEnough)
        #expect(view.foldHitForTesting(at: NSPoint(x: foldX, y: 10)) == nil)
    }

    @Test("On a view too short for a fold lane, folds stay reachable everywhere")
    func crampedViewKeepsFullHeightFolds() {
        // The fallback, and it must not be silent: gating a lane that has no
        // room to exist would make folds unclickable on a short timeline
        // rather than merely undecorated. This is also the height every
        // pre-existing fold test uses.
        let (view, cut, foldX) = makeView(height: 40)
        var toggled: UUID?
        view.onToggleExpansion = { toggled = $0 }
        view.mouseDown(with: .synthetic(at: NSPoint(x: foldX, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: foldX, y: 20), in: view))
        #expect(toggled == cut.id)
    }

    @Test("The marker lane clears the 24pt target floor at a realistic height")
    func markerLaneMeetsTheFloor() {
        // Shipped at `min(14.0, …)`, and markers are draggable. WCAG 2.5.8 AA
        // sets 24x24 as the enforceable minimum — this was a defect in the app
        // independent of any redesign.
        // Read from the VIEW, not from a height this test computed itself.
        // The first version passed `min(24, height * 0.4)` into `bands` and
        // asserted on the result — which tests this test's arithmetic and
        // leaves `markerTrackHeight` free to revert to 14. A mutant that did
        // exactly that survived, which is how the gap was found.
        let (view, _, _) = makeView(height: tallEnough)
        #expect(view.markerTrackHeightForTesting >= 24)
    }

    @Test("The fold lane appears only when a usable video band survives it")
    func foldLaneYieldsToTheFilmstrip() {
        // The filmstrip is protected last. Taking 24pt for a fold lane that
        // pushed the video band under its own floor would trade the spine for
        // a decoration.
        let tall = TimelineTrackLayout.bands(in: NSRect(x: 0, y: 0, width: width, height: tallEnough),
                                             markerHeight: 24, audioTracks: ["microphone"])
        let short = TimelineTrackLayout.bands(in: NSRect(x: 0, y: 0, width: width, height: 60),
                                              markerHeight: 24, audioTracks: ["microphone"])
        #expect(abs(tall.fold.height - TimelineTrackLayout.foldLaneHeight) < 0.001)
        #expect(abs(short.fold.height) < 0.001)
        #expect(short.video.height > 0, "the filmstrip was squeezed out for a fold lane")
    }

    @Test("Bands never overlap and never leave a gap")
    func bandsTile() {
        // Adding a lane between marks and video is exactly where an off-by-one
        // leaves a dead strip or a double-drawn edge.
        let bands = TimelineTrackLayout.bands(in: NSRect(x: 0, y: 0, width: width, height: tallEnough),
                                              markerHeight: 24,
                                              audioTracks: ["microphone", "systemAudio"])
        #expect(abs(bands.marker.maxY - bands.fold.minY) < 0.001)
        #expect(abs(bands.fold.maxY - bands.video.minY) < 0.001)
        #expect(abs(bands.video.maxY - bands.audio[0].rect.minY) < 0.001)
        #expect(abs(bands.audio.last!.rect.maxY - tallEnough) < 0.001)
    }
}
