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
        view.update(duration: 20, cuts: [TimeRange(start: 1, end: 2)],
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
