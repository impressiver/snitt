import Foundation

/// A position in `capture.mov`, the pristine source recording.
///
/// Deliberately NOT interchangeable with `OutputTime`: the two describe
/// different clocks, and M4b shipped a defect (a trim silently doing
/// nothing on the second attempt) that traced back to exactly this
/// confusion — a timeline fed output-time durations into code that consumed
/// source-time cuts. `SourceTime` and `OutputTime` share no protocol with a
/// `.seconds` both satisfy, so nothing lets one stand in for the other; the
/// type checker rejects the mistake instead of a reviewer having to catch it.
public struct SourceTime: Equatable, Hashable, Comparable, Sendable {
    public let seconds: Double

    public init(_ seconds: Double) {
        self.seconds = seconds
    }

    public static func < (lhs: SourceTime, rhs: SourceTime) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

/// A position in the exported/previewed (trimmed) timeline — the composition
/// `CompositionBuilder` builds from an EDL, with every cut span removed.
///
/// See `SourceTime`'s doc comment for why this is a distinct type rather
/// than a shared representation.
public struct OutputTime: Equatable, Hashable, Comparable, Sendable {
    public let seconds: Double

    public init(_ seconds: Double) {
        self.seconds = seconds
    }

    public static func < (lhs: OutputTime, rhs: OutputTime) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

/// Converts between `SourceTime` (a position in `capture.mov`) and
/// `OutputTime` (a position in the trimmed composition/export) for one EDL.
///
/// This wraps `KeptRanges.compute` (the source→kept-ranges arithmetic) and
/// `TimeRangeMapping`'s two containment-based conversions
/// (`trimmedTime(of:keptRanges:)` and `sourceTime(ofTrimmedTime:keptRanges:)`)
/// rather than reimplementing either — both already carry the off-by-one and
/// boundary handling this would otherwise have to get right a second time.
/// `Timebase` only adds the typed, EDL-shaped entry point and the
/// `outputDuration` these lower-level functions don't compute for you.
public struct Timebase: Sendable {
    /// The ONLY state this type carries. `sourceDuration` and `edl` were
    /// stored alongside it as public properties and read by nothing in
    /// `Sources/` or `Tests/` (M5f whole-branch review, F8) — dead public
    /// surface on the type this milestone introduced to BE the clock
    /// boundary, and an invitation to reach past the conversions for the
    /// raw inputs. They are constructor parameters now, nothing more; a
    /// caller that needs the source duration or the EDL already has them,
    /// since it is the one that passed them in.
    private let keptRanges: [TimeRange]

    public init(sourceDuration: Double, edl: EditDecisionList) {
        self.keptRanges = KeptRanges.compute(duration: sourceDuration, cuts: edl.cuts.map(\.range))
    }

    /// The trimmed timeline's total length: the source duration minus every
    /// cut. Zero when everything has been cut away.
    public var outputDuration: Double {
        keptRanges.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// Maps a source-recording instant into the output timeline, or `nil`
    /// if it falls inside a cut — a cut span has no position in the output
    /// at all, so returning 0, the cut's start, or crashing would each
    /// invent an answer that isn't there. Matches
    /// `TimeRangeMapping.trimmedTime(of:keptRanges:)`'s boundary rule.
    public func outputTime(forSource source: SourceTime) -> OutputTime? {
        guard let trimmed = TimeRangeMapping.trimmedTime(
            of: source.seconds, keptRanges: keptRanges
        ) else {
            return nil
        }
        return OutputTime(trimmed)
    }

    /// The inverse of `outputTime(forSource:)`: maps an output-timeline
    /// instant back to its source-recording position.
    ///
    /// Unlike the forward direction, this can't land in a cut — the output
    /// timeline has no cuts in it by construction — so `nil` here only means
    /// `output` itself was out of range (negative, past `outputDuration`, or
    /// there is no output at all because everything was cut). Matches
    /// `TimeRangeMapping.sourceTime(ofTrimmedTime:keptRanges:)`'s boundary
    /// rule, which is this function's entire implementation.
    public func sourceTime(forOutput output: OutputTime) -> SourceTime? {
        guard let source = TimeRangeMapping.sourceTime(
            ofTrimmedTime: output.seconds, keptRanges: keptRanges
        ) else {
            return nil
        }
        return SourceTime(source)
    }

    /// The OUTPUT instant `cut`'s removed span collapses onto once folded —
    /// the position `TimelineView` draws a fold's line at (M5f Task 5: "a cut
    /// collapses to a red line with its two edges touching").
    ///
    /// Every source instant inside `cut` — including both of its own
    /// endpoints — maps to this SAME output instant: `outputTime(forSource:)`
    /// returns `nil` for all of them (a cut has no position of its own in the
    /// output, which is exactly what makes it a cut), but the single point
    /// immediately after everything kept before it and immediately before
    /// everything kept after it is well-defined regardless. That point is
    /// exactly what `TimeRangeMapping.nearestTrimmedTime` already computes
    /// for any source instant that falls inside a gap between kept ranges —
    /// this reuses it rather than re-deriving the same cumulative-kept-
    /// duration walk a second time. `cut.range.start` always falls inside
    /// such a gap by construction (a `Cut`'s own range IS a gap, or is
    /// entirely contained within a larger one after merging with an
    /// overlapping neighbour), so the only way `nearestTrimmedTime` returns
    /// `nil` here is `keptRanges` itself being empty — everything cut,
    /// nothing kept, nowhere on the (empty) output axis for anything to fold
    /// onto — where 0 is as good an answer as any other, since there is no
    /// timeline left to be wrong on.
    ///
    /// ORDER DEPENDENCE, recorded here rather than only in the plan's ledger
    /// (M5f whole-branch review, F7): `nearestTrimmedTime` walks
    /// `keptRanges` in ARRAY order accumulating output seconds, and is
    /// correct only while that order is ascending TIME order. The refinement
    /// pass for slice/reorder (Tier 2) named it as the one function that
    /// genuinely breaks under a reordered timeline, and this is now its
    /// SECOND consumer — every fold's drawn position, and every fold's
    /// hit-test, resolve through it. Whoever lands reorder must revisit
    /// `nearestTrimmedTime` itself; reading only this call site will not
    /// show the assumption.
    public func foldPosition(for cut: Cut) -> OutputTime {
        let trimmed = TimeRangeMapping.nearestTrimmedTime(
            toSourceTime: cut.range.start, keptRanges: keptRanges) ?? 0
        return OutputTime(trimmed)
    }
}
