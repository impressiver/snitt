// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
@testable import SnittApp
import SnittDocument
import Testing

/// A synthetic mouse event at a view-local point.
///
/// `TimelineView` only ever reads `locationInWindow` (via `convert(_:from:)`)
/// — never `type` — so a single event type works as the payload for all
/// three call sites (`mouseDown`/`mouseDragged`/`mouseUp` are invoked
/// directly, not routed through AppKit's dispatch, so the event's declared
/// type is never consulted). No window server involved: the view under test
/// is never attached to a real `NSWindow`.
extension NSEvent {
    /// A mouse event at a point in the VIEW's own coordinates.
    ///
    /// The `in view:` parameter used to be ignored: `point` was handed to
    /// `NSEvent.mouseEvent(location:)`, which is WINDOW coordinates, and every
    /// caller then read it back through `convert(_:from: nil)`. On a flipped
    /// view — which `TimelineView` is — that inverts: passing y=36 into a
    /// 160pt-tall view made the view see y=124.
    ///
    /// It went unnoticed for a long time because the two oldest fixtures are
    /// 40pt tall and click at y=20, which is its own mirror image. The moment
    /// a test used a realistic height and an off-centre y, it silently tested
    /// a different lane than it named — and at least one test passed only
    /// because the inverted point happened to land somewhere with no marker in
    /// it. Three separate hit-testing bugs were investigated through this
    /// before the cause was found.
    ///
    /// Converting here rather than at every call site is the point: a rule
    /// that every author must remember is a rule that gets forgotten, and this
    /// one had no symptom until the geometry stopped being symmetric.
    static func synthetic(at point: NSPoint, in view: NSView,
                          clickCount: Int = 1) -> NSEvent {
        let location = view.isFlipped
            ? NSPoint(x: point.x, y: view.bounds.height - point.y)
            : point
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0)!
    }

    /// A synthetic key-down event carrying `character` as BOTH `characters`
    /// and `charactersIgnoringModifiers` (M5f Task 8) — `TimelineView.keyDown`
    /// only ever reads the latter, but a real key event always sets both, so
    /// this matches what AppKit would actually deliver rather than a payload
    /// no real keystroke produces.
    static func syntheticKey(_ character: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0)!
    }
}

