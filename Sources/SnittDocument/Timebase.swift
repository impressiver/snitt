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
    public var seconds: Double

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
    public var seconds: Double

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
    /// The source recording's own duration (`capture.mov`'s), before cuts.
    public let sourceDuration: Double
    public let edl: EditDecisionList
    private let keptRanges: [TimeRange]

    public init(sourceDuration: Double, edl: EditDecisionList) {
        self.sourceDuration = sourceDuration
        self.edl = edl
        self.keptRanges = KeptRanges.compute(duration: sourceDuration, cuts: edl.cuts)
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
}
