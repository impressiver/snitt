import Foundation

public enum AutoTrimError: Error, Equatable {
    /// The recording logged no input events, so there is nothing to trim
    /// against. Refusing is deliberate — see `autoTrimCuts`.
    case noInputEvents
}

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct TrackState: Codable, Sendable {
    public var track: String
    public var muted: Bool
    public var gain: Double

    public init(track: String, muted: Bool = false, gain: Double = 1.0) {
        self.track = track
        self.muted = muted
        self.gain = gain
    }
}

/// The only mutable part of a recording (spec section 7). Editing never
/// touches capture.mov.
public struct EditDecisionList: Codable, Sendable {
    public var schemaVersion: Int
    public var cuts: [TimeRange]
    public var trackStates: [TrackState]

    public init(schemaVersion: Int = 1,
                cuts: [TimeRange] = [],
                trackStates: [TrackState] = []) {
        self.schemaVersion = schemaVersion
        self.cuts = cuts
        self.trackStates = trackStates
    }

    /// The default EDL for a fresh recording: nothing cut, nothing muted.
    public static func fullRange() -> EditDecisionList {
        EditDecisionList(cuts: [], trackStates: [
            TrackState(track: "video"),
            TrackState(track: "microphone"),
            TrackState(track: "systemAudio"),
        ])
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.editURL)
    }

    public static func read(from bundle: SnittBundle) throws -> EditDecisionList {
        try JSONCoding.decoder.decode(
            EditDecisionList.self, from: Data(contentsOf: bundle.editURL)
        )
    }
}

extension EditDecisionList {
    /// Returns a copy that keeps only `range`, cutting the head and tail —
    /// while PRESERVING whatever cuts already existed (D60).
    ///
    /// Before this fix, `cuts` was built `= []` from scratch and `self.cuts`
    /// was never consulted: make an interior cut in the GUI, run `snitt
    /// trim`, and it was gone, permanently, since `capture.mov` is never
    /// rewritten and `edit.json` is the only place a cut lives. §4.8/§6:
    /// the CLI, the MCP server, and the GUI drive one shared model, not two
    /// — a CLI trim that silently deletes a GUI edit is two.
    ///
    /// The fix is to concatenate the new bookends with `self.cuts` and
    /// coalesce overlaps (`Self.merged`, below), which settles every edge
    /// case in one pass with no separate clipping step:
    ///
    ///  - A cut fully INSIDE `[range.start, range.end]` doesn't overlap
    ///    either bookend, so it survives untouched. This is the case the
    ///    bug report names directly, and the one the tests call "the test
    ///    that matters" — not "trim produced two bookend cuts" (true even
    ///    of the broken code on a fresh recording with nothing interior to
    ///    lose), but "a cut someone already made is still there after".
    ///  - A cut STRADDLING a new boundary is effectively CLIPPED to the
    ///    part still inside the kept range: the portion on the far side of
    ///    the boundary is, by construction, a subset of that bookend's
    ///    span (the bookend covers the ENTIRE region outside the kept
    ///    range), so it overlaps the bookend and the two coalesce into one
    ///    cut truncated at the boundary. This is provably identical to an
    ///    explicit clip-then-merge — for any cut C and bookend B,
    ///    `(C ∖ B) ∪ B == C ∪ B` — so plain union-then-merge is enough;
    ///    no separate clipping pass is needed, which is also less code to
    ///    get an off-by-one wrong in. Kept-whole-and-unmerged was rejected
    ///    as a persisted representation: it would store a cut extending
    ///    into territory the bookend already claims, which is redundant
    ///    with, not additional to, what merging already expresses. Dropped
    ///    outright was rejected: it would un-cut the sliver still inside
    ///    the kept range that the person never asked to restore.
    ///  - A cut ENTIRELY OUTSIDE `[range.start, range.end]` is wholly a
    ///    subset of one bookend's span, so it merges completely into that
    ///    bookend and vanishes as a separate entry: it is redundant with
    ///    the bookend, not additional information, and this format has no
    ///    cut identity yet (that's `schemaVersion`-gated M5f/D59 future
    ///    work) for a redundant entry to be worth preserving. Keeping it
    ///    as a second entry would only accumulate across repeated trims.
    ///  - Running `trimmed` again with the SAME range is therefore
    ///    idempotent: the previous call's bookends are themselves now
    ///    entirely outside the (unchanged) kept range, so they merge right
    ///    back into the freshly computed, identical bookends instead of
    ///    piling up as duplicates.
    ///
    /// Track states are carried over untouched: trimming edits time, not audio.
    public func trimmed(keeping range: TimeRange, duration: Double) -> EditDecisionList {
        var cuts: [TimeRange] = []
        if range.start > 0 { cuts.append(TimeRange(start: 0, end: range.start)) }
        if range.end < duration { cuts.append(TimeRange(start: range.end, end: duration)) }
        cuts.append(contentsOf: self.cuts)
        return EditDecisionList(schemaVersion: schemaVersion,
                                cuts: Self.merged(cuts),
                                trackStates: trackStates)
    }