@MainActor
struct TimelineViewTests {
    @Test("A click scrubs and does not select")
    func clickScrubsWithoutSelecting() {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [], markerPoints: [], playhead: 0)
        var scrubbed: Double?
        var selected: Selection?
        view.onScrub = { scrubbed = $0 }
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))

        #expect(abs((scrubbed ?? -1) - 10.0) < 0.01)
        // Every click becoming a zero-length selection would be as wrong as
        // the zero-length CUT this test used to guard against (D56 renamed
        // the outcome; the hazard is the same).
        #expect(selected == nil)
    }

    @Test("A drag selects the range it covered, in either direction")
    func dragSelectsNormalisedRange() throws {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // Right to left, the direction a naive implementation inverts.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.start - 5.0) < 0.01)
        #expect(abs(selection.range.end - 15.0) < 0.01)
    }

    @Test("With everything cut away, no click lands on a phantom fold")
    func fullyCutRecordingHasNoFoldPositions() {
        // A recording with every second cut away — the degenerate case
        // `foldHit`'s guard names. Worth pinning as BEHAVIOUR even though the
        // guard itself turned out not to be what enforces it: deleting the
        // `geometry.duration > 0` term changes nothing observable here, so
        // that term is belt-and-braces over a protection further up. The
        // behaviour is real and untested either way, which is what this
        // covers.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        view.update(duration: 10,
                    cuts: [Cut(range: TimeRange(start: 0, end: 10))],
                    markerPoints: [], playhead: 0)
        var expanded: UUID?
        view.onExpandAndSelectFold = { expanded = $0 }
        view.mouseDown(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view, clickCount: 2))
        #expect(expanded == nil, "a click landed on a fold that has no position")
    }

    @Test("A zero-width view does not produce NaN, and a click there never selects")
    func zeroWidthViewIsFinite() {
        // Views are laid out at zero width before their first real layout pass,
        // so this happens on every launch.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 0, height: 40))
        view.update(duration: 20, cuts: [Cut(range: TimeRange(start: 1, end: 2))],
                    markerPoints: [], playhead: 5)
        var scrubbed: Double?
        var selected: Selection?
        view.onScrub = { scrubbed = $0 }
        view.onSelect = { selected = $0 }
        view.mouseDown(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
        #expect((scrubbed ?? .nan).isFinite)
        // M4b whole-branch review, Minor finding #4: at zero width,
        // `minimumDragSeconds` clamps to exactly 0, and `TrimGesture.ended`
        // used to gate only on `length >= minimumSeconds` — so `0 >= 0` fired
        // a zero-length `onSelect(Selection(TimeRange(0,0)))` for this same
        // click. This is the same shape of gap the rest of this file's tests
        // target: a hazard the previous test named (NaN) but did not check
        // the adjacent, equally-broken outcome (a spurious selection).
        #expect(selected == nil)
    }

    @Test("A drag shorter than the pixel threshold scrubs instead of selecting")
    func subThresholdDragScrubsNotSelects() {
        // Discriminates the pixel-based threshold from a naive
        // any-drag-that-moved-at-all implementation: 1px of motion on an
        // 800px/20s timeline is well under the 3px minimum, so this must
        // read as a click, not a selection.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [], markerPoints: [], playhead: 0)
        var scrubbed: Double?
        var selected: Selection?
        view.onScrub = { scrubbed = $0 }
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 401, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 401, y: 20), in: view))

        #expect(selected == nil)
        #expect(scrubbed != nil)
    }

    // MARK: - M4b whole-branch review, Important finding #2
    //
    // `TrimGestureTests.samePixelJitterYieldsNoCutRegardlessOfLength`
    // recomputes `geometry.outputTime(atX:3) - geometry.outputTime(atX:0)`
    // itself and hands the RESULT to `TrimGesture` directly — it pins the
    // arithmetic, not the wiring. Every case above uses one geometry
    // (800px/20s), where the reverted `minimumDragSeconds = 0.05` constant
    // happens to agree with the pixel-derived threshold closely enough that
    // nothing here discriminated it from the real, geometry-driven
    // implementation. These four cases drive the real `TimelineView` — the
    // actual call site the reviewer's fix landed in — at a duration where
    // 0.05s stops agreeing with 3px, so a reversion to the literal fails
    // them.

    @Test("On a long recording, a sub-pixel wobble does not select")
    func longRecordingSubPixelWobbleDoesNotSelect() {
        // 800px / 600s is ~0.75s/pixel, so a fixed 0.05s constant sits far
        // under a single pixel — any 2px wobble would read as a deliberate
        // selection against that constant. The real pixel-derived threshold
        // (3px, ~2.25s here) must still absorb it.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 600, cuts: [], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 402, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 402, y: 20), in: view))

        #expect(selected == nil)
    }

    @Test("A deliberate drag past the pixel threshold selects on a short recording")
    func deliberateDragSelectsOnShortRecording() throws {
        // On an 800px/5s timeline the fixed 0.05s constant is ~8px. A 7px
        // drag (~0.044s) sits UNDER that constant — a reverted
        // implementation swallows it as jitter — but comfortably clears the
        // real pixel threshold (3px, ~0.019s here), which must let it
        // through as a deliberate selection.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 5, cuts: [], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 407, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 407, y: 20), in: view))

        let selection = try #require(selected)
        #expect(selection.range.end > selection.range.start)
    }

    @Test("A deliberate drag past the pixel threshold selects on a long recording")
    func deliberateDragSelectsOnLongRecording() throws {
        // The complementary case at 600s: a fixed 0.05s constant is
        // sub-pixel there, so it would (wrongly) treat this same 10px drag
        // as generously above threshold too — this case alone doesn't
        // discriminate the reverted constant from the real one. It matters
        // paired with `longRecordingSubPixelWobbleDoesNotSelect` above:
        // together they pin BOTH directions (jitter does not select, a
        // deliberate drag does) at the same duration the reverted constant
        // gets wrong.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 600, cuts: [], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 410, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 410, y: 20), in: view))

        let selection = try #require(selected)
        #expect(selection.range.end > selection.range.start)
    }
}

// MARK: - Zoom and snapping (M5f Task 8)

