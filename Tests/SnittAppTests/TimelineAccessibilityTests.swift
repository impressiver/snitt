// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp
@testable import SnittDocument

/// What a screen reader is told about the timeline.
///
/// The timeline is a Core Graphics canvas — marks, folds and the playhead are
/// pixels, and pixels have no accessibility. Everything here was unreachable
/// without a pointer until now, including the marks, which are how you
/// navigate a Snitt recording.
@Suite
struct TimelineAccessibilityTests {
    private func mark(_ label: String, _ time: Double) -> JumpPoint {
        JumpPoint(id: UUID(), timeSeconds: time, label: label,
                  transcript: nil, isInsideCut: false)
    }

    @Test("A mark leads with its own words, not with its index")
    func markLeadsWithItsLabel() {
        // The label is the differentiator — what an agent writes and what
        // `snitt_inspect` reads back. "Mark 3 of 7" describes the list; this
        // has to describe the recording.
        let label = TimelineAccessibility.markLabel(mark("Fix the off-by-one", 8))
        #expect(label.hasPrefix("Fix the off-by-one"))
        #expect(label.contains("0:08"))
    }

    @Test("An unlabelled mark says so rather than announcing silence")
    func unlabelledMarkIsNamed() {
        // A real case: a hotkey press with nothing typed after it. An empty
        // string is announced as nothing at all, which a listener cannot tell
        // from the rotor having found nothing.
        #expect(TimelineAccessibility.markLabel(mark("", 8)) == "Unlabelled mark, at 0:08")
        #expect(TimelineAccessibility.markLabel(mark("   ", 8)) == "Unlabelled mark, at 0:08")
    }

    @Test("A fold says what it REMOVED")
    func foldSaysWhatItRemoved() {
        // The question at a fold is "what am I not hearing", and the answer is
        // a duration. Its position is implied by where the rotor already is.
        let label = TimelineAccessibility.foldLabel(
            FoldDescriptor(outputSeconds: 12, removedSeconds: 95))
        #expect(label.contains("1:35 removed"))
        #expect(label.contains("0:12"))
    }

    @Test("A sub-second fold is not rounded away to zero")
    func shortFoldKeepsItsPrecision() {
        // `m:ss` renders 0.4s as "0:00" — a fold announced as removing nothing
        // is worse than one announced imprecisely.
        let label = TimelineAccessibility.foldLabel(
            FoldDescriptor(outputSeconds: 3, removedSeconds: 0.4))
        #expect(label.contains("0.4 seconds removed"))
        #expect(!label.contains("0:00 removed"))
    }

    @Test("Marks and folds interleave in time order")
    func elementsAreInterleavedByTime() {
        // Grouped — every mark, then every fold — describes a different
        // recording than the one on screen. The rotor steps in the order
        // given, and that order is the listener's mental model.
        let elements = TimelineAccessibility.elements(
            marks: [mark("start", 0), mark("later", 20)],
            folds: [FoldDescriptor(outputSeconds: 10, removedSeconds: 4)])
        #expect(elements.map(\.kind) == [.mark, .fold, .mark])
        #expect(elements.map(\.outputSeconds) == [0, 10, 20])
    }

    @Test("The timeline reports where the playhead is, in context")
    func playheadValueIsPositional() {
        // "0:08" alone says nothing about how far through you are.
        #expect(TimelineAccessibility.playheadValue(outputSeconds: 8, duration: 26)
                == "0:08 of 0:26")
    }

    @Test("Spoken times use the app's one clock format")
    func clockMatchesTheRestOfTheApp() {
        // A third rendering of a duration is a third thing that can disagree
        // about what 90 seconds is called. This is the same formatter the
        // menu-bar item and the recording HUD use.
        #expect(TimelineAccessibility.clock(95)
                == RecordingState.clock(95))
    }

    @Test("An empty timeline exposes nothing rather than a phantom element")
    func emptyTimelineIsEmpty() {
        #expect(TimelineAccessibility.elements(marks: [], folds: []).isEmpty)
    }
}