    /// Sorts cuts by start and coalesces any that overlap or touch into a
    /// single entry — the same normalisation `KeptRanges.compute` already
    /// applies when turning cuts into kept ranges for export, applied here
    /// too so a persisted `edit.json` never carries two entries describing
    /// overlapping or merely adjacent seconds. This is what makes repeated
    /// trims idempotent instead of accumulating fragments, and what lets
    /// `trimmed(keeping:duration:)` merge new bookends with preserved cuts
    /// by plain concatenation, with no separate clipping pass.
    private static func merged(_ cuts: [TimeRange]) -> [TimeRange] {
        let sorted = cuts.sorted { $0.start < $1.start }
        var result: [TimeRange] = []
        for cut in sorted {
            if let last = result.last, cut.start <= last.end {
                result[result.count - 1] = TimeRange(start: last.start, end: max(last.end, cut.end))
            } else {
                result.append(cut)
            }
        }
        return result
    }

    /// The `[start, end]` a person keeps by running `--auto-trim`: the padded
    /// span from the first to the last logged INPUT event.
    ///
    /// Throws `noInputEvents` when the log contains none. That refusal is the
    /// point: §8 notes an agent driving an app through a CLI or HTTP produces
    /// no OS-level input at all, so its `events.json` holds only markers. An
    /// event-driven pass would see the whole recording as one gap and delete
    /// it — and an empty export looks like success.
    ///
    /// Markers are excluded deliberately. They are deliberate bookmarks, often
    /// dropped at the very start of a take, and counting them as activity
    /// would defeat head-trimming exactly when it is most useful.
    ///
    /// Factored out of `autoTrimCuts` (below) so `AutomationHost`'s auto-trim
    /// path can hand this range straight to `trimmed(keeping:duration:)`
    /// instead of writing pre-built cuts over `edit.json` directly. That
    /// matters (D60): auto-trim only ever computes new head/tail bookends
    /// from event timestamps — exactly what a manual `--start`/`--end` trim
    /// computes from typed numbers — so it is deliberately NOT a "replace
    /// every cut with these" operation. Routing it through `trimmed` gives it
    /// the identical cuts-preserving merge a manual trim gets; writing
    /// `autoTrimCuts`'s cuts directly, as production code did before this
    /// fix, silently discards any interior cut a person already made (in the
    /// GUI, or via an earlier manual trim) the moment they auto-trim —
    /// the same data-loss bug D60 names for the manual path, on the other
    /// branch of the same `if auto` in `AutomationHost.trim`.
    public static func autoTrimRange(events: [LoggedEvent],
                                     duration: Double,
                                     padding: Double = 0.5) throws -> TimeRange {
        let inputTimes = events.filter { $0.kind != .marker }.map(\.timeSeconds).sorted()
        guard let first = inputTimes.first, let last = inputTimes.last else {
            throw AutoTrimError.noInputEvents
        }
        let head = max(0, first - padding)
        let tail = min(duration, last + padding)
        return TimeRange(start: head, end: tail)
    }

    /// The raw bookend cuts `autoTrimRange` implies, with no merge against
    /// any existing cuts. Kept for callers (and tests) that want the pure
    /// head/tail computation in isolation; production auto-trim does NOT
    /// call this directly — see `autoTrimRange`'s doc comment above for why
    /// — it goes through `trimmed(keeping:duration:)` instead so existing
    /// cuts survive.
    public static func autoTrimCuts(events: [LoggedEvent],
                                    duration: Double,
                                    padding: Double = 0.5) throws -> [TimeRange] {
        let range = try autoTrimRange(events: events, duration: duration, padding: padding)
        var cuts: [TimeRange] = []
        if range.start > 0 { cuts.append(TimeRange(start: 0, end: range.start)) }
        if range.end < duration { cuts.append(TimeRange(start: range.end, end: duration)) }
        return cuts
    }
}
