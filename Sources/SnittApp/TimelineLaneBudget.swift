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

    /// The filmstrip's floor.
    ///
    /// Halved twice on product-owner direction: 36 -> 18 -> 9 (2026-09-10).
    /// On a 731pt window the band goes 121pt -> 70pt -> ~36pt.
    ///
    /// The filmstrip is now unambiguously a RIBBON, not a row of thumbnails:
    /// it shows WHERE the picture changes and carries no detail about what it
    /// changed to. That is a coherent position — the transcript lane carries
    /// the "what" now, and it did not exist when the filmstrip was sized — but
    /// it is the opposite of the argument that set the timeline to 120pt, and
    /// the next reader should know the reversal was deliberate, not drift.
    public static let minimumVideoHeight: Double = 9

    /// What each lane WANTS to be, when there is room.
    ///
    /// Preferred heights, not shares of a surplus. The old model gave the
    /// timeline a fixed 40% of the window and let the lanes stretch to fill
    /// it — so halving the filmstrip did not give the height back to the
    /// PICTURE, it handed it to the waveforms, which grew to ~101pt each. Two
    /// hundred-point waveforms is worse than the tall filmstrip that was being
    /// fixed.
    ///
    /// Lanes now take what they need and the timeline sizes to fit, capped by
    /// the window share. Everything left over goes to the recording, which is
    /// the whole point of bounding the timeline in the first place.
    public static let preferredVideoHeight: Double = 36
    public static let preferredAudioHeight: Double = 44

    /// The transcript lane's height, and the one place it is written down.
    ///
    /// 30, up 25% from 24 on product-owner direction (2026-09-10). Comfortably
    /// clear of WCAG 2.5.8's 24pt target floor, which a chip must meet anyway
    /// to be clickable — increasing it was safe in a way decreasing it would
    /// not have been.
    public static let transcriptLaneHeight: Double = 30

    /// The most of the window the timeline may take, however much it wants.
    public static let maximumWindowShare: Double = 0.40

    /// Never smaller than this, or the timeline stops being usable at all.
    public static let minimumTimelineHeight: Double
        = minimumTargetHeight + minimumVideoHeight + minimumTargetHeight

    /// What the whole stack wants, given what this recording actually has.
    public static func naturalHeight(audioTracks: [String],
                                     hasTranscript: Bool) -> Double {
        minimumTargetHeight                                    // marks
            + preferredVideoHeight
            + preferredAudioHeight * Double(audioTracks.count)
            + (hasTranscript ? transcriptLaneHeight : 0)
    }


    /// What the timeline should be given, for a window of this height.
    ///
    /// The SMALLER of what the lanes want and what the window allows — not
    /// always the window share. A timeline that always took 40% grew its lanes
    /// to fill it however little they needed, which is how halving the
    /// filmstrip made the waveforms enormous instead of making the picture
    /// bigger.
    public static func timelineHeight(forWindowHeight window: Double,
                                      audioTracks: [String] = ["microphone", "systemAudio"],
                                      hasTranscript: Bool = false) -> Double {
        let wanted = naturalHeight(audioTracks: audioTracks,
                                   hasTranscript: hasTranscript)
        return max(minimumTimelineHeight, min(wanted, window * maximumWindowShare))
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
        let transcriptHeight = transcriptLaneHeight
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
        // Preferred heights, and the filmstrip absorbs whatever is left over.
        //
        // No surplus split any more. `videoShareOfSurplus` is gone with it —
        // a constant tuned three times across three commits, whose only job
        // was deciding which lane got to grow when the timeline was bigger
        // than the lanes needed. The timeline is no longer bigger than the
        // lanes need: it sizes to them.
        let audioHeight = min(preferredAudioHeight,
                              audio.isEmpty ? 0
                                  : max(minimumTargetHeight,
                                        (available - marks - minimumVideoHeight - transcript)
                                            / Double(audio.count)))
        let used = marks + audioHeight * Double(audio.count) + transcript
        let videoHeight = max(minimumVideoHeight, available - used)

        var lanes: [TimelineLanePlan.Lane] = [.init(lane: .marks, height: marks),
                                              .init(lane: .video, height: videoHeight)]
        lanes.append(contentsOf: audio.map { .init(lane: $0, height: audioHeight) })
        if transcript > 0 { lanes.append(.init(lane: .transcript, height: transcript)) }
        return TimelineLanePlan(lanes: lanes, collapsed: collapsed)
    }
}
