import Testing
import CoreGraphics
@testable import SnittApp

/// An expanded fold must not cover what comes after it.
///
/// Expansion draws the cut's source length at the timeline's own
/// pixels-per-second, and deliberately does not push later content right —
/// `geometry` is the single axis every gesture and every drawn pixel share, and
/// letting a UI-only expansion move it is how drawing and gesture axes come to
/// disagree (M4b Critical #1, guarded by `GestureAxisTests`). Unclamped, that
/// left the expansion drawing straight over the next fold, which is what made a
/// long cut's expansion look like a smear across the rest of the timeline.
@Suite
struct TimelineFoldExtentTests {
    @Test("An expansion stops at the next fold")
    func stopsAtTheNextFold() {
        // 400px of natural width, but the next fold is 90px away.
        let width = TimelineFoldExtent.clampedWidth(
            naturalWidth: 400, foldX: 100, otherFoldXs: [190], viewWidth: 800)
        #expect(width == 90)
    }

    @Test("An expansion stops at the view's edge")
    func stopsAtTheViewEdge() {
        let width = TimelineFoldExtent.clampedWidth(
            naturalWidth: 400, foldX: 700, otherFoldXs: [], viewWidth: 800)
        #expect(width == 100)
    }

    @Test("Folds to the LEFT do not constrain it")
    func foldsToTheLeftDoNotConstrain() {
        // An expansion grows rightward from its own fold, so a fold behind it
        // cannot be covered. Clamping against the nearest fold in EITHER
        // direction — the obvious wrong implementation — returns 60 here.
        let width = TimelineFoldExtent.clampedWidth(
            naturalWidth: 200, foldX: 400, otherFoldXs: [340, 100], viewWidth: 800)
        #expect(width == 200)
    }

    @Test("A coincident fold does not collapse the expansion to nothing")
    func coincidentFoldDoesNotZeroIt() {
        // Two cuts can collapse to the same output x. Clamping with `>=`
        // instead of `>` would make every such expansion zero-width — visible
        // as a fold that simply refuses to expand.
        let width = TimelineFoldExtent.clampedWidth(
            naturalWidth: 150, foldX: 300, otherFoldXs: [300], viewWidth: 800)
        #expect(width == 150)
    }

    @Test("A natural width that already fits is unchanged")
    func fittingWidthIsUnchanged() {
        let width = TimelineFoldExtent.clampedWidth(
            naturalWidth: 50, foldX: 100, otherFoldXs: [600], viewWidth: 800)
        #expect(width == 50)
    }

    @Test("Zero natural width stays zero")
    func zeroStaysZero() {
        #expect(TimelineFoldExtent.clampedWidth(
            naturalWidth: 0, foldX: 100, otherFoldXs: [], viewWidth: 800) == 0)
    }
}
