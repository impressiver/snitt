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
/// pixel: Task 8's zoom adds a scale factor and a scroll offset to this
/// type, and both belong right there, not spread across every caller.
public struct TimelineGeometry: Equatable, Sendable {
    public let width: Double
    /// The trimmed timeline's own length — what will actually export, not
    /// `capture.mov`'s. See the type's doc comment.
    public let duration: Double
    private let timebase: Timebase

    public init(width: Double, timebase: Timebase) {
        self.width = width
        self.timebase = timebase
        self.duration = timebase.outputDuration
    }

    /// Manual, not synthesized: `Timebase` isn't `Equatable` (it wraps an
    /// `EditDecisionList`, which carries no such conformance), so this
    /// compares the same two fields the pre-`Timebase` version of this type
    /// had and synthesized `==` over.
    public static func == (lhs: TimelineGeometry, rhs: TimelineGeometry) -> Bool {
        lhs.width == rhs.width && lhs.duration == rhs.duration
    }

    /// Zero width or zero duration would divide to NaN, and a NaN reaching a
    /// drawing call is silent garbage on screen rather than a crash. A view
    /// is laid out at zero width before its first real layout pass, so this
    /// is reachable on every launch, not a theoretical edge. Zero duration
    /// now also covers "everything was cut" (`Timebase.outputDuration == 0`),
    /// not just a zero-length recording.
    private var isDegenerate: Bool { width <= 0 || duration <= 0 }

    /// Maps an OUTPUT-timeline instant to a pixel. Every instant in
    /// `0...duration` has a position — the output timeline has no gaps in it
    /// by construction, `Timebase`'s kept ranges tile it edge to edge — so
    /// this never needs to return `nil`; an out-of-range input clamps rather
    /// than extrapolating, matching every other clamp in this type.
    public func x(atOutput time: OutputTime) -> Double {
        guard !isDegenerate else { return 0 }
        return min(max(time.seconds / duration * width, 0), width)
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
        guard !isDegenerate else { return OutputTime(0) }
        return OutputTime(min(max(x / width * duration, 0), duration))
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
