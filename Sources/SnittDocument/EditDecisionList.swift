// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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

/// A single removed span, addressable by `id` — the handle "right-click this
/// cut and remove it" (Task 5's fold UI) needs. `TimeRange` alone is
/// `{start, end}`: two cuts of the same length at the same place are
/// value-equal and therefore indistinguishable, and nothing names "this one"
/// rather than "that one" for deletion.
///
/// v0.1.0 wrote plain `{start, end}` cuts with no identity at all — see
/// `Tests/Fixtures/edit-v0.1.0.json`, captured from that shipping encoder
/// before this type existed. `Cut.init(from:)` mints a fresh `UUID` for any
/// cut decoded without one, so a bundle recorded before this milestone still
/// opens instead of failing to parse or silently losing its cuts.
public struct Cut: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var range: TimeRange
    /// What this fold removed, in words — "waiting for build — 4m 12s".
    ///
    /// A fold is a hole in the recording, and a hole says nothing about what
    /// used to be in it. Without this, an automatic trim leaves a timeline of
    /// anonymous gaps that a viewer has to expand one at a time to understand.
    /// `nil` for a cut somebody made by hand: they know what they removed, and
    /// inventing a description of their own edit would be putting words in
    /// their mouth.
    public var label: String?

    /// `id` defaults to a fresh `UUID()` PER CALL (not a shared static
    /// default) — two `Cut(range:)` calls with identical ranges must not
    /// collide, or removing one fold would remove both.
    public init(id: UUID = UUID(), range: TimeRange, label: String? = nil) {
        self.id = id
        self.range = range
        self.label = label
    }
}

extension Cut: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, start, end, label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Double.self, forKey: .start)
        let end = try container.decode(Double.self, forKey: .end)
        // Legacy (pre-M5f) cuts carry no `id` key at all — mint one rather
        // than failing to decode, so a v0.1.0 edit.json still opens.
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // Absent on every cut written before folds carried words, and on every
        // hand-made cut since — the same `decodeIfPresent` treatment `id` gets,
        // for the same reason.
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        self.init(id: id, range: TimeRange(start: start, end: end), label: label)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(range.start, forKey: .start)
        try container.encode(range.end, forKey: .end)
        // `encodeIfPresent`, so an unlabelled cut writes no key at all rather
        // than a null — an edit.json full of `"label": null` is noise in the
        // one file a person might read by hand.
        try container.encodeIfPresent(label, forKey: .label)
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

/// Thrown by `EditDecisionList` decoding.
///
/// D60: `edit.json` is the only place an edit lives, and updates are
/// hand-delivered (D54) — an old and a new Snitt build can coexist on one
/// machine, each capable of opening the same bundle. Without this refusal,
/// an old build's `Codable` conformance would decode a newer file's
/// unfamiliar shape into whatever it happens to understand and silently
/// drop the rest, and the very next autosave would write that impoverished
/// value back over the original — permanently destroying the edit, with
/// `capture.mov` untouched and no error anywhere. A loud refusal here is
/// the alternative to that silent, unrecoverable loss.
public enum EditDecisionListError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, maxSupported: Int)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, maxSupported):
            return "This edit.json declares schemaVersion \(found), but this build of "
                 + "Snitt only understands up to \(maxSupported). Refusing to open it: "
                 + "a partial read would silently drop what this build can't represent, "
                 + "and the next save would make that loss permanent. Update Snitt to "
                 + "open this recording."
        }
    }
}

