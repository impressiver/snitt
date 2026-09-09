// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Drag-to-select as a pure state machine.
///
/// Kept in `SnittDocument`, importing only Foundation, so the interesting
/// cases — a drag that ends where it started, a drag backwards, a drag that
/// never began — are five ordinary value-type tests with no window, no run
/// loop, no mouse. The `NSView` forwards mouse events into `began`/`moved`/
/// `ended`; the rules live here.
///
/// D56 (M5f Task 4): this type only ever computes the RANGE a drag covers —
/// it has no opinion on what that range becomes. Before this task, the one
/// caller (`TimelineView`) treated a completed drag as an immediate cut,
/// which is the defect D56 names: dragging *was* cutting. Now a completed
/// drag becomes a `Selection` (`SnittDocument/Selection.swift`) instead,
/// and cutting is a separate operation a person applies to it afterwards
/// (`EditorTimelineState.cutSelection()`). Kept as `TimeRange` here rather
/// than returning `Selection` directly: this type stays exactly what it
/// always was — pixel-threshold arithmetic over two endpoints — and stays
/// silent on the vocabulary ("selection" vs. "cut") that only the caller
/// decides.
public struct TrimGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case dragging(from: Double)
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func began(atTime time: Double) {
        phase = .dragging(from: time)
    }

    public mutating func moved(toTime time: Double) {
        guard case .dragging = phase else { return }
        currentTime = time
    }

    /// Ends the drag, returning the range it covered, or `nil` if it was too
    /// short to count as a deliberate selection rather than click jitter.
    ///
    /// `minimumSeconds` is a parameter, not a constant here, deliberately: a
    /// fixed time threshold is wrong in opposite directions depending on
    /// recording length. A hand wobbles by roughly the same number of
    /// *pixels* on any click regardless of what the timeline shows, but the
    /// same pixel count maps to wildly different amounts of media time
    /// depending on how many seconds are squeezed into the view's width — a
    /// ten-minute recording at 800px is ~0.75s/pixel, so a 0.05s threshold
    /// sits under a single pixel and any click becomes a selection; a
    /// five-second recording is ~0.006s/pixel, so the same 0.05s is ~8px and
    /// a deliberate short selection is silently swallowed. Converting a
    /// pixel budget to seconds requires `TimelineGeometry`, which lives with
    /// the view — this type stays free of pixels and AppKit, and the caller
    /// (the view) computes the right threshold for its own current geometry
    /// and hands it in.
    ///
    /// M5f Task 8 is the other half of this comment's own complaint: the
    /// 0.75s/pixel figure above was cited as a bottleneck the first draft of
    /// this milestone never addressed — nothing changed pixels-per-second at
    /// all. `TimelineGeometry.zoomed(by:anchoredAt:)` now lets a person
    /// zoom in until that same pixel is worth a fraction of a second instead
    /// of most of one, and `TimelineView.minimumDragSeconds` recomputes
    /// against the CURRENT zoom (`TimelineGeometry.duration(ofPixels:)`) on
    /// every call — so the threshold this parameter receives shrinks right
    /// along with the view, and a "deliberate short cut" stops being
    /// unplaceable instead of merely being explained.
    public mutating func ended(atTime time: Double, minimumSeconds: Double) -> TimeRange? {
        guard case .dragging(let from) = phase else { return nil }
        phase = .idle
        currentTime = nil
        let range = Self.normalised(from, time)
        let length = range.end - range.start
        // `length > 0` is checked separately from the threshold, not folded
        // into a single `>= minimumSeconds` comparison (M4b whole-branch
        // review, Minor finding #4): a zero-width view's `minimumDragSeconds`
        // clamps to exactly 0, and `0 >= 0` would fire a zero-length
        // selection for every click on such a view if the threshold check
        // alone gated it. A zero-length range is never a deliberate
        // selection, independent of whatever pixel threshold the caller
        // computed.
        guard length > 0, length >= minimumSeconds else { return nil }
        return range
    }

    /// The range the drag would select if it ended now. Available while
    /// `phase` is `.dragging`, so the view can draw the pending selection
    /// before the mouse is released — a preview that only appeared after
    /// `ended` would be a preview of nothing.
    public var previewRange: TimeRange? {
        guard case .dragging(let from) = phase, let current = currentTime else { return nil }
        return Self.normalised(from, current)
    }

    /// Tracks the most recent `moved` position, separate from `phase.from`,
    /// so the origin of the drag and its current point are both retained.
    private var currentTime: Double?

    private static func normalised(_ a: Double, _ b: Double) -> TimeRange {
        a <= b ? TimeRange(start: a, end: b) : TimeRange(start: b, end: a)
    }
}
