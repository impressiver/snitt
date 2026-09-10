// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// How the timeline spends the height it is given, and what it gives up first.
@Suite
struct TimelineLaneBudgetTests {
    private let both = ["microphone", "systemAudio"]

    @Test("The timeline is bounded by the window, so the picture stops being the only thing that shrinks")
    func heightScalesWithTheWindow() {
        // The defect this replaces: a fixed 120pt frame made the picture the
        // only flexible dimension, so on a short window the recording — the
        // thing meant to be largest — gave up every pixel and the timeline
        // gave up none.
        let tall = TimelineLaneBudget.timelineHeight(forWindowHeight: 900)
        let short = TimelineLaneBudget.timelineHeight(forWindowHeight: 600)
        #expect(tall > short, "the timeline did not scale with the window")
        #expect(tall == 900 * TimelineLaneBudget.maximumWindowShare)
    }

    @Test("The timeline never grows past its share of the window")
    func heightIsCapped() {
        // Unbounded, a tall display would hand the timeline half the screen
        // for six lanes that need a couple of hundred points.
        let height = TimelineLaneBudget.timelineHeight(forWindowHeight: 2000)
        #expect(height <= 2000 * TimelineLaneBudget.maximumWindowShare)
    }

    @Test("A tiny window still gets a usable timeline")
    func heightHasAFloor() {
        // 40% of a very short window is not a timeline, it is a stripe. The
        // floor is what the minimums actually need.
        #expect(TimelineLaneBudget.timelineHeight(forWindowHeight: 100)
                == TimelineLaneBudget.minimumTimelineHeight)
    }

    @Test("With room, both audio sources get their own band")
    func roomyPlanKeepsEverything() {
        let plan = TimelineLaneBudget.plan(availableHeight: 200, audioTracks: both)
        #expect(plan.lanes.map(\.lane) == [.marks, .video,
                                           .audio("microphone"), .audio("systemAudio")])
        #expect(plan.collapsed.isEmpty)
    }

    @Test("Squeezed, the two audio sources MERGE before either disappears")
    func audioMergesBeforeItDisappears() {
        // The collapse order three reviewers reached independently. Dropping a
        // source outright while there is room for a composite loses a whole
        // signal to save 24pt.
        let plan = TimelineLaneBudget.plan(availableHeight: 90, audioTracks: both)
        #expect(plan.lanes.map(\.lane) == [.marks, .video, .audioComposite])
        #expect(plan.collapsed == both, "a merge that does not report itself cannot be undone")
    }

    @Test("Squeezed further, audio goes and the filmstrip survives")
    func filmstripIsProtectedLast() {
        // The spine. You can navigate a recording by pictures with no
        // waveform; the reverse is not true. An implementation that dropped
        // video first would pass every other test here.
        let plan = TimelineLaneBudget.plan(availableHeight: 62, audioTracks: both)
        #expect(plan.lanes.map(\.lane) == [.marks, .video])
        #expect(plan.collapsed == both)
    }

    @Test("Every lane clears the 24pt target floor")
    func lanesMeetTheTargetFloor() {
        // WCAG 2.5.8 AA. Marks are draggable and audio bands are click
        // targets; a lane below this is a control nobody can reliably hit.
        for height in stride(from: 84.0, through: 400, by: 7) {
            let plan = TimelineLaneBudget.plan(availableHeight: height, audioTracks: both)
            for lane in plan.lanes {
                #expect(lane.height >= TimelineLaneBudget.minimumTargetHeight
                        || lane.lane == .video,
                        "\(lane.lane) is \(lane.height)pt at \(height)pt available")
            }
            #expect(try! #require(plan.height(of: .video))
                    >= TimelineLaneBudget.minimumVideoHeight)
        }
    }

    @Test("The plan spends exactly what it is given, never more")
    func planFitsItsBudget() {
        // Overshooting is how lanes end up drawn outside the view, clipped
        // with no warning.
        for height in stride(from: 84.0, through: 400, by: 11) {
            let plan = TimelineLaneBudget.plan(availableHeight: height, audioTracks: both)
            #expect(abs(plan.totalHeight - height) < 0.001,
                    "plan totals \(plan.totalHeight) for \(height)pt")
        }
    }

    @Test("Surplus is split 60/40, the same ratio the shipped bands use")
    func surplusMatchesTheShippedRatio() {
        // Two ratios for one layout is how bands start disagreeing about who
        // grows. This is D56's split, kept rather than re-chosen.
        let plan = TimelineLaneBudget.plan(availableHeight: 300, audioTracks: both)
        let video = try! #require(plan.height(of: .video))
        let audio = try! #require(plan.height(of: .audio("microphone")))
        let surplus: Double = 300 - 24 - 36 - 48
        let expectedVideo: Double = 36 + surplus * 0.6
        let expectedAudio: Double = 24 + (surplus * 0.4) / 2
        #expect(abs(video - expectedVideo) < 0.001)
        #expect(abs(audio - expectedAudio) < 0.001)
    }

    @Test("A recording with one audio source is not merged into a composite")
    func singleSourceIsNeverComposite() {
        // "Composite" means two signals in one band. Labelling a lone
        // microphone as a composite would tell the user something was folded
        // away when nothing was.
        let plan = TimelineLaneBudget.plan(availableHeight: 90, audioTracks: ["microphone"])
        #expect(plan.lanes.map(\.lane) == [.marks, .video, .audio("microphone")])
        #expect(plan.collapsed.isEmpty)
    }

    @Test("A silent recording gives its whole allowance to the picture")
    func noAudioMeansNoEmptyBand() {
        let plan = TimelineLaneBudget.plan(availableHeight: 200, audioTracks: [])
        #expect(plan.lanes.map(\.lane) == [.marks, .video])
        #expect(abs(try! #require(plan.height(of: .video)) - (200 - 24)) < 0.001,
                "a dead strip was left where audio would have been")
    }

    @Test("With room, the transcript lane joins the stack")
    func transcriptLaneAppearsWhenItFits() {
        let plan = TimelineLaneBudget.plan(availableHeight: 220, audioTracks: both,
                                           hasTranscript: true)
        #expect(plan.lanes.map(\.lane).contains(.transcript))
        #expect(abs(try! #require(plan.height(of: .transcript))
                    - TimelineLaneBudget.minimumTargetHeight) < 0.001)
    }

    @Test("The transcript lane is the FIRST thing to go")
    func transcriptHidesBeforeAudioMerges() {
        // The collapse order three reviewers reached independently. At a
        // height where both audio bands still fit separately, the transcript
        // must be what yields — merging audio first would trade a signal the
        // waveform cannot replace for one the reading pane already shows at
        // any window size.
        let plan = TimelineLaneBudget.plan(availableHeight: 110, audioTracks: both,
                                           hasTranscript: true)
        #expect(!plan.lanes.map(\.lane).contains(.transcript))
        #expect(plan.lanes.map(\.lane) == [.marks, .video,
                                           .audio("microphone"), .audio("systemAudio")])
    }

    @Test("A recording with no transcript is never given an empty lane for one")
    func noTranscriptMeansNoLane() {
        let plan = TimelineLaneBudget.plan(availableHeight: 300, audioTracks: both,
                                           hasTranscript: false)
        #expect(!plan.lanes.map(\.lane).contains(.transcript))
    }

    @Test("The transcript lane is fixed height, not proportional")
    func transcriptDoesNotGrowWithTheWindow() {
        // A phrase chip is text. Text does not get more legible with more
        // height the way a waveform gets more readable, so surplus belongs to
        // the bands that can use it.
        let small = TimelineLaneBudget.plan(availableHeight: 220, audioTracks: both,
                                            hasTranscript: true)
        let large = TimelineLaneBudget.plan(availableHeight: 500, audioTracks: both,
                                            hasTranscript: true)
        #expect(abs(try! #require(small.height(of: .transcript))
                    - (try! #require(large.height(of: .transcript)))) < 0.001)
    }

    @Test("Anything collapsed is reported, so it can be offered back")
    func collapseIsAlwaysReported() {
        // A lane that vanishes on a window resize with no record of it is
        // content lost with no way back except un-resizing — and no keyboard
        // path at all.
        for height in stride(from: 40.0, through: 120, by: 6) {
            let plan = TimelineLaneBudget.plan(availableHeight: height, audioTracks: both)
            let showsBothSeparately = plan.lanes.contains { $0.lane == .audio("microphone") }
                && plan.lanes.contains { $0.lane == .audio("systemAudio") }
            #expect(showsBothSeparately == plan.collapsed.isEmpty,
                    "at \(height)pt the plan hid a source without saying so")
        }
    }
}
