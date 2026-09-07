import Foundation

/// Maps between timeline pixels and the EXPORTED (output) timeline's own
/// seconds.
///
/// Pure and in `SnittDocument` deliberately: this is the arithmetic every
/// timeline interaction depends on, and the only part of the timeline
/// testable without a window or a mouse. The `NSView` draws and forwards
/// events; the rules live here.
///
/// D56's first requirement: a cut must SHORTEN the timeline, not leave it
/// the same length with a red patch drawn inside it. Before this type
/// wrapped `Timebase` (M5f Task 3), it was constructed with `capture.mov`'s
/// own SOURCE duration — a cut removed seconds from the export but the
/// timeline kept drawing the full, untrimmed span, because nothing here
/// distinguished the two. `duration` below is `Timebase.outputDuration` for
/// exactly that reason, and the mapping functions are typed on `OutputTime`
/// and `SourceTime` (Task 1) rather than a bare `Double` so a caller cannot
/// feed the wrong clock in without a compiler error — the confusion this
/// type itself used to be built on.
///
/// `width` stays its own stored value rather than folding into a combined
/// scale-and-offset, and `x(atOutput:)` is the one place a time becomes a
/// pixel: Task 8's zoom adds a scale factor (`pixelsPerSecond`) and a scroll
/// offset (`visibleOffset`) to this type, right here rather than spread
/// across every caller — see `zoomed(by:anchoredAt:)`.
public struct TimelineGeometry: Equatable, Sendable {
    public let width: Double
    /// The trimmed timeline's own length — what will actually export, not
    /// `capture.mov`'s. See the type's doc comment.
    public let duration: Double
    /// Pixels per OUTPUT second at the current zoom. `width / duration` at
    /// the default (unzoomed) level — `init(width:timebase:)` always starts
    /// there — and multiplied by `zoomed(by:anchoredAt:)`'s factor from then
    /// on. Stored rather than always recomputed from `width`/`duration`
    /// because after a zoom it no longer equals that ratio: the whole point
    /// of zooming in is packing MORE pixels into the same second than a
    /// plain `width / duration` fit-to-view would give it.
    public let pixelsPerSecond: Double
    /// The OUTPUT second currently drawn at pixel 0 — zero until
    /// `zoomed(by:anchoredAt:)` moves it. At the default zoom the whole
    /// `0...duration` span fits in `width`, so there is nothing to scroll to
    /// and this stays zero; once `pixelsPerSecond` grows past that fit, the
    /// timeline is wider than the view and this is how much of it has
    /// scrolled out of view on the left.
    public let visibleOffset: Double
    private let timebase: Timebase

    public init(width: Double, timebase: Timebase) {
        self.width = width
        self.timebase = timebase
        self.duration = timebase.outputDuration
        self.pixelsPerSecond = (width > 0 && self.duration > 0) ? width / self.duration : 0
        self.visibleOffset = 0
    }

    private init(width: Double, duration: Double, timebase: Timebase,
                pixelsPerSecond: Double, visibleOffset: Double) {
        self.width = width
        self.duration = duration
        self.timebase = timebase
        self.pixelsPerSecond = pixelsPerSecond
        self.visibleOffset = visibleOffset
    }

    /// Manual, not synthesized: `Timebase` isn't `Equatable` (it wraps an
    /// `EditDecisionList`, which carries no such conformance), so this
    /// compares the same fields the pre-`Timebase` version of this type had
    /// and synthesized `==` over, plus the two Task 8 added — two geometries
    /// at different zoom levels or scroll positions are not the same
    /// geometry even when `width`/`duration` agree.
    public static func == (lhs: TimelineGeometry, rhs: TimelineGeometry) -> Bool {
        lhs.width == rhs.width && lhs.duration == rhs.duration
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond && lhs.visibleOffset == rhs.visibleOffset
    }

    /// Zero width or zero duration would divide to NaN, and a NaN reaching a
    /// drawing call is silent garbage on screen rather than a crash. A view
    /// is laid out at zero width before its first real layout pass, so this
    /// is reachable on every launch, not a theoretical edge. Zero duration
    /// now also covers "everything was cut" (`Timebase.outputDuration == 0`),
    /// not just a zero-length recording.
    private var isDegenerate: Bool { width <= 0 || duration <= 0 }

    /// `x(atOutput:)` without the final clamp to `0...width` — the raw
    /// position `time` sits at, which can legitimately fall outside the
    /// current viewport once zoomed in and scrolled. `zoomed(by:anchoredAt:)`
    /// needs this unclamped value for its anchor math: clamping first would
    /// silently relocate an anchor that is currently scrolled off-screen to
    /// whichever edge it clamped to, and the NEXT zoom step would then pivot
    /// around that wrong edge instead of the real anchor.
    private func rawX(atOutput time: OutputTime) -> Double {
        (time.seconds - visibleOffset) * pixelsPerSecond
    }