/// A crop, expressed in fractions of the source's natural size (0...1), with
/// the origin at the **top-left** of the displayed image.
///
/// Normalized rather than in pixels so it survives a change of source
/// resolution and composes with `--scale` without either needing to know about
/// the other: the render size is (crop × natural × scale), and those two
/// multipliers commute.
///
/// Non-destructive per §4.5 — this lives in `edit.json` and `capture.mov` is
/// never touched, so a crop is as reversible as a cut.
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// Clamps into the unit square. A crop is a view onto the source, so a
    /// rect reaching past the edge means the caller wanted the edge — the
    /// alternative is either a throw at every construction site or a render
    /// size larger than the frame, filled with nothing.
    public init(x: Double, y: Double, width: Double, height: Double) {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        self.x = clampedX
        self.y = clampedY
        self.width = min(max(width, 0), 1 - clampedX)
        self.height = min(max(height, 0), 1 - clampedY)
    }

    public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    /// Applies `sub` — a crop expressed in the coordinates of what THIS crop
    /// already shows — and returns the equivalent crop of the original source.
    ///
    /// Needed because the editor previews the cropped frame: a second drag is
    /// against the visible picture, not against `capture.mov`. Storing that
    /// drag directly would silently re-anchor the crop to the wrong origin,
    /// and the error compounds with every further adjustment.
    public func composing(_ sub: CropRect) -> CropRect {
        CropRect(x: x + sub.x * width,
                 y: y + sub.y * height,
                 width: sub.width * width,
                 height: sub.height * height)
    }

    /// A crop that removes nothing renders identically to no crop, so callers
    /// can skip the whole transform rather than multiplying by one.
    public var isFullFrame: Bool { x == 0 && y == 0 && width == 1 && height == 1 }

    /// A zero-area crop would produce a zero-size render — a file with no
    /// picture in it. Callers treat this the way they treat `isFullFrame`:
    /// as "do not apply this".
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// The only mutable part of a recording (spec section 7). Editing never
/// touches capture.mov.
public struct EditDecisionList: Codable, Sendable {
    /// Bumped 1 -> 2 by M5f Task 2: cuts gained `id`. Still readable from a
    /// bare `{start, end}` — schemaVersion 1's shape — via `Cut.init(from:)`
    /// minting an id; a version ABOVE this one is refused outright rather
    /// than partially decoded (D60, `EditDecisionListError`).
    /// Bumped 2 -> 3 by the crop work. This one is NOT additive in the way
    /// `Cut.id` was: an older build decodes an `edit.json` it can read,
    /// silently ignores a `crop` key it has no field for, and the next
    /// autosave writes back a cropless EDL — destroying the crop with
    /// `capture.mov` untouched and no error anywhere. That is precisely the
    /// "next non-additive change" `encode(to:)`'s comment predicts below, so
    /// the version gate has to fire for it.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var cuts: [Cut]
    public var trackStates: [TrackState]
    /// `nil` means "no crop", which is distinct from `.full` only in what gets
    /// written to disk — both render the whole frame.
    public var crop: CropRect?
    /// Whether click rings are drawn — in the editor's playback, and therefore
    /// as the export's default.
    ///
    /// Lives with the edit rather than in a preference because it is a property
    /// of THIS recording: a screen-capture demo wants its clicks shown, and a
    /// recording of someone's face does not, and the answer should travel with
    /// the bundle instead of being whatever the app was last set to.
    ///
    /// **Deliberately does NOT bump `currentSchemaVersion`.** The gate exists
    /// to stop an older build silently destroying work, which is why `crop`
    /// bumped it — losing a crop loses an edit that cannot be recovered from
    /// `capture.mov`. Losing this loses a checkbox. Bumping would make every
    /// older build REFUSE the document outright, which costs far more than the
    /// thing it protects; the honest trade is that an old build round-tripping
    /// a bundle resets this flag to false.
    public var showClicks: Bool
    /// Whether captions from the transcript are drawn — in playback, and
    /// therefore as the export's default. Same reasoning as `showClicks`, and
    /// the same additive, no-version-bump treatment.
    public var showSubtitles: Bool
    /// Whether marker banners are drawn.
    public var showMarkers: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cuts, trackStates, crop, showClicks
        case showSubtitles, showMarkers
    }

    public init(schemaVersion: Int = EditDecisionList.currentSchemaVersion,
                cuts: [Cut] = [],
                trackStates: [TrackState] = [],
                crop: CropRect? = nil,
                showClicks: Bool = false,
                showSubtitles: Bool = false,
                showMarkers: Bool = false) {
        self.schemaVersion = schemaVersion
        self.cuts = cuts
        self.trackStates = trackStates
        self.crop = crop
        self.showClicks = showClicks
        self.showSubtitles = showSubtitles
        self.showMarkers = showMarkers
    }

    /// Custom rather than synthesized so `schemaVersion` can be checked
    /// BEFORE `cuts`/`trackStates` are decoded at all (D60). Letting
    /// `Codable`'s default synthesis run to completion on a too-new file
    /// would decode whatever fields it recognizes and quietly ignore the
    /// rest — a partial, wrong-looking success, not the loud refusal this
    /// format needs.
    ///
    /// The decoded value is PRESERVED here rather than normalised, so
    /// `schemaVersion` still reports what the file on disk actually said —
    /// `encode(to:)` is where the stamp belongs, and it stamps
    /// unconditionally.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw EditDecisionListError.unsupportedSchemaVersion(
                found: schemaVersion, maxSupported: Self.currentSchemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.cuts = try container.decode([Cut].self, forKey: .cuts)
        self.trackStates = try container.decode([TrackState].self, forKey: .trackStates)
        // decodeIfPresent, not decode: every bundle written before this field
        // existed has no `crop` key, and those must keep opening.
        self.crop = try container.decodeIfPresent(CropRect.self, forKey: .crop)
        // Same reason as `crop`: every bundle written before this field
        // existed has no key, and those must keep opening — defaulted off
        // rather than refused.
        self.showClicks = try container.decodeIfPresent(Bool.self, forKey: .showClicks) ?? false
        self.showSubtitles = try container.decodeIfPresent(Bool.self, forKey: .showSubtitles) ?? false
        self.showMarkers = try container.decodeIfPresent(Bool.self, forKey: .showMarkers) ?? false
    }

    /// Custom rather than synthesized so a WRITE always declares the version
    /// this build actually writes, whatever version the value was read as
    /// (M5f whole-branch review, F4).
    ///
    /// Synthesis wrote `self.schemaVersion` back, and `init(from:)`
    /// preserves the decoded value — so a v0.1.0 bundle opened, edited and
    /// saved by this build kept declaring `schemaVersion: 1` while carrying
    /// schema-2, `id`-bearing cuts. D60's gate compares declared versions,
    /// so it never fired for any bundle that actually exists: an older build
    /// read the file without refusal, and the loud refusal this format needs
    /// was decorative for every real case.
    ///
    /// It was harmless only by accident. `Cut`'s encoding happens to be flat
    /// and additive (`{id, start, end}`), so a v0.1.0 `TimeRange` decoder
    /// ignores the extra key; the next non-additive change to this file
    /// turns the same situation into exactly the silent, unrecoverable loss
    /// `EditDecisionListError`'s own message promises to prevent. Stamping
    /// on encode — rather than at `write(to:)` — covers every caller that
    /// encodes an EDL, `snitt trim`'s write path included.
    ///
    /// `events.json` never had the problem, and not deliberately:
    /// `PreviewController.persistEvents` builds a fresh `EventLog(events:)`
    /// whose defaulted `schemaVersion` is `currentSchemaVersion`, so a
    /// legacy log is upgraded 1 -> 2 on write as a side effect of how it is
    /// constructed. This makes the two files agree on purpose.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(cuts, forKey: .cuts)
        try container.encode(trackStates, forKey: .trackStates)
        // encodeIfPresent: an uncropped EDL writes no `crop` key at all, so a
        // file's shape still tells you whether a crop was ever set.
        try container.encodeIfPresent(crop, forKey: .crop)
        // Written only when ON, so a file's shape still says whether anyone
        // ever asked for rings — and a bundle from before this field keeps
        // round-tripping byte-identical while the flag is off.
        if showClicks { try container.encode(true, forKey: .showClicks) }
        if showSubtitles { try container.encode(true, forKey: .showSubtitles) }
        if showMarkers { try container.encode(true, forKey: .showMarkers) }
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
        try decode(from: Data(contentsOf: bundle.editURL))
    }

    /// Decodes a standalone `edit.json` payload through the same
    /// `schemaVersion`-gated `init(from:)` `read(from:)` uses, for callers
    /// (and tests) that already have the bytes rather than a bundle.
    public static func decode(from data: Data) throws -> EditDecisionList {
        try JSONCoding.decoder.decode(EditDecisionList.self, from: data)
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
    ///    either bookend, so it survives untouched — id included, since it
    ///    forms a group of one in `merged` and nothing recomputes it.
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
    ///    the kept range that the person never asked to restore. The
    ///    merged entry keeps the PRE-EXISTING cut's id, not the bookend's
    ///    freshly minted one — see `merged`'s doc comment.
    ///  - A cut ENTIRELY OUTSIDE `[range.start, range.end]` is wholly a
    ///    subset of one bookend's span, so it merges completely into that
    ///    bookend and vanishes as a separate array ENTRY: it is redundant
    ///    with the bookend, not additional information. Keeping it as a
    ///    second entry would only accumulate across repeated trims. Its id
    ///    is not lost outright, though — `merged` still prefers it over the
    ///    bookend's for the single surviving entry, on the same reasoning
    ///    as the straddling case above.
    ///  - Running `trimmed` again with the SAME range is therefore
    ///    idempotent: the previous call's bookends are themselves now
    ///    entirely outside the (unchanged) kept range, so they merge right
    ///    back into the freshly computed, identical bookends instead of
    ///    piling up as duplicates.
    ///
    /// Track states are carried over untouched: trimming edits time, not audio.
    public func trimmed(keeping range: TimeRange, duration: Double) -> EditDecisionList {
        var candidates: [(cut: Cut, isBookend: Bool)] = []
        if range.start > 0 {
            candidates.append((Cut(range: TimeRange(start: 0, end: range.start)), true))
        }
        if range.end < duration {
            candidates.append((Cut(range: TimeRange(start: range.end, end: duration)), true))
        }
        candidates.append(contentsOf: cuts.map { ($0, false) })
        return EditDecisionList(schemaVersion: schemaVersion,
                                cuts: Self.merged(candidates),
                                trackStates: trackStates,
                                // Carried, not dropped. D60 is exactly this
                                // defect one field earlier: `trimmed` rebuilt
                                // the EDL from scratch, so `snitt trim` silently
                                // destroyed cuts the GUI had made. A rebuild
                                // that forgets a field is the same bug whatever
                                // the field is, and §4.8 holds that the CLI and
                                // GUI are one model rather than two.
                                crop: crop)
    }

    /// Sorts cuts by start and coalesces any that overlap or touch into a
    /// single entry — the same normalisation `KeptRanges.compute` already
    /// applies when turning cuts into kept ranges for export, applied here
    /// too so a persisted `edit.json` never carries two entries describing
    /// overlapping or merely adjacent seconds. This is what makes repeated
    /// trims idempotent instead of accumulating fragments, and what lets
    /// `trimmed(keeping:duration:)` merge new bookends with preserved cuts
    /// by plain concatenation, with no separate clipping pass.
    ///
    /// Identity through a merge (M5f Task 2, once cuts had ids worth
    /// preserving): a coalesced group keeps the id of whichever INPUT cut
    /// already existed before this trim (`isBookend == false`) — never a
    /// bookend's freshly minted one. A straddling cut that gets clipped and
    /// absorbed into a bookend is, from the fold UI's perspective, the SAME
    /// edit someone already made, now extended to cover a bit more, not a
    /// new one that happens to occupy the old one's seconds; an entirely
    /// pre-existing cut merging into a bookend (the "outside" case above)
    /// gets the same treatment even though it no longer has its own array
    /// entry. Only a group made ENTIRELY of bookends (both bookends
    /// colliding with each other and nothing pre-existing between them — an
    /// edge case no test here reaches with a positive `duration`) falls
    /// back to a bookend's id. Two pre-existing cuts merging into each
    /// other — not reachable through `trimmed` today, since every call
    /// merges already-`merged`, non-overlapping `self.cuts` against fresh
    /// bookends — would deterministically keep the earliest-starting one's
    /// id, a policy chosen for its determinism rather than exercised.
    private static func merged(_ candidates: [(cut: Cut, isBookend: Bool)]) -> [Cut] {
        let sorted = candidates.sorted { $0.cut.range.start < $1.cut.range.start }
        var groups: [[(cut: Cut, isBookend: Bool)]] = []
        for candidate in sorted {
            if let runningEnd = groups.last?.map({ $0.cut.range.end }).max(),
               candidate.cut.range.start <= runningEnd {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        return groups.map { group in
            let start = group.map(\.cut.range.start).min()!
            let end = group.map(\.cut.range.end).max()!
            let id = group.first(where: { !$0.isBookend })?.cut.id ?? group[0].cut.id
            return Cut(id: id, range: TimeRange(start: start, end: end))
        }
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
        // Reported input counts. D44 and D49 both note that agent recordings
        // log no OS input, which is why auto-trim refused them — an agent that
        // now reports its own clicks has given exactly the signal that refusal
        // was missing, and trimming to it is the point of reporting.
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
