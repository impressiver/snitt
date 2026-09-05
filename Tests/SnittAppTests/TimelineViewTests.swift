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
    @Test("A click scrubs and does not trim")
    func clickScrubsWithoutTrimming() {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
        var scrubbed: Double?
        var trimmed: TimeRange?
        view.onScrub = { scrubbed = $0 }
        view.onTrim = { trimmed = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))

        #expect(abs((scrubbed ?? -1) - 10.0) < 0.01)
        // Every click becoming a zero-length cut would fill the EDL with garbage.
        #expect(trimmed == nil)
    }

    @Test("A drag trims the range it covered, in either direction")
    func dragTrimsNormalisedRange() throws {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
        var trimmed: TimeRange?
        view.onTrim = { trimmed = $0 }

        // Right to left, the direction a naive implementation inverts.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))

        let range = try #require(trimmed)
        #expect(abs(range.start - 5.0) < 0.01)
        #expect(abs(range.end - 15.0) < 0.01)
    }

    @Test("A zero-width view does not produce NaN")
    func zeroWidthViewIsFinite() {
        // Views are laid out at zero width before their first real layout pass,
        // so this happens on every launch.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 0, height: 40))
        view.update(duration: 20, cuts: [TimeRange(start: 1, end: 2)],
                    jumpPoints: [], playhead: 5)
        var scrubbed: Double?
        view.onScrub = { scrubbed = $0 }
        view.mouseDown(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
        #expect((scrubbed ?? .nan).isFinite)
    }

    @Test("A drag shorter than the pixel threshold scrubs instead of trimming")
    func subThresholdDragScrubsNotTrims() {
        // Discriminates the pixel-based threshold from a naive
        // any-drag-that-moved-at-all implementation: 1px of motion on an
        // 800px/20s timeline is well under the 3px minimum, so this must
        // read as a click, not a cut.
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
        var scrubbed: Double?
        var trimmed: TimeRange?
        view.onScrub = { scrubbed = $0 }
        view.onTrim = { trimmed = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 401, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 401, y: 20), in: view))

        #expect(trimmed == nil)
        #expect(scrubbed != nil)
    }
}
