// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// The welcome-window mascot's DECISIONS — which eye ry, which pupil radius,
/// which mouth path, for a given mood/keenness/poke/gaze combination.
///
/// No pixel ever gets asserted here, because none can be: this is a
/// `CALayer` tree, and a test that decoded `CGPath`s to check a curve would
/// be testing Core Animation's path representation, not this view's logic.
/// Every test below goes through a narrow `...ForTesting` seam instead,
/// following `TimelineView.markerTrackHeightForTesting`'s existing pattern,
/// and asserts on the RESOLVED state — the same numbers `refresh()` hands to
/// the layers, one step before they become geometry nothing here can read
/// back.
@Suite(.serialized)
@MainActor
struct MascotViewTests {
    init() { _ = NSApplication.shared }

    private func view() -> MascotView {
        MascotView(frame: NSRect(x: 0, y: 0, width: 150, height: 115))
    }

    // MARK: - Idle

    @Test("Idle gives both eyes open and the idle mouth")
    func idleIsOpenAndNeutral() {
        // Catches: a default/idle state that accidentally starts shut (ry
        // near 0) or already smiling (the happy path substituted for idle) —
        // either would make the mascot look wrong before anything has
        // happened to it at all.
        let v = view()
        v.setMoodForTesting(.idle)
        #expect(v.leftEyeRyForTesting == 6.4)
        #expect(v.rightEyeRyForTesting == 6.4)
        #expect(v.mouthPathForTesting == "M44 61c3.6 3.4 11.4 3.4 15 0")
    }

    @Test("Blink shuts both eyes and drops both pupils, but keeps the idle mouth")
    func blinkShutsBothEyesSymmetrically() {
        // Catches: a blink implemented as a WINK (only one eye shutting) by
        // reusing the wrong case, and a blink that also swaps the mouth
        // (blinking is not an expression change, just a shut eye).
        let v = view()
        v.setMoodForTesting(.blink)
        #expect(v.leftEyeRyForTesting == 0.7)
        #expect(v.rightEyeRyForTesting == 0.7)
        #expect(v.leftPupilRadiusForTesting == 0)
        #expect(v.rightPupilRadiusForTesting == 0)
        #expect(v.mouthPathForTesting == "M44 61c3.6 3.4 11.4 3.4 15 0")
    }

    @Test("Wink shuts only the left eye, leaving the right open")
    func winkIsAsymmetric() {
        // Catches: `wink` accidentally sharing `blink`'s symmetric geometry
        // (the two are easy to confuse since both are "an eye closes"), and
        // catches the two eyes' ry being swapped (right shut, left open).
        let v = view()
        v.setMoodForTesting(.wink)
        #expect(v.leftEyeRyForTesting == 0.7)
        #expect(v.rightEyeRyForTesting == 6.4)
        #expect(v.leftPupilRadiusForTesting == 0)
        #expect(v.rightPupilRadiusForTesting == 1.8)
        #expect(v.mouthPathForTesting == "M43 60c4 4.6 12 4.6 16 0")
    }

    // MARK: - Poke

    @Test("A poke on the left shuts the left eye and leaves the right wide, not narrowed")
    func pokeLeftIsAsymmetricAndWide() {
        // Catches the exact regression this file's spec calls out: an
        // earlier design NARROWED the other eye (resentful), which is wrong
        // on its own terms even before the sulk/tear was removed. This
        // asserts the other eye is WIDER than idle (7.4 > 6.4), not merely
        // "not shut".
        let v = view()
        v.pokeForTesting(.left)
        #expect(v.leftEyeRyForTesting == 0.5)
        #expect(v.leftPupilRadiusForTesting == 0)
        #expect(v.rightEyeRyForTesting == 7.4)
        #expect(v.rightEyeRyForTesting > 6.4)
        #expect(v.rightPupilRadiusForTesting == 1.6)
    }

    @Test("A poke on the right mirrors a poke on the left")
    func pokeRightIsAsymmetricAndWide() {
        // Catches the left/right geometry being transposed onto the wrong
        // eye — a copy-paste of `pokeLeft`'s case that forgot to swap which
        // side shuts.
        let v = view()
        v.pokeForTesting(.right)
        #expect(v.rightEyeRyForTesting == 0.5)
        #expect(v.rightPupilRadiusForTesting == 0)
        #expect(v.leftEyeRyForTesting == 7.4)
        #expect(v.leftPupilRadiusForTesting == 1.6)
    }