    /// Maps an OUTPUT-timeline instant to a pixel, clamped to `0...width` —
    /// an out-of-viewport instant (scrolled off either edge, or simply past
    /// `0...duration`) piles up at whichever edge it is nearest, rather than
    /// extrapolating or reporting a position nothing is actually drawn at.
    public func x(atOutput time: OutputTime) -> Double {
        guard !isDegenerate else { return 0 }
        return min(max(rawX(atOutput: time), 0), width)
    }

    /// Maps a SOURCE-recording instant to a pixel, or `nil` if it falls
    /// inside a cut. A cut span is not part of the export — it has no pixel
    /// to invent, so this says so rather than returning 0, the cut's own
    /// edge, or crashing, any of which a caller could mistake for a real
    /// position that happens to sit there.
    public func x(atSource time: SourceTime) -> Double? {
        guard let output = timebase.outputTime(forSource: time) else { return nil }
        return x(atOutput: output)
    }

    /// The inverse of `x(atOutput:)`: the OUTPUT instant a pixel sits over,
    /// clamped to `0...duration`. Deliberately stops at output time rather
    /// than also reversing into source time — a caller that needs a
    /// `SourceTime` back (to build a `TimeRange` for `edl.cuts`, say) asks
    /// `Timebase.sourceTime(forOutput:)` for that itself; folding it in here
    /// would hide which of two very different clocks a pixel query answers
    /// in.
    public func outputTime(atX x: Double) -> OutputTime {
        guard !isDegenerate, pixelsPerSecond > 0 else { return OutputTime(0) }
        return OutputTime(min(max(visibleOffset + x / pixelsPerSecond, 0), duration))
    }

    /// The number of OUTPUT seconds `pixels` pixels span at the CURRENT
    /// zoom — `TrimGesture.ended`'s own stated problem turned into a query:
    /// "how many seconds is one pixel right now", so a caller (`TimelineView`'s
    /// `minimumDragSeconds`) can shrink its click-vs-drag threshold as the
    /// view zooms in, instead of carrying a fixed-at-1x seconds budget that
    /// stays coarse no matter how far in a person has zoomed. Zero when
    /// degenerate — there is no scale to convert against.
    public func duration(ofPixels pixels: Double) -> Double {
        guard pixelsPerSecond > 0 else { return 0 }
        return pixels / pixelsPerSecond
    }

    /// Returns a geometry scaled by `factor` around `anchor` — the OUTPUT
    /// instant that must land at the SAME pixel after the zoom as before it.
    /// Task 8's whole point: a zoom that recentres the timeline under the
    /// user instead of holding still under their cursor or playhead is what
    /// makes a timeline feel like it is "fighting" whoever is dragging it.
    ///
    /// `factor` is RELATIVE to this geometry's own current
    /// `pixelsPerSecond`, not absolute — repeated small zoom steps (a scroll
    /// wheel firing many small events) compose correctly by just chaining
    /// calls, rather than each one needing to know the cumulative zoom
    /// level to reproduce.
    ///
    /// A degenerate geometry, or a non-positive factor, has no scale worth
    /// multiplying — returns `self` unchanged rather than manufacturing a
    /// NaN or negative `pixelsPerSecond`. One guard covers both: a
    /// non-degenerate geometry's own `pixelsPerSecond` is always strictly
    /// positive (see `init`), so `factor <= 0` already drives
    /// `newPixelsPerSecond <= 0` without a separate check for it.
    public func zoomed(by factor: Double, anchoredAt anchor: OutputTime) -> TimelineGeometry {
        guard !isDegenerate else { return self }
        let newPixelsPerSecond = pixelsPerSecond * factor
        guard newPixelsPerSecond > 0 else { return self }
        // Solve for the offset that keeps `anchor` at the pixel it already
        // sits at (`rawX`, UNCLAMPED — see that method's own doc comment):
        // `(anchor - newOffset) * newPixelsPerSecond == anchorX`.
        let anchorX = rawX(atOutput: anchor)
        let rawOffset = anchor.seconds - anchorX / newPixelsPerSecond
        // Once the whole (zoomed) timeline is narrower than the view, there
        // is nothing to scroll to — clamp to 0 rather than let the anchor
        // solve for a negative offset that would leave empty space before
        // the timeline's own start.
        let maxOffset = max(0, duration - width / newPixelsPerSecond)
        let newOffset = min(max(rawOffset, 0), maxOffset)
        return TimelineGeometry(width: width, duration: duration, timebase: timebase,
                                pixelsPerSecond: newPixelsPerSecond, visibleOffset: newOffset)
    }

    /// The pixel position where `cut`'s own two edges meet once folded —
    /// wraps `Timebase.foldPosition(for:)` exactly as `x(atSource:)` wraps
    /// `outputTime(forSource:)` (M5f Task 5). Unlike `x(atSource:)`, this
    /// never has a `nil` case: neither of a cut's own edges has an output
    /// position by itself (that absence is what makes it a cut), but the
    /// SINGLE point they collapse onto together always does, as long as
    /// there is an output timeline at all to place it on.
    public func x(atFold cut: Cut) -> Double {
        guard !isDegenerate else { return 0 }
        return x(atOutput: timebase.foldPosition(for: cut))
    }
}