/// `TimelineGeometryTests`/`TimelineZoomTests` (SnittDocument) pin the pure
/// `zoomed(by:anchoredAt:)` arithmetic; this drives the real `TimelineView`
/// wiring on top of it — that `zoomIn()`/`zoomOut()` actually reach the
/// gesture math a drag uses, and that a drag's resolved endpoint snaps onto
/// a nearby marker, fold, or the playhead — the same "adjacent property"
/// trap this project keeps finding elsewhere: a `TimelineGeometry` that
/// zooms correctly in isolation proves nothing about whether `TimelineView`
/// actually asks it before interpreting a click.
///
/// Every case here uses ONE cut or none, at one zoom level, which is what
/// left the axis defect C1/C2 invisible: `zoomChangesTheGestureScale` and
/// the keyboard case below run on `cuts: []`, where the two axes the view
/// used to carry coincide exactly. `GestureAxisTests` is the cut-bearing,
/// zoom-sweeping half.
@MainActor
struct TimelineViewZoomAndSnappingTests {
    @Test("Zooming in shrinks the SOURCE time a fixed pixel drag covers, and zooming back out restores it")
    func zoomChangesTheGestureScale() throws {
        // 800px / 600s (10 minutes) — `TrimGesture.ended`'s own cited case,
        // ~0.75s/pixel unzoomed.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 600, cuts: [], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // A 40px drag unzoomed: 40 / (800/600) = 30s.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        let unzoomed = try #require(selected)
        let unzoomedWidth = unzoomed.range.end - unzoomed.range.start
        #expect(abs(unzoomedWidth - 30.0) < 0.1)

        // `zoomIn()` doubles the zoom each call and anchors on the playhead
        // (0 here) — a plausible wrong implementation changes only the
        // DRAWING `geometry`, leaving gesture math (and therefore what a
        // drag actually selects) at the old, unzoomed scale. If that were
        // true, this SAME 40px drag would still select ~30s here too.
        for _ in 0..<4 { view.zoomIn() }   // 16x
        selected = nil
        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        let zoomedIn = try #require(selected)
        let zoomedInWidth = zoomedIn.range.end - zoomedIn.range.start
        // 40 / (16 * 800/600) = 1.875s — over an order of magnitude smaller.
        #expect(abs(zoomedInWidth - 1.875) < 0.05)

        // `zoomOut()` undoes it exactly (clamped at 1x, which four calls
        // lands on precisely): the SAME drag should select ~30s again, not
        // some other value a lossy round-trip through zoom would leave.
        for _ in 0..<4 { view.zoomOut() }   // back to 1x
        selected = nil
        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        let restored = try #require(selected)
        #expect(abs((restored.range.end - restored.range.start) - 30.0) < 0.1)
    }