    @Test("A poke on the left and a poke on the right pick different, mirrored mouth paths")
    func pokeMouthsDifferByTiltedSide() {
        // Catches the single most likely transcription slip in this file:
        // the two asymmetric grimace paths differ only in the sign of a few
        // numbers, so a copy that forgot to flip a sign would make both
        // sides draw identically.
        let v = view()
        v.pokeForTesting(.left)
        let left = v.mouthPathForTesting
        v.pokeForTesting(.right)
        let right = v.mouthPathForTesting
        #expect(left == "M43.5 60.6q3.7 -1.2 7.4 0.8t7.4 1.4")
        #expect(right == "M43.5 62.8q3.7 1.4 7.4 -0.8t7.4 -1.4")
        #expect(left != right)
    }

    @Test("Poking again mid-ouch restarts cleanly rather than stacking")
    func pokingAgainMidOuchRestartsCleanly() {
        // Catches a second poke's recovery timer stacking on top of the
        // first's instead of replacing it — which would eventually resolve
        // the mood to whichever timer happened to fire LAST rather than
        // reflecting the most recent poke, and would leave an orphaned timer
        // pointed at the view after it believed itself idle.
        let v = view()
        v.pokeForTesting(.left)
        v.pokeForTesting(.right)
        #expect(v.mood == .pokeRight)
        #expect(v.rightEyeRyForTesting == 0.5)
        #expect(v.leftEyeRyForTesting == 7.4)
    }

    // MARK: - Keenness

    @Test("Keenness is applied while idle: it raises eye ry and pupil radius")
    func keennessAppliesWhenIdle() {
        // Catches keenness being ignored entirely (a no-op `keenness` setter)
        // and catches the ry/pupil-radius coefficients being swapped or
        // dropped.
        let v = view()
        v.setMoodForTesting(.idle)
        v.keenness = 1.0
        #expect(v.leftEyeRyForTesting == 6.4 + 1.7)
        #expect(v.rightEyeRyForTesting == 6.4 + 1.7)
        #expect(v.leftPupilRadiusForTesting == 1.8 + 0.25)
    }

    @Test("Keenness switches the mouth to happy only above 0.5")
    func keennessSwitchesMouthPastHalf() {
        // Catches an off-by-threshold error (using >= 0.5, or a different
        // cutoff entirely) and catches the mouth never switching at all.
        let v = view()
        v.setMoodForTesting(.idle)
        v.keenness = 0.5
        #expect(v.mouthPathForTesting == "M44 61c3.6 3.4 11.4 3.4 15 0", "0.5 itself must not yet switch it")
        v.keenness = 0.51
        #expect(v.mouthPathForTesting == "M42 59c4.6 7 13.4 7 18 0")
    }

    @Test("Keenness is ignored while blinking")
    func keennessIgnoredWhileBlinking() {
        // Catches keenness being applied unconditionally rather than gated
        // to idle — a blink with keenness added on top would never fully
        // shut, since 0.7 + up to 1.7 no longer reads as closed.
        let v = view()
        v.keenness = 1.0
        v.setMoodForTesting(.blink)
        #expect(v.leftEyeRyForTesting == 0.7)
        #expect(v.rightEyeRyForTesting == 0.7)
    }

    @Test("Keenness is ignored while poked")
    func keennessIgnoredWhilePoked() {
        // Same gate, the other state that must outrank keenness: a flinch
        // outranks "wanting" to be recorded exactly as a blink does.
        let v = view()
        v.keenness = 1.0
        v.pokeForTesting(.left)
        #expect(v.leftEyeRyForTesting == 0.5)
        #expect(v.rightEyeRyForTesting == 7.4, "keenness must not add onto the startled eye either")
    }

    @Test("Keenness clamps to 0...1 rather than over- or under-shooting")
    func keennessClamps() {
        // Catches a missing clamp letting an out-of-range owner-supplied
        // value (an easing curve briefly overshooting 1, or a negative
        // transient) push the eye ry or pupil radius past what the shapes in
        // this file were designed to draw.
        let v = view()
        v.setMoodForTesting(.idle)
        v.keenness = 4.0
        #expect(v.leftEyeRyForTesting == 6.4 + 1.7)
        v.keenness = -3.0
        #expect(v.leftEyeRyForTesting == 6.4)
    }

    // MARK: - Gaze

