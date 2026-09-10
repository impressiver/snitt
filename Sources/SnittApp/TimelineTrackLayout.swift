// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreGraphics
import SnittDocument

/// Where each track band sits in the timeline.
///
/// D56 Tier 1 asked for separate audio and video tracks. Task 6 delivered
/// three bands — markers, video, audio — but drew BOTH audio sources into the
/// single `audio` band, so a recording with the microphone on looked identical
/// to one without, and `TrackState.muted` (which the model has carried since
/// M3) had no representation at all: muting a source changed the export and
/// nothing on screen.
///
/// Pure, and returns rects rather than drawing them, so band geometry is
/// testable without a window — the same split that made `CropGeometry` and
/// `openingContentRect` testable.
enum TimelineTrackLayout {
    /// Which audio sources a recording actually has, in draw order.
    ///
    /// Derived from `trackStates` rather than assumed, because a recording made
    /// with the microphone off has no `microphone` state and must not be given
    /// an empty band implying a source that was never captured.
    static func audioTracks(in states: [TrackState]) -> [String] {
        ["microphone", "systemAudio"].filter { name in states.contains { $0.track == name } }
    }

    /// Band rects, bottom-up in AppKit's flipped-off coordinate space, matching
    /// how `TimelineView.draw` already lays out marker/video/audio.
    ///
    /// Returns `nil` band entries for audio sources the recording lacks rather
    /// than shrinking the others, so a mic-less recording gives its whole audio
    /// allowance to system audio instead of leaving a dead strip.
    /// The fold lane's height — a 24pt strip under the marker lane.
    ///
    /// Folds used to have no lane at all: `foldHit(atX:)` took no y and
    /// matched anywhere in the view, because a fold's line is drawn full
    /// height on purpose. That worked while the stack was marks/video/audio,
    /// and stops working the moment more lanes exist below Video — an ungated
    /// full-height hit swallows clicks aimed at every one of them, which is
    /// the same collision the marker lane already needed a y-gate to survive.
    ///
    /// 24pt: WCAG 2.5.8's enforceable target floor, matching the marker lane.
    static let foldLaneHeight: Double = 24

    static func bands(in bounds: CGRect,
                      markerHeight: Double,
                      audioTracks: [String]) -> (marker: CGRect, fold: CGRect, video: CGRect, audio: [(track: String, rect: CGRect)]) {
        let marker = CGRect(x: 0, y: 0, width: bounds.width, height: markerHeight)
        // The fold lane only earns its 24pt when there is room left for a
        // usable video band underneath; on a very short view the filmstrip is
        // protected and folds fall back to their full-height line alone.
        let foldHeight = bounds.height - markerHeight - foldLaneHeight
            >= TimelineLaneBudget.minimumVideoHeight ? foldLaneHeight : 0
        let fold = CGRect(x: 0, y: markerHeight, width: bounds.width, height: foldHeight)
        // Named rather than shadowing `markerHeight`: everything below the
        // two fixed lanes divides what is left, and a rebound parameter makes
        // that arithmetic read as if it used the caller's value.
        let stackTop = markerHeight + foldHeight
        let remaining = max(0, bounds.height - stackTop)
        let video = CGRect(x: 0, y: stackTop, width: bounds.width, height: remaining * 0.6)
        let audioTotal = remaining * 0.4
        guard !audioTracks.isEmpty else { return (marker, fold, video, []) }

        let each = audioTotal / Double(audioTracks.count)
        let audio = audioTracks.enumerated().map { index, track in
            (track: track,
             rect: CGRect(x: 0, y: video.maxY + Double(index) * each,
                          width: bounds.width, height: each))
        }
        return (marker, fold, video, audio)
    }
}