    /// The three snap tests below all changed pixels — never expected times —
    /// in the M5f whole-branch review's fix wave (Criticals C1/C2). Each one
    /// aimed its drag at where the deleted fixed-SOURCE gesture axis put a
    /// snap target, which for every one of them was NOT where the thing
    /// being snapped to is drawn: the cut's edges sat 44px and 200px from
    /// its own fold, the marker's target 40px from its own glyph. Snapping
    /// to something other than the thing on screen is not snapping.
    ///
    /// The pixel each drag now ends on is derived from a real
    /// `TimelineGeometry` rather than written out, so the test names the
    /// PROPERTY (a drag ending near a drawn target lands exactly on it)
    /// instead of a coordinate that has to be recomputed by hand whenever
    /// the fixture changes.
    @Test("A drag ending near an existing cut's fold snaps exactly onto it")
    func dragSnapsToCutEdge() throws {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let geometry = TimelineGeometry(
            width: 800, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        let foldX = geometry.x(atFold: cut)
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // 18s of output across 800px (44.4px/s), so the fold for [10,12]
        // draws at ~444px. Ending the drag 3px off it, well inside the 6px
        // tolerance, must snap the SELECTION edge to exactly the instant
        // that fold IS — output 10.0, which is SOURCE 12.0, the cut's far
        // edge and the first frame still kept after it. A build with no
        // snapping (or with a mistakenly seconds-based tolerance this zoom
        // level puts under a pixel) reports the raw ~12.07 instead.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: foldX + 3, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: foldX + 3, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.end - 12.0) < 0.001)
    }

    @Test("A drag ending just past the snap margin does not snap")
    func dragJustOutsideSnapMarginDoesNotSnap() throws {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let geometry = TimelineGeometry(
            width: 800, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        let foldX = geometry.x(atFold: cut)
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // 10px past the fold clears any reasonable pixel margin without
        // landing far enough away that a generous margin would
        // coincidentally also miss it — the same discriminating distance
        // `TrackLayoutTests`/`CutFoldTests` use for their own hit margins.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: foldX + 10, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: foldX + 10, y: 20), in: view))

        let selection = try #require(selected)
        let unsnapped = 12.0 + 10.0 / geometry.pixelsPerSecond
        #expect(abs(selection.range.end - unsnapped) < 0.001)
        #expect(abs(selection.range.end - 12.0) > 0.01)
    }

    @Test("A drag ending near a marker snaps onto the glyph that is drawn, and reports its SOURCE time")
    func dragSnapsToMarkerConvertedFromOutputTime() throws {
        // A 2s cut [2,4) means OUTPUT and SOURCE time diverge past it:
        // marker output 5.0 is SOURCE 7.0 (2s of cut sits between them).
        // The marker is COMPARED where it is drawn — `geometry.x(atOutput:)`,
        // no conversion, since a marker is already output time — and the
        // conversion happens once, on the way out, because a `Selection` is
        // source time. Doing it the other way round (converting first, then
        // comparing on a source-scaled axis) is what put this marker's snap
        // target 40px from its own glyph until the whole-branch review.
        let cut = Cut(range: TimeRange(start: 2, end: 4))
        let marker = JumpPoint(timeSeconds: 5.0, label: "m")
        let geometry = TimelineGeometry(
            width: 800, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        let markerX = geometry.x(atOutput: OutputTime(marker.timeSeconds))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], markerPoints: [marker], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 50, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: markerX + 3, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: markerX + 3, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.end - 7.0) < 0.001)
    }

    @Test("A drag ending near the playhead snaps onto where it is drawn, and reports its SOURCE time")
    func dragSnapsToPlayheadConvertedFromOutputTime() throws {
        // Same 2s cut; OUTPUT playhead 6.0 is SOURCE 8.0.
        let cut = Cut(range: TimeRange(start: 2, end: 4))
        let geometry = TimelineGeometry(
            width: 800, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        let playheadX = geometry.x(atOutput: OutputTime(6.0))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 6.0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 50, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: playheadX - 3, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: playheadX - 3, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.end - 8.0) < 0.001)
    }

    @Test("The '+' key zooms in and '-' zooms out, both reaching the SAME gesture scale zoomIn()/zoomOut() do")
    func keyboardControlZoomsInAndOut() throws {
        // A plausible wrong implementation swaps the two cases (`+` calling
        // `zoomOut()`, `-` calling `zoomIn()`) or drops one of them to the
        // `default` (unhandled) branch — either compiles and passes any test
        // that only checks `zoomIn()`/`zoomOut()` directly, so this drives
        // the actual keyboard path (`keyDown(with:)`) instead.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 600, cuts: [], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        for _ in 0..<4 { view.keyDown(with: .syntheticKey("+")) }   // 16x, matching zoomChangesTheGestureScale
        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        let zoomedIn = try #require(selected)
        #expect(abs((zoomedIn.range.end - zoomedIn.range.start) - 1.875) < 0.05)

        for _ in 0..<4 { view.keyDown(with: .syntheticKey("-")) }   // back to 1x
        selected = nil
        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        let restored = try #require(selected)
        #expect(abs((restored.range.end - restored.range.start) - 30.0) < 0.1)
    }

    @Test("An unrecognised key is not swallowed — it falls through instead of zooming")
    func unrecognisedKeyDoesNotZoom() throws {
        // Discriminates a `keyDown` that zooms on ANY key (e.g. a `switch`
        // with no `default` case reaching `super`, or one that zooms
        // unconditionally) from one that only reacts to `+`/`=`/`-`.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 600, cuts: [], markerPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.keyDown(with: .syntheticKey("a"))

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
        let unchanged = try #require(selected)
        #expect(abs((unchanged.range.end - unchanged.range.start) - 30.0) < 0.1)
    }
}