    @Test("Gaze is clamped: a pointer far outside the view does not push pupils outside the eye")
    func gazeClampsForFarPointers() {
        // Catches a missing `min(1, distance / reach)` clamp, which would
        // scale the offset by raw distance/reach unbounded — for a pointer
        // thousands of units away that produces an offset dozens of times
        // the eye's own radius, instead of the same bounded offset as a
        // pointer sitting exactly at the clamp's reach.
        let v = view()
        v.simulateGazeForTesting(pointerDesignUnits: CGPoint(x: 100_000, y: 100_000))
        let offset = v.gazeOffsetForTesting
        #expect(abs(offset.dx) <= 2.3 + 0.001)
        #expect(abs(offset.dy) <= 2.7 + 0.001)
    }

    @Test("Gaze toward the right eye's side offsets pupils rightward, not leftward")
    func gazeDirectionIsSane() {
        // Catches a sign flip in the gaze vector (pointer on the right
        // producing a LEFTWARD pupil offset), which would make the mascot
        // look away from the pointer instead of toward it.
        let v = view()
        v.simulateGazeForTesting(pointerDesignUnits: CGPoint(x: 1000, y: 46))
        #expect(v.gazeOffsetForTesting.dx > 0)
    }

    @Test("A centred pointer produces no gaze offset")
    func gazeAtMidpointIsZero() {
        // Catches a distance-from-origin calculation that doesn't actually
        // use the eye midpoint, which would report a nonzero offset even
        // when the pointer sits exactly between the eyes.
        let v = view()
        v.simulateGazeForTesting(pointerDesignUnits: CGPoint(x: 51.5, y: 46))
        #expect(v.gazeOffsetForTesting.dx == 0)
        #expect(v.gazeOffsetForTesting.dy == 0)
    }

    // MARK: - isNodding / keenness independence

    @Test("isNodding and keenness are independent of each other")
    func nodAndKeennessAreIndependent() {
        // Catches the two owner-facing properties being wired together by
        // mistake (one setter's didSet reaching into the other), which would
        // make a hover-driven keenness change silently start or stop the
        // Record-button nod, or vice versa.
        let v = view()
        v.setMoodForTesting(.idle)
        v.isNodding = true
        v.keenness = 0.2
        #expect(v.isNodding == true)
        v.keenness = 0
        #expect(v.isNodding == true, "changing keenness must not touch isNodding")
        v.isNodding = false
        #expect(v.keenness == 0, "changing isNodding must not touch keenness")
    }

    // MARK: - The poke buttons

    @Test("Both poke buttons exist, are enabled, borderless, and carry the spec's accessibility labels")
    func pokeButtonsAreAccessible() {
        // Catches the eyes being made clickable via a raw `mouseDown` hit
        // test instead of real `NSButton`s, which — unlike this — Tab could
        // never reach, and catches the two accessibility labels being
        // swapped or left as the default empty string.
        let v = view()
        let left = v.leftPokeButtonForTesting
        let right = v.rightPokeButtonForTesting
        #expect(left.isEnabled)
        #expect(right.isEnabled)
        #expect(left.isBordered == false)
        #expect(right.isBordered == false)
        #expect(left.accessibilityLabel() == "Poke the left eye")
        #expect(right.accessibilityLabel() == "Poke the right eye")
        #expect(left.superview === v)
        #expect(right.superview === v)
    }

    @Test("Activating the left poke button's action pokes the left eye")
    func leftButtonActionReachesPoke() {
        // Catches the button's target/action being left unwired (a button
        // that exists and is labelled but does nothing when activated,
        // which Tab-and-Return would never reveal without this test).
        let v = view()
        let button = v.leftPokeButtonForTesting
        _ = button.target?.perform(button.action, with: button)
        #expect(v.mood == .pokeLeft)
        #expect(v.leftEyeRyForTesting == 0.5)
    }

    @Test("Activating the right poke button's action pokes the right eye")
    func rightButtonActionReachesPoke() {
        let v = view()
        let button = v.rightPokeButtonForTesting
        _ = button.target?.perform(button.action, with: button)
        #expect(v.mood == .pokeRight)
        #expect(v.rightEyeRyForTesting == 0.5)
    }

    // MARK: - Palette

    @Test("Switching palette does not itself change the mood or geometry decisions")
    func paletteSwitchLeavesGeometryAlone() {
        // Catches `palette`'s setter accidentally resetting `mood` or
        // `keenness` as a side effect of `refresh()` — colour and shape are
        // meant to be fully orthogonal here.
        let v = view()
        v.setMoodForTesting(.happy)
        v.palette = .onLight
        #expect(v.mood == .happy)
        #expect(v.mouthPathForTesting == "M42 59c4.6 7 13.4 7 18 0")
    }
}
