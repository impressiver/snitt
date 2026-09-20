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
/// **WHICH sources get a band is not decided here** (D110). This type takes
/// the list and divides the height; `AudioTrackOrder.recorded` decides what is
/// on the list, from evidence — `CaptureHealth` and the document's takes —
/// that geometry has no business reading. The filter that used to live here
/// consulted `trackStates` alone and could never remove anything, because
/// `EditDecisionList.fullRange()` writes both audio states at `start()`.
///
/// Pure, and returns rects rather than drawing them, so band geometry is
/// testable without a window — the same split that made `CropGeometry` and
/// `openingContentRect` testable.
enum TimelineTrackLayout {
    /// Band rects, bottom-up in AppKit's flipped-off coordinate space, matching
    /// how `TimelineView.draw` already lays out marker/video/audio.
    ///
    /// Returns `nil` band entries for audio sources the recording lacks rather
    /// than shrinking the others, so a mic-less recording gives its whole audio
    /// allowance to system audio instead of leaving a dead strip.
    ///
    /// The transcript lane's height — fixed, and at the bottom.
    ///
    /// Fixed because a phrase chip is text: it does not get more legible with
    /// more height the way a waveform gets more readable, so surplus belongs
    /// to the bands that can use it. At the bottom because it reads
    /// left-to-right like the prose it comes from, and burying it between two
    /// waveforms would make it one more band to scan past.
    /// One value, defined in the budget, so the lane that is PLANNED and the
    /// lane that is DRAWN cannot be different heights.
    static var transcriptLaneHeight: Double { TimelineLaneBudget.transcriptLaneHeight }

    /// Cuts have no band here, and that is the rev 5 ruling (W11): a cut
    /// collapses the whole stack, so it draws as a full-height seam across
    /// every lane rather than as a strip of its own. The 24pt it used to take
    /// goes back to the filmstrip.
    static func bands(in bounds: CGRect,
                      markerHeight: Double,
                      audioTracks: [String],
                      hasTranscript: Bool = false) -> (marker: CGRect, video: CGRect, audio: [(track: String, rect: CGRect)], transcript: CGRect) {
        let marker = CGRect(x: 0, y: 0, width: bounds.width, height: markerHeight)
        // Claimed off the bottom before anything below the marker lane divides
        // what is left, so adding it never silently shrinks the filmstrip past
        // its floor.
        let transcriptHeight = hasTranscript
            && bounds.height - markerHeight - transcriptLaneHeight
                >= TimelineLaneBudget.minimumVideoHeight ? transcriptLaneHeight : 0
        let transcript = CGRect(x: 0, y: bounds.height - transcriptHeight,
                                width: bounds.width, height: transcriptHeight)
        // Named rather than shadowing `markerHeight`: everything below the
        // marker lane divides what is left, and a rebound parameter makes
        // that arithmetic read as if it used the caller's value.
        let stackTop = markerHeight
        let remaining = max(0, bounds.height - stackTop - transcriptHeight)
        // The budget's constants, not a second copy of them. This read
        // `remaining * 0.6` while the budget was tuned across three commits —
        // so the type that was tested was not the type that DREW, and two
        // rounds of "halve the filmstrip" changed nothing on screen.
        // `bandsMatchThePlan` is the test that stops the two drifting again.
        //
        // Audio takes its preferred height and the filmstrip absorbs the rest,
        // matching `TimelineLaneBudget.distribute` exactly.
        let audioHeight = audioTracks.isEmpty ? 0
            : min(TimelineLaneBudget.preferredAudioHeight,
                  max(TimelineLaneBudget.minimumTargetHeight,
                      (remaining - TimelineLaneBudget.minimumVideoHeight)
                          / Double(audioTracks.count)))
        let videoHeight = max(TimelineLaneBudget.minimumVideoHeight,
                              remaining - audioHeight * Double(audioTracks.count))
        let video = CGRect(x: 0, y: stackTop, width: bounds.width, height: videoHeight)
        let audioTotal = max(0, remaining - videoHeight)
        guard !audioTracks.isEmpty else { return (marker, video, [], transcript) }

        let each = audioTotal / Double(audioTracks.count)
        let audio = audioTracks.enumerated().map { index, track in
            (track: track,
             rect: CGRect(x: 0, y: video.maxY + Double(index) * each,
                          width: bounds.width, height: each))
        }
        return (marker, video, audio, transcript)
    }
}
