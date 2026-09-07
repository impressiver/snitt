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
    static func synthetic(at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
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
        view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
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
        view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
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

    @Test("A zero-width view does not produce NaN, and a click there never selects")
    func zeroWidthViewIsFinite() {
        // Views are laid out at zero width before their first real layout pass,
        // so this happens on every launch.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 0, height: 40))
        view.update(duration: 20, cuts: [Cut(range: TimeRange(start: 1, end: 2))],
                    jumpPoints: [], playhead: 5)
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
        view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
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
        view.update(duration: 600, cuts: [], jumpPoints: [], playhead: 0)
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
        view.update(duration: 5, cuts: [], jumpPoints: [], playhead: 0)
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
        view.update(duration: 600, cuts: [], jumpPoints: [], playhead: 0)
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
/// gesture math a drag uses (`sourceTime(atX:)`, routed through
/// `gestureGeometry` now, not a bare `x / bounds.width * duration`), and
/// that a drag's resolved endpoint snaps onto a nearby marker, cut edge, or
/// the playhead — the same "adjacent property" trap this project keeps
/// finding elsewhere: a `TimelineGeometry` that zooms correctly in isolation
/// proves nothing about whether `TimelineView` actually asks it before
/// interpreting a click.
@MainActor
struct TimelineViewZoomAndSnappingTests {
    @Test("Zooming in shrinks the SOURCE time a fixed pixel drag covers, and zooming back out restores it")
    func zoomChangesTheGestureScale() throws {
        // 800px / 600s (10 minutes) — `TrimGesture.ended`'s own cited case,
        // ~0.75s/pixel unzoomed.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 600, cuts: [], jumpPoints: [], playhead: 0)
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

    @Test("A drag ending near an existing cut's edge snaps exactly onto it")
    func dragSnapsToCutEdge() throws {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], jumpPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // Gesture scale (fixed SOURCE, unzoomed): 800px / 20s = 40px/s, so
        // the cut's start (source 10) sits at pixel 400. Ending the drag 3px
        // off it, well inside the 6px tolerance, must snap the SELECTION
        // edge to exactly 10.0 — not the raw, unsnapped 403/40 = 10.075 a
        // build with no snapping (or a mistakenly seconds-based tolerance
        // that this zoom level puts under a pixel) would report instead.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 403, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 403, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.end - 10.0) < 0.001)
    }

    @Test("A drag ending just past the snap margin does not snap")
    func dragJustOutsideSnapMarginDoesNotSnap() throws {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], jumpPoints: [], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // 10px off the cut's start (pixel 400) clears any reasonable pixel
        // margin without landing far enough away that a generous margin
        // would coincidentally also miss it — the same discriminating
        // distance `TrackLayoutTests`/`CutFoldTests` use for their own hit
        // margins.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 410, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 410, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.end - 10.25) < 0.001)
        #expect(abs(selection.range.end - 10.0) > 0.01)
    }

    @Test("A drag ending near a marker snaps to its SOURCE time, converted from the OUTPUT time it is stored/drawn at")
    func dragSnapsToMarkerConvertedFromOutputTime() throws {
        // A 2s cut [2,4) means OUTPUT and SOURCE time diverge past it:
        // marker output 5.0 is SOURCE 7.0 (2s of cut sits between them).
        // Snapping against the raw, unconverted 5.0 instead would be the
        // M4b clock confusion this milestone exists to prevent, one more
        // place — this test fails against exactly that mistake, since an
        // unconverted comparison sits nowhere near this drag's endpoint.
        let cut = Cut(range: TimeRange(start: 2, end: 4))
        let marker = JumpPoint(timeSeconds: 5.0, label: "m")
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], jumpPoints: [marker], playhead: 0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // Gesture scale is fixed-source, 40px/s: SOURCE 7.0 sits at pixel
        // 280. 3px off, inside the 6px tolerance.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 50, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 283, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 283, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.end - 7.0) < 0.001)
    }

    @Test("A drag ending near the playhead snaps to it, converted from OUTPUT to SOURCE time")
    func dragSnapsToPlayheadConvertedFromOutputTime() throws {
        // Same 2s cut; OUTPUT playhead 6.0 is SOURCE 8.0.
        let cut = Cut(range: TimeRange(start: 2, end: 4))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], jumpPoints: [], playhead: 6.0)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        // SOURCE 8.0 sits at pixel 320 on the 40px/s fixed gesture scale.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 50, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 317, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 317, y: 20), in: view))

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
        view.update(duration: 600, cuts: [], jumpPoints: [], playhead: 0)
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
        view.update(duration: 600, cuts: [], jumpPoints: [], playhead: 0)
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
