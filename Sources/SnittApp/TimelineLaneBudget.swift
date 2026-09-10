// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreGraphics
import Foundation

/// A lane the timeline can show.
public enum TimelineLane: Equatable, Sendable {
    case marks
    case video
    /// One band per captured source.
    case audio(String)
    /// Microphone and system audio drawn as a single band, when there is not
    /// room for both.
    case audioComposite
    /// Phrase chips from the transcript (D89). First to go when space is
    /// short — it is the most deferrable thing on the timeline, and the
    /// reading pane says the same words at any window size.
    case transcript
}

/// What the timeline shows at a given height, and what it had to give up.
public struct TimelineLanePlan: Equatable, Sendable {
    /// Lanes top to bottom, with the height each gets.
    public let lanes: [Lane]
    /// Sources folded into `audioComposite`, or dropped entirely. Non-empty
    /// means the UI owes the user a way to get them back.
    public let collapsed: [String]

    public struct Lane: Equatable, Sendable {
        public let lane: TimelineLane
        public let height: Double
    }

    public var totalHeight: Double { lanes.reduce(0) { $0 + $1.height } }
    public func height(of lane: TimelineLane) -> Double? {
        lanes.first { $0.lane == lane }?.height
    }
}

/// How much vertical room the timeline gets, and how it spends it.
///
/// Two problems, one place. The timeline was a fixed 120pt frame, which made
/// the PICTURE the only thing that could shrink — on a short window the
/// recording, the thing the product owner asked to be largest, gave up every
/// pixel while the timeline kept all of its own. And the shipped
/// `TimelineTrackLayout.bands` already allocated band height as a proportion
/// of whatever it was given, so replacing that with fixed rows would have
/// discarded a scaling model that already worked.
///
/// Pure, like every other geometry decision in this project: what collapses
/// and when is arithmetic, and arithmetic does not need a window to be wrong.
public enum TimelineLaneBudget {

    /// The enforceable minimum for something you can click or drag
    /// (WCAG 2.5.8 AA). Marks are draggable and audio bands are click targets,
    /// so this is a floor rather than a preference. Note the shipped
    /// `markerTrackHeight` is `min(14.0, …)` — below this, and a separate
    /// defect.
    public static let minimumTargetHeight: Double = 24

    /// The filmstrip's floor. Lower and a thumbnail stops being a picture,
    /// which is the one thing the video band exists to be.
    public static let minimumVideoHeight: Double = 36

    /// The share of surplus the video band takes, matching the 60/40 split
    /// `TimelineTrackLayout.bands` has used since D56. Kept rather than
    /// re-chosen: two ratios for one layout is how the bands start disagreeing
    /// about who grows.
    public static let videoShareOfSurplus: Double = 0.6

    /// The tallest the timeline may be, as a share of the window.
    ///
    /// 40%, not 35%. The full stack — marks 24, video 36, two audio bands at
    /// 24 — needs 108pt of lanes before any surplus, and a 731pt window (what
    /// `openingContentRect` opens at on a 1600×975 screen) at 35% leaves about
    /// 172pt after the transport row and ruler. That fits today, but the fold
    /// and word lanes are queued and each costs 24pt more; 40% is the number
    /// that still fits once they land, and going the other way later would
    /// mean the timeline growing under the user.
    public static let maximumWindowShare: Double = 0.40

    /// Never smaller than this, or the timeline stops being usable at all.
    public static let minimumTimelineHeight: Double
        = minimumTargetHeight + minimumVideoHeight + minimumTargetHeight

    /// What the timeline should be given, for a window of this height.
    public static func timelineHeight(forWindowHeight window: Double) -> Double {
        max(minimumTimelineHeight, window * maximumWindowShare)
    }

    /// Which lanes fit in `availableHeight`, and how tall each is.
    ///
    /// The collapse order is the one three reviewers reached independently:
    /// audio sources merge into a single composite before any of them
    /// disappears, audio disappears before the filmstrip gives up its floor,
    /// and the filmstrip is protected last because it is the spine — you can
    /// navigate a recording by pictures with no waveform, and not the reverse.
    public static func plan(availableHeight: Double,
                            audioTracks: [String],
                            hasTranscript: Bool = false) -> TimelineLanePlan {
        let available = max(0, availableHeight)
        let marks = minimumTargetHeight
        // The transcript lane is fixed rather than proportional: a phrase chip
        // is text, and text does not get more legible with more height the way
        // a waveform gets more readable. Extra room belongs to the bands that
        // can use it.
        let transcriptHeight = minimumTargetHeight
        let transcript = hasTranscript
            && available >= marks + minimumVideoHeight
                + minimumTargetHeight * Double(max(1, audioTracks.count)) + transcriptHeight
            ? transcriptHeight : 0

        // Attempts, roomiest first. The first that fits its own minimums wins,
        // which is what makes the collapse order a list rather than a pile of
        // conditionals.
        let separate = marks + minimumVideoHeight
            + minimumTargetHeight * Double(audioTracks.count)
        let composite = marks + minimumVideoHeight + minimumTargetHeight
        let videoOnly = marks + minimumVideoHeight

        if audioTracks.count > 0, available >= separate + transcript {
            return distribute(available: available, marks: marks,
                              audio: audioTracks.map { TimelineLane.audio($0) },
                              transcript: transcript, collapsed: [])
        }
        // Only reachable with two or more sources. With one, `composite` and
        // `separate` are the same number — a single band either way — so the
        // branch above has already taken it, and a `count == 1` arm here would
        // be unreachable. An earlier version had exactly that arm; a mutant
        // that changed this condition to `> 0` survived, which is what
        // revealed the code below it was dead rather than the test being weak.
        if audioTracks.count > 1, available >= composite {
            return distribute(available: available, marks: marks,
                              audio: [.audioComposite], transcript: 0,
                              collapsed: audioTracks)
        }
        // Below every audio arrangement: the filmstrip keeps what is left.
        // `collapsed` names what went, so the UI can offer it back — a lane
        // that vanishes with no way to reach it is content lost to a window
        // resize, with no keyboard path to recover it.
        return distribute(available: max(available, videoOnly), marks: marks,
                          audio: [], transcript: 0, collapsed: audioTracks)
    }

    private static func distribute(available: Double, marks: Double,
                                   audio: [TimelineLane],
                                   transcript: Double,
                                   collapsed: [String]) -> TimelineLanePlan {
        let audioFloor = minimumTargetHeight * Double(audio.count)
        let surplus = max(0, available - marks - minimumVideoHeight
                              - audioFloor - transcript)
        // With no audio band there is nobody to give audio's 40% to, and it
        // does NOT fall out — an earlier version of this comment claimed it
        // did, and left a 56pt dead strip under the filmstrip on a silent
        // recording. Caught by `noAudioMeansNoEmptyBand`, which is the whole
        // reason that test asserts the video band's height rather than just
        // the absence of an audio lane.
        let videoShare = audio.isEmpty ? 1.0 : videoShareOfSurplus
        let videoHeight = minimumVideoHeight + surplus * videoShare
        let audioShare = audio.isEmpty
            ? 0 : (audioFloor + surplus * (1 - videoShareOfSurplus)) / Double(audio.count)

        var lanes: [TimelineLanePlan.Lane] = [.init(lane: .marks, height: marks),
                                              .init(lane: .video, height: videoHeight)]
        lanes.append(contentsOf: audio.map { .init(lane: $0, height: audioShare) })
        if transcript > 0 { lanes.append(.init(lane: .transcript, height: transcript)) }
        return TimelineLanePlan(lanes: lanes, collapsed: collapsed)
    }
}
