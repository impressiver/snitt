import CoreGraphics

/// How wide an expanded fold is allowed to draw.
///
/// An expanded fold shows its cut's own source length at the timeline's
/// pixels-per-second, which is what makes revealed footage read at the same
/// scale as everything around it. Unclamped, that width runs straight over
/// whatever comes next — a later fold, or the right edge of the view — because
/// expansion deliberately does NOT move `geometry` (later content is not
/// pushed right to make room).
///
/// That deliberate choice is right and stays: `geometry` is the single axis
/// every gesture and every drawn pixel share, and letting a UI-only expansion
/// move it is how the drawing and gesture axes come to disagree — M4b's
/// Critical #1, which `GestureAxisTests` exists to prevent. So the fix is not
/// to reflow, it is to stop the expansion covering its neighbours.
///
/// Pure, so the rule is testable without a view: given where the folds are, how
/// wide may this one draw?
enum TimelineFoldExtent {
    /// `naturalWidth` clamped so the expansion reaches neither the next fold to
    /// its right nor past the view's edge.
    ///
    /// Only folds to the RIGHT constrain it — an expansion grows rightward from
    /// its own fold position, so a fold to the left is behind it and cannot be
    /// covered.
    static func clampedWidth(naturalWidth: Double,
                             foldX: Double,
                             otherFoldXs: [Double],
                             viewWidth: Double) -> Double {
        guard naturalWidth > 0 else { return 0 }
        let toViewEdge = max(0, viewWidth - foldX)
        // A fold exactly at the same x is a coincident cut, not something to
        // the right; `> foldX` keeps this from clamping the expansion to zero
        // against a neighbour it is stacked on.
        let toNextFold = otherFoldXs.filter { $0 > foldX }.min().map { $0 - foldX }
        return min(naturalWidth, toViewEdge, toNextFold ?? .greatestFiniteMagnitude)
    }
}
