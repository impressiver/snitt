import Testing
@testable import SnittDocument

struct TrimGestureTests {
    @Test("A forward drag produces the range it covered")
    func forwardDragProducesRange() {
        var g = TrimGesture()
        g.began(atTime: 2.0)
        g.moved(toTime: 5.0)
        let range = g.ended(atTime: 5.0)
        #expect(range == TimeRange(start: 2.0, end: 5.0))
    }

    @Test("A backwards drag is normalised, not inverted")
    func backwardsDragIsNormalised() {
        // Dragging right-to-left is as natural as left-to-right. EditDecisionList
        // assumes start <= end, so an inverted range silently cuts nothing —
        // the user drags, sees no change, and has no idea why.
        var g = TrimGesture()
        g.began(atTime: 8.0)
        g.moved(toTime: 3.0)
        let range = g.ended(atTime: 3.0)
        #expect(range == TimeRange(start: 3.0, end: 8.0))
    }

    @Test("A click is not a zero-length cut")
    func clickProducesNoCut() {
        // Clicking to seek is the most common timeline interaction. An
        // implementation that returns a range whenever a drag ends fills the EDL
        // with zero-length cuts, one per click.
        var g = TrimGesture()
        g.began(atTime: 4.0)
        let range = g.ended(atTime: 4.0)
        #expect(range == nil)
    }

    @Test("Ending without beginning yields nothing")
    func endWithoutBeginYieldsNothing() {
        var g = TrimGesture()
        #expect(g.ended(atTime: 3.0) == nil)
    }

    @Test("A drag in progress previews the range it would cut")
    func draggingPreviewsRange() {
        // The view needs to draw the pending cut while the mouse is down.
        var g = TrimGesture()
        g.began(atTime: 2.0)
        g.moved(toTime: 6.0)
        #expect(g.previewRange == TimeRange(start: 2.0, end: 6.0))
        // Discriminating against a preview that only appears after the drag
        // ends, which is a preview of nothing.
        #expect(g.phase != .idle)
    }
}
