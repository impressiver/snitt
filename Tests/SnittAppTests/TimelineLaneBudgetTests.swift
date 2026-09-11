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

    @Test("A small window shrinks the timeline, not the picture alone")
    func boundBitesDownward() {
        // This replaces a test asserting the timeline GREW with the window,
        // which was the behaviour that made the waveforms enormous. The bound
        // still matters, in the direction it was written for: when the window
        // cannot afford what the lanes want, the timeline gives way rather
        // than pushing the picture out.
        let cramped = TimelineLaneBudget.timelineHeight(
            forWindowHeight: 300, audioTracks: both, hasTranscript: true)
        let roomy = TimelineLaneBudget.timelineHeight(
            forWindowHeight: 900, audioTracks: both, hasTranscript: true)
        #expect(cramped < roomy, "a cramped window did not shrink the timeline")
        #expect(cramped <= 300 * TimelineLaneBudget.maximumWindowShare + 0.001)
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
        // Separate bands need marks 24 + video 18 + 24 each = 90; a composite
        // needs 66. 80 sits between, which is what squeezes.
        let plan = TimelineLaneBudget.plan(availableHeight: 80, audioTracks: both)
        #expect(plan.lanes.map(\.lane) == [.marks, .video, .audioComposite])
        #expect(plan.collapsed == both, "a merge that does not report itself cannot be undone")
    }

    @Test("Squeezed further, audio goes and the filmstrip survives")
    func filmstripIsProtectedLast() {
        // The spine. You can navigate a recording by pictures with no
        // waveform; the reverse is not true. An implementation that dropped
        // video first would pass every other test here.
        // Below a composite's 66pt, only marks and the filmstrip survive.
        let plan = TimelineLaneBudget.plan(availableHeight: 50, audioTracks: both)
        #expect(plan.lanes.map(\.lane) == [.marks, .video])
        #expect(plan.collapsed == both)
    }

    @Test("The filmstrip's share is half the audio bands', not more")
    func filmstripNoLongerDominates() {
        // Asserted as a relationship rather than a number: whatever the
        // preferred heights are, a filmstrip band is shorter than a waveform
        // band. A test pinning the constants would pass if the distribution
        // stopped using them.
        let natural = TimelineLaneBudget.naturalHeight(audioTracks: both,
                                                       hasTranscript: false)
        let plan = TimelineLaneBudget.plan(availableHeight: natural, audioTracks: both)
        let video = try! #require(plan.height(of: .video))
        let audio = try! #require(plan.height(of: .audio("microphone")))
        #expect(video < audio, "the filmstrip is \(video)pt against a \(audio)pt waveform")
    }

    @Test("The transcript lane is taller than the target floor, not equal to it")
    func transcriptLaneClearsTheFloor() {
        // Raised 25% above 24. Worth its own assertion because 24 is also the
        // WCAG target minimum, and a lane that merely EQUALS the floor is one
        // refactor away from dropping below it.
        let plan = TimelineLaneBudget.plan(availableHeight: 260, audioTracks: both,
                                           hasTranscript: true)
        let transcript = try! #require(plan.height(of: .transcript))
        #expect(transcript > TimelineLaneBudget.minimumTargetHeight)
        #expect(abs(transcript - 30) < 0.001)
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

    @Test("Lanes take what they NEED; the timeline sizes to them")
    func lanesTakeTheirPreferredHeights() {
        // Replaces a surplus-split test. The old model gave the timeline a
        // fixed 40% of the window and let lanes stretch to fill it, so halving
        // the filmstrip handed the height to the WAVEFORMS — ~101pt each —
        // rather than back to the picture. Lanes now take a preferred height
        // and the timeline sizes to the total.
        let natural = TimelineLaneBudget.naturalHeight(
            audioTracks: both, hasTranscript: true)
        let plan = TimelineLaneBudget.plan(availableHeight: natural, audioTracks: both,
                                           hasTranscript: true)
        #expect(abs(try! #require(plan.height(of: .audio("microphone")))
                    - TimelineLaneBudget.preferredAudioHeight) < 0.001)
        #expect(abs(try! #require(plan.height(of: .video))
                    - TimelineLaneBudget.preferredVideoHeight) < 0.001)
    }

    @Test("A tall window does not inflate the lanes")
    func extraWindowGoesToThePicture() {
        // The behaviour the product owner reported as "audio lanes way too
        // tall". More window must mean a bigger PICTURE, not fatter waveforms
        // — bounding the timeline is pointless if the lanes expand to consume
        // whatever the bound allows.
        let short = TimelineLaneBudget.timelineHeight(
            forWindowHeight: 700, audioTracks: both, hasTranscript: true)
        let tall = TimelineLaneBudget.timelineHeight(
            forWindowHeight: 1600, audioTracks: both, hasTranscript: true)
        #expect(abs(short - tall) < 0.001, "the timeline grew with the window")
    }

    @Test("A cramped window still caps the timeline at its share")
    func smallWindowStillCaps() {
        // The bound has to keep working in the direction it was written for:
        // on a short window the lanes cannot have everything they want.
        let height = TimelineLaneBudget.timelineHeight(
            forWindowHeight: 400, audioTracks: both, hasTranscript: true)
        #expect(height <= 400 * TimelineLaneBudget.maximumWindowShare + 0.001)
        #expect(height >= TimelineLaneBudget.minimumTimelineHeight)
    }

    @Test("A recording with fewer lanes gets a shorter timeline")
    func fewerLanesMeansMorePicture() {
        // No transcript and no cuts is two fewer lanes. Claiming the height
        // anyway would stretch the rest to fill it, which is the bug.
        let full = TimelineLaneBudget.naturalHeight(audioTracks: both,
                                                    hasTranscript: true)
        let spare = TimelineLaneBudget.naturalHeight(audioTracks: both,
                                                     hasTranscript: false)
        #expect(spare < full)
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
                    - TimelineLaneBudget.transcriptLaneHeight) < 0.001)
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
