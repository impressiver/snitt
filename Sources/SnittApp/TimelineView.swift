import AppKit
import SnittDocument
import SnittExport

/// The scrubbable, trimmable timeline beneath the editor's video surface.
///
/// Holds no rules of its own. `TrimGesture` (SnittDocument) answers every
/// "is this a click or a deliberate drag" question; this view's only job is
/// to convert an `NSEvent`'s location to a time, feed it to `gesture`, and
/// call out through `onScrub`/`onSelect`. §4.7 puts gesture handling in
/// AppKit — not because AppKit is where the rules belong, but because
/// keeping the untestable part (drawing, event plumbing) as small as
/// possible is the only defence available for code no test can see.
///
/// D56 (M5f Task 4): a drag SELECTS; it never touches the EDL. `onSelect`
/// reports the drag's result (a `Selection`, or `nil` for a plain click) to
/// the owner, which decides separately, and later, whether to cut it —
/// see `EditorTimelineState.cutSelection()`. Before this task `onTrim`
/// applied a cut the instant a drag ended, which is the defect D56 exists
/// to fix.
///
/// `TimelineGeometry` (SnittDocument) answers pixel-to-time, on the OUTPUT
/// axis, per D56 (M5f Task 3) — for DRAWING **and for GESTURES**. There is
/// exactly one geometry here and interaction is interpreted on the axis
/// being drawn; see `time(for:)`'s doc comment for the rule and for the
/// pair of Critical findings that established it.
///
/// M5f Task 8: the first draft of this milestone shipped nothing that
/// changed pixels-per-second — `TrimGesture.ended`'s own doc comment names
/// the resulting bottleneck ("a ten-minute recording at 800px is
/// ~0.75s/pixel"). `zoomFactor`/`zoomAnchorOutput` and
/// `snappedOutputTime(atX:)`'s pixel-tolerance snap are the fix — see each
/// property's own doc comment. Zoom applies to the one geometry every
/// pixel and every gesture already share, so a click keeps meaning the
/// instant under the cursor at any zoom level, by construction rather than
/// by two axes being kept in step.
///
/// D56 (M5f Task 5): a cut draws as a FOLD — its own two edges collapsed to
/// the single OUTPUT position they meet at (`TimelineGeometry.x(atFold:)`),
/// not a gap and not the red overlay Task 3 deleted. Clicking a fold expands
/// it in place; right-clicking one offers Remove Cut. Both are handled ahead
/// of the existing scrub/drag machinery in `mouseDown`/`menu(for:)` — see
/// `foldHit(atX:)` — because a fold draws thin and would otherwise lose
/// every click to the scrub gesture that already claims the whole track.
/// Expansion (`expandedCutIDs`) is UI state exactly like `selection`: it
/// never reaches `edl`, so it cannot change `Timebase.outputDuration` or
/// where the playhead maps — see `EditorTimelineState.expandedCutIDs`'s doc
/// comment for the model-side half of that guarantee.
@MainActor
public final class TimelineView: NSView {
    public var onScrub: (Double) -> Void = { _ in }
    /// Called every time a drag resolves: `Selection(range:)` for a drag
    /// that cleared the pixel threshold, `nil` for a plain click (or a drag
    /// too short to count) — either way, always a REPLACEMENT of whatever
    /// was selected before, never an edit. See this type's doc comment.
    public var onSelect: (Selection?) -> Void = { _ in }
    /// A fold was clicked (`foldHit(atX:)`) and should toggle between
    /// collapsed and expanded — the owner (`EditorTimelineState`) holds the
    /// actual `expandedCutIDs` set and hands it back down through `update`,
    /// exactly as `selection` round-trips; this view never tracks expansion
    /// on its own.
    public var onToggleExpansion: (UUID) -> Void = { _ in }
    /// Right-click ▸ Remove Cut on a fold. Unlike `onToggleExpansion`, this
    /// IS an edit — the owner turns it into an undoable, persisted removal
    /// from `edl.cuts` (`EditorTimelineState.removeCut(id:)`).
    public var onRemoveCut: (UUID) -> Void = { _ in }
    /// A marker drag resolved to a real move (past `minimumDragPixels`,
    /// reused as the click-vs-drag threshold — see `mouseUp`). `Double`
    /// arrives in OUTPUT time — this view's own drawing axis — and the
    /// owner (`EditorTimelineState.moveMarker`) converts it back to SOURCE
    /// time before storing it; this view never does that conversion itself,
    /// matching `onScrub`'s existing division of labour.
    public var onMoveMarker: (UUID, Double) -> Void = { _, _ in }
    /// A marker was clicked without being dragged (D50/D56, M5f Task 6) —
    /// the owner presents whatever editing UI it chooses (a sheet, in
    /// production; see `EditorContentView`).
    public var onEditMarker: (UUID) -> Void = { _ in }

    /// Pixels of mouse wobble a click may exhibit before it counts as a
    /// deliberate selection rather than jitter. This is a PIXEL constant
    /// deliberately: a hand wobbles by roughly the same number of pixels on
    /// any click regardless of what the timeline shows. Converting it to a
    /// number of seconds requires knowing how much OUTPUT media time is
    /// packed into this view's current width at the current zoom — see
    /// `minimumDragSeconds`, which asks `geometry` for exactly that.
    /// `TrimGesture` itself never sees pixels; it takes the converted
    /// threshold as a parameter to `ended(atTime:minimumSeconds:)`.
    private static let minimumDragPixels: Double = 3.0

    /// Pixels of slop a click gets around a fold's own line (drawn just 2px
    /// wide, see `draw`) before it counts as "aimed at this fold" rather
    /// than the surrounding scrub track. Wider than `minimumDragPixels`
    /// deliberately: that constant absorbs a hand's wobble on an otherwise
    /// enormous target (the whole track); this one is the target itself,
    /// and a fold nobody can reliably click is a fold nobody can expand.
    ///
    /// Trap 2 (Task 5 dispatch): without a deliberate hit-test here,
    /// `mouseDown`'s pre-existing scrub/drag logic runs for EVERY mouse-down
    /// on the track — a fold is thin, so it would lose every click to a
    /// scrub, exactly the ambiguity Task 4 already fixed one interaction
    /// earlier for drag-vs-cut.
    private static let foldHitMarginPixels: Double = 6.0

    /// Pixels of slop a click gets around a marker's own glyph before it
    /// counts as "aimed at this marker" — the marker-track sibling of
    /// `foldHitMarginPixels`, same reasoning: a marker draws as a handful of
    /// pixels wide (see `draw`), so a click needs a target wider than its
    /// own drawn width to be reliably hittable.
    private static let markerHitMarginPixels: Double = 6.0

    /// D56 (M5f Task 3): draws on the OUTPUT (export) axis, built fresh from
    /// `duration`/`cuts` on every `update`/`layout` — see `rebuildGeometry`.
    /// M5f Task 8: also carries the current zoom/scroll (`zoomFactor`,
    /// `zoomAnchorOutput`), reapplied on top of a fresh, unzoomed
    /// `TimelineGeometry` every time this is rebuilt, rather than trying to
    /// carry a raw pixel offset forward across a resize or a landed cut —
    /// either changes `width`/`duration`, after which an old offset means a
    /// different visible span than the one the person was actually looking
    /// at.
    private var geometry = TimelineGeometry(
        width: 0, timebase: Timebase(sourceDuration: 0, edl: EditDecisionList()))
    /// The `Timebase` `geometry` was last built from — kept alongside it so
    /// the one conversion this view still performs (an OUTPUT instant a
    /// gesture resolved to, into the SOURCE instant a `Selection` is
    /// expressed in) does not rebuild a second `Timebase` on every mouse
    /// event. See `sourceSeconds(forOutput:)`.
    private var timebase = Timebase(sourceDuration: 0, edl: EditDecisionList())
    private var gesture = TrimGesture()

    /// Current zoom, relative to "the whole (uncut) recording fits exactly
    /// in `bounds.width`" — 1 is that default, unzoomed level; `zoomIn()`/
    /// `zoomOut()`/`scrollWheel(with:)`/`magnify(with:)` are the only things
    /// that change it. Clamped to `Self.minZoomFactor...Self.maxZoomFactor`
    /// everywhere it is set, never read raw off an event.
    private var zoomFactor: Double = 1
    /// The OUTPUT-time instant the current zoom is centred on — Step 3's
    /// "anchored on the playhead when there is no cursor": `zoomIn()`/
    /// `zoomOut()` (no cursor position available to a caller with no mouse
    /// event) always pass the current `playhead`; `scrollWheel`/`magnify`
    /// pass wherever the cursor actually is. Reapplied on every
    /// `rebuildGeometry()` so a resize or a new cut re-derives the SAME
    /// visual centre instead of a stale pixel offset (see `geometry`'s own
    /// doc comment).
    private var zoomAnchorOutput: Double = 0

    private static let minZoomFactor: Double = 1
    private static let maxZoomFactor: Double = 200

    /// The recording's own SOURCE duration, as handed down by
    /// `EditorTimelineState.displayState` — the input `rebuildGeometry`
    /// builds `timebase` (and therefore `geometry`) from, together with
    /// `cuts`. NOTHING interprets a gesture against this: it is the
    /// recording's length, not an axis.
    ///
    /// It used to be one. Until the M5f whole-branch review, a second
    /// geometry built over this value drove every gesture while `geometry`
    /// drove every pixel, citing M4b Critical #1 ("a drag's meaning must not
    /// shift as cuts land"). That defence WAS the defect it named: on a
    /// fixed source scale the same pixels resolve to the same source span
    /// forever, so a second deliberate drag over them appended a duplicate
    /// `Cut` and changed nothing — "a second trim silently did nothing",
    /// verbatim. The real M4b defect was never "the axis shrinks"; it was
    /// "the picture and the math disagree". A shrinking axis is correct
    /// precisely BECAUSE the picture shrinks with it: footage that has been
    /// cut is no longer drawn, so it can no longer be pointed at.
    private var duration: Double = 0
    /// SOURCE-time cuts, WITH identity — `edl.cuts` exactly as the owner
    /// already has them. Feeds `rebuildGeometry`'s `Timebase`; unlike before
    /// Task 5, a `Cut`'s `id` matters here as much as its `range` does:
    /// `foldHit(atX:)` reports it back through `onToggleExpansion`/
    /// `onRemoveCut`, and both need to name WHICH cut a click landed on, not
    /// merely that some cut did. Drawing a filled rect FOR a cut's REMOVED
    /// span is still gone (see `draw`), since a cut has no position on the
    /// output axis to draw one at — what draws now is its FOLD.
    private var cuts: [Cut] = []
    /// The folds currently expanded, by `Cut.id` — round-tripped from
    /// `EditorTimelineState.expandedCutIDs` exactly as `selection` is: this
    /// view never decides expansion on its own, only reports a click via
    /// `onToggleExpansion` and draws whatever the owner hands back.
    private var expandedCutIDs: Set<UUID> = []
    /// Which audio sources this recording has, and whether each is muted —
    /// one band each in `draw`.
    private var trackStates: [TrackState] = []
    /// Source-time peaks per audio track. Empty until sampling finishes, which
    /// draws as a plain band — see `EditorTimelineState.waveforms`.
    private var waveforms: [WaveformSamples] = []
    /// Source-time thumbnails for the video band; nil until decoding finishes.
    private var filmstrip: FilmstripFrames?
    /// OUTPUT time (M5f Task 3) — see `EditorTimelineState.displayState`'s
    /// doc comment for why these arrive unconverted.
    /// What the marker TRACK draws — `MarkerTrackPoints.compute`, which keeps
    /// markers whose instant was cut and places them at the fold. Distinct
    /// from `PreviewController.jumpPoints`, which drops those because a jump
    /// list must not offer to seek to a moment the viewer never sees.
    private var markerPoints: [JumpPoint] = []
    /// OUTPUT time (M5f Task 3) — `PreviewController`'s player plays the
    /// composition `CompositionBuilder` built from kept ranges only, so its
    /// `currentTime()` already IS output time before it ever reaches here.
    private var playhead: Double = 0
    /// SOURCE time (M5f Task 4) — the last COMMITTED selection, i.e. what a
    /// completed drag reported through `onSelect`. Set locally the instant
    /// a drag ends (for an immediate redraw, with no round trip through the
    /// owner needed for the rectangle to appear) and also mirrored back down
    /// through `update(selection:)`, so the owner clearing it externally
    /// (`EditorTimelineState.cutSelection()`, once a cut is made) redraws
    /// this view without this type needing its own "clear" entry point.
    /// `nil` means no selection — nothing drawn beyond `gesture.previewRange`.
    private var selection: Selection?

    /// Set by `mouseDown` when the press landed on a fold (`foldHit(atX:)`),
    /// so `mouseDragged`/`mouseUp` skip the scrub/selection machinery
    /// entirely for the rest of THIS press. Without this, `mouseUp` (which
    /// has no idea `mouseDown` already resolved the click as a fold toggle)
    /// would see `gesture.ended` return `nil` — no drag was ever begun — and
    /// treat that exactly like a plain click: clearing `selection` via
    /// `onSelect(nil)` and reissuing a scrub to wherever the fold happened
    /// to sit. A fold click must not ALSO silently discard whatever was
    /// selected or move the playhead.
    private var activeFoldClick: UUID?

    /// Set by `mouseDown` when the press landed on a marker (`markerHit(at:)`,
    /// D50/D56, M5f Task 6) — the marker-track sibling of `activeFoldClick`,
    /// same reason: without it `mouseDragged`/`mouseUp` would run the
    /// scrub/selection machinery for the rest of this press, exactly the
    /// ambiguity `activeFoldClick` already exists to prevent one interaction
    /// earlier.
    ///
    /// Unlike a fold (which always toggles on `mouseDown` and never drags),
    /// a marker press does NOT resolve immediately: whether it becomes a
    /// move or an edit depends on how far the mouse travels before
    /// `mouseUp`, so this stays set across `mouseDragged` calls rather than
    /// being cleared the instant the press lands.
    private var activeMarkerDrag: UUID?
    /// Where `activeMarkerDrag`'s press began, in VIEW-LOCAL pixels — the
    /// anchor `mouseUp` measures total travel from to decide click (edit)
    /// vs. drag (move), the same pixel-threshold idea `minimumDragPixels`
    /// already uses for drag-vs-cut.
    private var markerDragOrigin: NSPoint?
    /// The dragged marker's LIVE position while `activeMarkerDrag` is set,
    /// in OUTPUT seconds, for `draw()` to render it at instead of its stale
    /// `jumpPoints` position — without this the marker being dragged would
    /// stay drawn at its old spot until `mouseUp` finally reports the move.
    /// `nil` whenever no marker drag is in progress.
    private var markerDragPreviewOutputTime: Double?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rebuildGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TimelineView is not loaded from a nib") }

    public override var isFlipped: Bool { true }

    /// `NSView`'s default is `false` — without overriding it, a click here
    /// would never make this view first responder, and `keyDown`'s `+`/`-`
    /// zoom shortcuts (Step 3) would never actually reach it despite
    /// compiling and passing every test that calls `keyDown(with:)`
    /// directly. AppKit's own click-to-focus (`NSWindow` making the
    /// hit-tested view first responder before delivering its `mouseDown`)
    /// only fires for a view that opts in here.
    public override var acceptsFirstResponder: Bool { true }

    /// Replaces everything the view draws and recomputes `geometry` for the
    /// bounds it has right now. Called by the owner whenever the underlying
    /// EDL, markers or playback position change.
    ///
    /// `duration`/`cuts`/`selection` are SOURCE time; `jumpPoints`/`playhead`
    /// are OUTPUT time. See this type's stored properties of the same names
    /// for why the two halves of this parameter list are deliberately on
    /// different clocks. `selection` defaults to `nil`, and `expandedCutIDs`
    /// to empty, for callers (existing tests among them) that don't drive
    /// them at all.
    public func update(duration: Double, cuts: [Cut], markerPoints: [JumpPoint],
                       playhead: Double, selection: Selection? = nil,
                       expandedCutIDs: Set<UUID> = [],
                       trackStates: [TrackState] = [],
                       waveforms: [WaveformSamples] = [],
                       filmstrip: FilmstripFrames? = nil) {
        self.duration = duration
        self.cuts = cuts
        self.markerPoints = markerPoints
        self.playhead = playhead
        self.selection = selection
        self.expandedCutIDs = expandedCutIDs
        self.trackStates = trackStates
        self.waveforms = waveforms
        self.filmstrip = filmstrip
        rebuildGeometry()
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        rebuildGeometry()
        needsDisplay = true
    }

    /// Builds the OUTPUT-time geometry `draw()` positions the playhead and
    /// jump points against — D56's first requirement: the timeline reflects
    /// what will actually export, not `capture.mov`'s own length. `cuts`
    /// folds into a throwaway `EditDecisionList` purely to reach
    /// `Timebase`'s conversions (Task 1) — but, since Task 5, WITH each
    /// `Cut`'s own `id` preserved rather than re-minted: `geometry.x(atFold:)`
    /// and `foldHit(atX:)` both need to name a specific cut, and a fresh
    /// `Cut(range:)` per call would silently hand back a different id than
    /// the one `edl.cuts` (and `EditorTimelineState.expandedCutIDs`) actually
    /// use.
    private func rebuildGeometry() {
        let edl = EditDecisionList(cuts: cuts)
        timebase = Timebase(sourceDuration: duration, edl: edl)
        // Expanded folds insert their cut's SOURCE length into the axis, so
        // later content shifts right and the playhead jumps the band rather
        // than appearing to travel through removed footage. Passed to the
        // geometry rather than applied at draw time because gestures share
        // this axis — a drawing that inserted space while hit-testing did not
        // is M4b's Critical #1.
        let expansions = cuts
            .filter { expandedCutIDs.contains($0.id) }
            .map { TimelineGeometry.Expansion(
                output: timebase.foldPosition(for: $0),
                seconds: $0.range.end - $0.range.start) }
        let base = TimelineGeometry(width: bounds.width, timebase: timebase,
                                    expansions: expansions)
        // M5f Task 8: reapply whatever zoom is currently in effect on top of
        // the fresh, unzoomed geometry — see `geometry`'s own doc comment
        // for why this recomputes from the anchor every time rather than
        // trying to carry a raw offset across a resize or a landed cut.
        geometry = zoomFactor > Self.minZoomFactor
            ? base.zoomed(by: zoomFactor, anchoredAt: OutputTime(zoomAnchorOutput)) : base
    }

    /// The pixel width an EXPANDED fold draws at: `cut`'s own SOURCE length,
    /// converted at the OUTPUT timeline's own pixels-per-second
    /// (`geometry.pixelsPerSecond`, M5f Task 8 — was `width / duration`
    /// before zoom existed, which is exactly what `pixelsPerSecond` equals
    /// at the default zoom level, so this is a strict generalisation, not a
    /// behaviour change at 1x) — the same scale every kept second on this
    /// view already draws at, so the revealed footage reads at a size
    /// consistent with everything around it, not an arbitrary fixed box.
    /// Also doubles as the expanded fold's HIT-TEST width (see
    /// `foldHit(atX:)`): the whole widened rect is the target once expanded,
    /// not just its edge. Zero pixels-per-second (nothing kept, or zero
    /// view width) has no scale to borrow, so this returns 0 rather than
    /// dividing by it.
    /// The band's drawn span for an expanded cut, from the geometry that
    /// reserved the space.
    private func expansionSpan(for cut: Cut) -> (x: Double, width: Double)? {
        geometry.expansionSpan(atOutput: timebase.foldPosition(for: cut))
    }

    private func expandedWidthPixels(for cut: Cut) -> Double {
        guard geometry.pixelsPerSecond > 0 else { return 0 }
        // Exactly the space the geometry inserted for it — no clamp.
        //
        // `TimelineFoldExtent` used to bound this against the next fold and the
        // view edge, because expansion did not reflow and an unbounded band
        // drew straight over whatever followed. Reflow removes the overlap at
        // its source: the next fold has itself moved right by this band's
        // width, so there is nothing left to collide with. Clamping now would
        // be actively wrong — it would draw a band narrower than the space the
        // axis reserved, leaving a gap.
        return (cut.range.end - cut.range.start) * geometry.pixelsPerSecond
    }

    /// The pixel height of the thin marker lane at the very top of the view
    /// (D56, M5f Task 6: "markers get their own thinner track above" video
    /// and audio). A FIXED pixel height, not a fraction of `bounds.height`:
    /// a fraction would make the lane — and the margin `markerHit` accepts
    /// around a marker in it — shrink along with the view, and a target
    /// that keeps getting thinner is eventually unclickable. Clamped to at
    /// most 40% of the view's own height so a very short view (a test
    /// double a handful of pixels tall) never gives the marker lane MORE
    /// room than the video/audio tracks it sits above.
    private var markerTrackHeight: Double { min(14.0, bounds.height * 0.4) }

    /// The marker whose glyph `point` lands on/near, or `nil`. Gated to the
    /// MARKER LANE's own y-range (`markerTrackHeight` down from the top,
    /// this view is flipped) — unlike `foldHit(atX:)`, which spans the
    /// whole view height because a fold's line is drawn full-height on
    /// purpose (one collapse across the whole synchronised stack). A click
    /// on the video/audio tracks below must keep meaning scrub/select
    /// exactly as before, even at an x that happens to coincide with a
    /// marker sitting above it — this y-gate is what keeps the two tracks'
    /// gestures from colliding.
    private func markerHit(at point: NSPoint) -> JumpPoint? {
        guard point.y <= markerTrackHeight else { return nil }
        guard bounds.width > 0, geometry.duration > 0 else { return nil }
        for marker in markerPoints {
            let x = geometry.x(atOutput: OutputTime(marker.timeSeconds))
            if abs(point.x - x) <= Self.markerHitMarginPixels { return marker }
        }
        return nil
    }

    /// The `Cut` whose fold `x` lands in/near, or `nil` if `x` is plain
    /// scrub/drag territory. A COLLAPSED fold is a `foldHitMarginPixels`
    /// window either side of its single line; an EXPANDED one is its whole
    /// widened rect (`expandedWidthPixels`), since that entire rect IS the
    /// revealed cut once expanded. Checked before any drag/scrub logic runs
    /// (`mouseDown`, `menu(for:)`) — see this type's own doc comment and
    /// `foldHitMarginPixels` for why a fold needs its own dedicated hit-test
    /// rather than falling through to the track's.
    private func foldHit(atX x: Double) -> Cut? {
        // A degenerate geometry (zero width, or zero OUTPUT duration —
        // everything cut away) has no real fold positions: `geometry.x
        // (atFold:)` falls back to 0 for every cut in that case (see
        // `TimelineGeometry.isDegenerate`), which would otherwise make
        // every cut look like a fold sitting exactly at the origin and
        // swallow a click aimed at nothing in particular — found by
        // `TimelineViewTests.zeroWidthViewIsFinite`, an existing test whose
        // click at x=0 landed on this false "fold" instead of scrubbing
        // the instant this guard was missing.
        guard bounds.width > 0, geometry.duration > 0 else { return nil }
        for cut in cuts {
            let foldX = geometry.x(atFold: cut)
            if expandedCutIDs.contains(cut.id), let span = expansionSpan(for: cut) {
                // The band as DRAWN, so clicking the red rectangle is what
                // hits it — hit-testing at `x(atFold:)` tested a rectangle one
                // width right of the visible one.
                if x >= span.x, x <= span.x + span.width { return cut }
            } else if abs(x - foldX) <= Self.foldHitMarginPixels {
                return cut
            }
        }
        return nil
    }

    /// The SOURCE instant `output` names, or `nil` when there is no output
    /// timeline for it to name one on (everything cut — the single case
    /// `Timebase.sourceTime(forOutput:)` can fail, since the output axis has
    /// no cuts in it by construction).
    ///
    /// The ONE conversion this view performs, and it happens at the moment
    /// a `SourceTime` is actually needed — building a `Selection` for
    /// `edl.cuts`, or handing `onScrub` the source instant its own contract
    /// is written in. Everything upstream of it (hit-testing, the gesture
    /// state machine, snapping, the drag threshold) stays on the output
    /// axis, which is the axis being drawn.
    private func sourceSeconds(forOutput output: OutputTime) -> Double? {
        timebase.sourceTime(forOutput: output)?.seconds
    }

    /// `minimumDragPixels` converted at the current zoom, on the same axis
    /// `gesture` is fed — `TimelineGeometry.duration(ofPixels:)` divides by
    /// `pixelsPerSecond` directly rather than differencing two
    /// `outputTime(atX:)` calls (mathematically the same result, since the
    /// `visibleOffset` term cancels either way). Zero pixels-per-second
    /// (zero width, or everything cut) makes this 0; `TrimGesture.ended`
    /// checks `length > 0` separately for exactly that case.
    private var minimumDragSeconds: Double {
        geometry.duration(ofPixels: Self.minimumDragPixels)
    }

    /// Pixels of slop a drag's endpoint gets before it snaps onto a nearby
    /// marker, existing cut edge, or the playhead (Step 4, M5f Task 8) — a
    /// PIXEL tolerance, not a seconds one: `TrimGesture.ended`'s whole point
    /// is that a fixed number of SECONDS reads as generous at one zoom level
    /// and imperceptible at another, and a snap tolerance that becomes
    /// unusable exactly when someone has zoomed in to place a cut precisely
    /// would defeat the reason zoom exists at all.
    private static let snapMarginPixels: Double = 6.0

    /// The OUTPUT instant `event` points at — the one axis this view draws
    /// on, and therefore the one it interprets interaction on.
    ///
    /// M5f whole-branch review, Criticals C1 and C2. This used to answer in
    /// SOURCE time off a second, fixed-source geometry, which made every
    /// primary interaction resolve to a different instant than the pixels
    /// the person was looking at the moment anything had been cut: on a
    /// 10s recording with one 2s cut at 800px, a click at x=400 drew the
    /// playhead at x=300, and a drag from 400 to 600 removed source 5.0-7.5
    /// while the pixels pointed at 6.0-8.0. Zoom multiplied the error
    /// rather than correcting it, because the same zoom NUMBER applied to
    /// two axes on different clocks pivots them around different instants.
    ///
    /// The rule, which Task 6's marker drag already followed: interaction is
    /// interpreted on the axis being drawn. A `SourceTime` is produced only
    /// where one is actually needed (`sourceSeconds(forOutput:)`), never as
    /// the currency gestures are carried in.
    private func time(for event: NSEvent) -> OutputTime {
        let point = convert(event.locationInWindow, from: nil)
        return snappedOutputTime(atX: point.x)
    }

    /// `geometry.outputTime(atX:)`, pulled onto the nearest fold, marker or
    /// playhead when one is DRAWN within `snapMarginPixels` of `x` at the
    /// current zoom.
    ///
    /// Every candidate is compared as a pixel on `geometry` — the same call
    /// `draw` makes for the same thing, so a snap target is always exactly
    /// where the thing it snaps to is on screen. Markers and the playhead
    /// are already OUTPUT time (Task 3) and need no conversion at all; a
    /// cut contributes ONE candidate, not two, because both of its edges
    /// collapse onto the single instant its fold is drawn at
    /// (`Timebase.foldPosition(for:)` via `geometry.x(atFold:)`) — snapping
    /// to a cut's start and its end as separate targets would name two
    /// pixels for something drawn as one line.
    ///
    /// A candidate scrolled out of the viewport is NOT filtered out, and
    /// that is deliberate: `x(atOutput:)` clamps an off-viewport instant to
    /// 0 or `width`, and `draw` clamps the same way for the same thing, so
    /// a fold scrolled off the left really is drawn as a red line at x=0.
    /// Snapping to it there keeps this method's whole contract — a snap
    /// target is where the thing it snaps to is ON SCREEN. A visibility
    /// filter here would make a drag refuse to snap to a line the person
    /// can see, which is the same picture-and-math disagreement C1 was.
    /// Whether the view should pile off-screen content at its edges at all
    /// is a DRAWING question, adjacent to the review's own undetermined
    /// item about `visibleOffset`'s upper clamp; if that changes, this
    /// method needs nothing — it already follows `draw`.
    ///
    /// The closest candidate within tolerance wins, not the first one found
    /// — two candidates both inside the margin (a marker sitting right next
    /// to a fold) should snap to whichever is actually nearer, not whichever
    /// happens to be earlier in `cuts`/`jumpPoints`.
    private func snappedOutputTime(atX x: Double) -> OutputTime {
        let raw = geometry.outputTime(atX: x)
        guard bounds.width > 0, geometry.duration > 0 else { return raw }
        var candidates: [OutputTime] = cuts.map { timebase.foldPosition(for: $0) }
        candidates.append(contentsOf: markerPoints.map { OutputTime($0.timeSeconds) })
        candidates.append(OutputTime(playhead))

        var best: (output: OutputTime, distance: Double)?
        for candidate in candidates {
            let distance = abs(geometry.x(atOutput: candidate) - x)
            guard distance <= Self.snapMarginPixels else { continue }
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.output ?? raw
    }

    // MARK: - Zoom (Step 3, M5f Task 8)

    /// Applies `factor` to the current zoom, anchored at `anchor` (an OUTPUT
    /// instant), clamped to `Self.minZoomFactor...Self.maxZoomFactor`, and
    /// rebuilds `geometry` against it. The one place
    /// `zoomFactor`/`zoomAnchorOutput` change — `zoomIn()`, `zoomOut()`,
    /// `scrollWheel(with:)` and `magnify(with:)` all funnel through this
    /// rather than mutating either property directly, so the clamp can
    /// never be skipped by a new caller.
    private func setZoom(_ factor: Double, anchoredAtOutput anchor: Double) {
        zoomFactor = min(max(factor, Self.minZoomFactor), Self.maxZoomFactor)
        zoomAnchorOutput = anchor
        rebuildGeometry()
        needsDisplay = true
    }

    /// Step 3's "a control": callable with no mouse event at all (a
    /// keyboard shortcut, see `keyDown`, or code driving this view directly
    /// in a test) — anchored on the PLAYHEAD, per the brief's own wording,
    /// since there is no cursor position to anchor on instead.
    public func zoomIn() { setZoom(zoomFactor * 2, anchoredAtOutput: playhead) }

    /// The inverse of `zoomIn()`, same anchor rule.
    public func zoomOut() { setZoom(zoomFactor / 2, anchoredAtOutput: playhead) }

    /// Scroll-to-zoom (Step 3): vertical scroll deltas zoom in/out rather
    /// than scrolling this view's content — `TimelineView` has no other use
    /// for the scroll wheel (there is no independent vertical scroll to
    /// preserve), so claiming it entirely for zoom needs no modifier key.
    /// Anchored at the CURSOR (`point.x`, converted through the CURRENT,
    /// pre-zoom `geometry`) — the brief's playhead fallback is for a
    /// caller with no cursor position at all, which a scroll event always
    /// has.
    public override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let anchor = geometry.outputTime(atX: point.x).seconds
        // Scrolling UP (a positive deltaY, the "natural" convention's own
        // sign) zooms IN — the same direction scrolling up already means in
        // every app that treats the wheel as a zoom control.
        let step = 1 + min(abs(event.scrollingDeltaY) / 50.0, 1.0)
        setZoom(zoomFactor * (event.scrollingDeltaY > 0 ? step : 1 / step), anchoredAtOutput: anchor)
    }

    /// Trackpad pinch-to-zoom. `event.magnification` is already a signed
    /// fraction (0.1 means "10% bigger"), so `1 + magnification` converts it
    /// straight into `zoomed(by:)`'s own multiplicative factor — no
    /// per-event step size to tune, unlike the scroll wheel's discrete
    /// deltas above.
    public override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let anchor = geometry.outputTime(atX: point.x).seconds
        setZoom(zoomFactor * (1 + event.magnification), anchoredAtOutput: anchor)
    }

    /// The keyboard half of Step 3's "a control": `+`/`=` zoom in, `-` zooms
    /// out, both anchored on the PLAYHEAD (`zoomIn()`/`zoomOut()`'s own
    /// rule) since a keypress carries no cursor position. `=` is included
    /// alongside `+` because it is the SAME physical key on every standard
    /// keyboard layout — most "zoom in" shortcuts elsewhere (browsers,
    /// Xcode) accept both for exactly that reason, and requiring Shift for
    /// `+` specifically would be an arbitrary extra step here. Anything
    /// else falls through to `super`, so this never swallows a keystroke
    /// meant for something else in the window.
    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=":
            zoomIn()
        case "-":
            zoomOut()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Mouse handling

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // D50/D56 (M5f Task 6): checked BEFORE the fold hit-test and any
        // scrub/drag logic, for the same reason Task 5's fold check runs
        // before scrub/drag — a marker's glyph is a small target, and the
        // marker lane's y-gate (`markerHit`) is what keeps this from ever
        // firing for a click on the video/audio tracks below. Unlike a
        // fold, this does NOT resolve on `mouseDown`: whether it becomes a
        // move or an edit is decided in `mouseUp`, once total travel is
        // known (see `activeMarkerDrag`'s doc comment).
        if let marker = markerHit(at: point) {
            activeMarkerDrag = marker.id
            markerDragOrigin = point
            markerDragPreviewOutputTime = marker.timeSeconds
            needsDisplay = true
            return
        }
        // D56 (M5f Task 5), Trap 2: checked BEFORE any scrub/drag logic
        // runs. A fold click never begins a gesture and never scrubs — see
        // `activeFoldClick`'s doc comment for why `mouseDragged`/`mouseUp`
        // also need to know this happened.
        if let cut = foldHit(atX: point.x) {
            activeFoldClick = cut.id
            onToggleExpansion(cut.id)
            needsDisplay = true
            return
        }
        activeFoldClick = nil
        let output = time(for: event)
        gesture.began(atTime: output.seconds)
        // `onScrub`'s contract is SOURCE time (see
        // `EditorTimelineState.onScrub`), so the conversion happens here,
        // at the call that needs it. Nothing to scrub to when there is no
        // output timeline at all — `EditorTimelineState.onScrub` already
        // returns for that case, so skipping the call changes nothing
        // observable.
        if let source = sourceSeconds(forOutput: output) { onScrub(source) }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        if activeMarkerDrag != nil {
            let point = convert(event.locationInWindow, from: nil)
            markerDragPreviewOutputTime = geometry.outputTime(atX: point.x).seconds
            needsDisplay = true
            return
        }
        guard activeFoldClick == nil else { return }
        gesture.moved(toTime: time(for: event).seconds)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if let markerID = activeMarkerDrag {
            let point = convert(event.locationInWindow, from: nil)
            let origin = markerDragOrigin ?? point
            activeMarkerDrag = nil
            markerDragOrigin = nil
            markerDragPreviewOutputTime = nil
            needsDisplay = true
            // Same pixel threshold `minimumDragPixels` uses to separate a
            // deliberate drag from click jitter, reused rather than
            // duplicated (D50/D56, M5f Task 6): total on-screen travel is
            // what a hand's wobble is measured in, and this is already the
            // constant this view uses for exactly that judgement one
            // interaction over.
            if abs(point.x - origin.x) < Self.minimumDragPixels {
                onEditMarker(markerID)
            } else {
                onMoveMarker(markerID, geometry.outputTime(atX: point.x).seconds)
            }
            return
        }
        if activeFoldClick != nil {
            // The press already resolved in `mouseDown` (a fold toggled) —
            // no gesture was begun, so falling through to the normal
            // plain-click path below would misread that as a click that
            // scrubs and clears `selection`. See `activeFoldClick`'s doc
            // comment.
            activeFoldClick = nil
            return
        }
        let output = time(for: event)
        let outputRange = gesture.ended(atTime: output.seconds, minimumSeconds: minimumDragSeconds)
        let resolved = outputRange.flatMap(sourceRange(ofOutput:))
        // D56 (M5f Task 4): a resolved drag REPLACES the selection — it
        // never appends a `Cut`. A plain click (nil `range`) clears any
        // prior selection and scrubs, matching the pre-D56 behaviour for
        // clicks exactly; a deliberate drag reports the new selection and,
        // as before this task, does NOT also scrub — its own `mouseDown`
        // already moved the playhead to the drag's start.
        selection = resolved.map { Selection(range: $0) }
        onSelect(selection)
        if resolved == nil, let source = sourceSeconds(forOutput: output) {
            // A drag that resolved to a range but could not be expressed in
            // source time falls through to the click path deliberately,
            // rather than being dropped: an unreported gesture is the silent
            // no-op this project keeps finding. It is unreachable today —
            // the only way the conversion fails is an empty output timeline,
            // where `geometry` is degenerate, every pixel maps to output 0
            // and `TrimGesture.ended`'s `length > 0` guard has already
            // returned nil.
            onScrub(source)
        }
        needsDisplay = true
    }

    /// The SOURCE span an OUTPUT span covers: each endpoint converted
    /// independently, giving the SOURCE-CONTIGUOUS reading of a drag.
    ///
    /// The question the M5f whole-branch review left undetermined, now that
    /// gestures are on the output axis: should a drag spanning a fold select
    /// the source-contiguous span (endpoints converted, everything between
    /// them included — the already-removed footage among it) or the
    /// output-contiguous one (only the kept pieces, as several disjoint
    /// spans)? Source-contiguous, for three reasons:
    ///
    ///  - The two are OBSERVATIONALLY IDENTICAL in what gets removed. The
    ///    span between the endpoints that a previous cut already removed
    ///    contributes zero output seconds, so `Timebase.outputDuration`
    ///    falls by exactly the number of output seconds the drag covered
    ///    either way, and `draw` renders the same rectangle either way
    ///    (both ends map through `geometry.x(atSource:)`).
    ///  - Output-contiguous would need `Selection` to carry N ranges and
    ///    `cutSelection()` to append N `Cut`s for one gesture — N folds
    ///    stacked on the single pixel they all collapse onto, N separate
    ///    "Remove Cut" targets there — for no visible difference.
    ///  - One gesture producing one `Cut` keeps one undo step meaning one
    ///    thing.
    ///
    /// The cost, recorded rather than hidden: the new cut can fully contain
    /// an older one, and removing the older fold then restores nothing
    /// visible. That is pre-existing (overlapping cuts have always been
    /// possible) and bounded — the containing cut's own fold still restores
    /// the whole span — but it is a genuine, if minor, no-op the fold UI can
    /// present. Coalescing overlapping cuts on append would close it; that
    /// is a `EditDecisionList`-level change, deliberately not made here.
    private func sourceRange(ofOutput range: TimeRange) -> TimeRange? {
        guard let start = sourceSeconds(forOutput: OutputTime(range.start)),
              let end = sourceSeconds(forOutput: OutputTime(range.end)) else { return nil }
        return TimeRange(start: start, end: end)
    }

    /// AppKit's right-click entry point: returning `nil` suppresses any
    /// context menu (the default off a fold), a non-nil menu shows it.
    /// D56 (M5f Task 5): "right-clicking [a fold] offers Remove Cut". Reuses
    /// `foldHit(atX:)` — the same hit-test `mouseDown` uses — so left- and
    /// right-click agree on exactly what counts as "on a fold".
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let cut = foldHit(atX: point.x) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove Cut",
                              action: #selector(handleRemoveCutMenuItem(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = cut.id
        menu.addItem(item)
        return menu
    }

    /// Not `private`: a test seam, exactly like `EditorWindowController`'s
    /// `...ForTesting` methods — driving a real `NSMenu`'s target-action
    /// dispatch needs a live `NSApp`/window this test target cannot assume,
    /// so a test instead calls this directly with the same `NSMenuItem`
    /// `menu(for:)` would have built.
    @objc func handleRemoveCutMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRemoveCut(id)
    }

    // MARK: - Drawing (appearance only — deliberately untested, see Task 6 brief)

    /// Tiles thumbnails across the video band, each one chosen by the SOURCE
    /// instant its slot shows.
    ///
    /// Slots are one thumbnail wide rather than one pixel, so this asks
    /// `TimelineSampleIndex` once per tile instead of once per column — but the
    /// mapping is the same one the waveform uses, so both bands agree about
    /// what moment a given x shows, and a cut makes the strip jump exactly
    /// where the waveform does.
    private func drawFilmstrip(_ strip: FilmstripFrames, in rect: NSRect) {
        guard !strip.frames.isEmpty, rect.height > 2, let context = NSGraphicsContext.current else { return }
        let kept = KeptRanges.compute(duration: duration, cuts: cuts.map(\.range))
        let first = strip.frames[0]
        let aspect = first.height > 0 ? Double(first.width) / Double(first.height) : 16.0 / 9.0
        let tileWidth = max(8, rect.height * aspect)

        context.saveGraphicsState()
        NSBezierPath(rect: rect).setClip()
        var x = rect.minX
        while x < rect.maxX {
            defer { x += tileWidth }
            let output = geometry.outputTime(atX: x + tileWidth / 2).seconds
            guard let index = TimelineSampleIndex.index(
                forOutputSeconds: output, keptRanges: kept,
                samplesPerSecond: strip.samplesPerSecond,
                sampleCount: strip.frames.count) else { continue }
            context.cgContext.draw(strip.frames[index],
                                   in: CGRect(x: x, y: rect.minY, width: tileWidth, height: rect.height))
        }
        context.restoreGraphicsState()
    }

    /// Draws one vertical bar per pixel column, mirrored about the band's
    /// centre line.
    ///
    /// Each column asks `TimelineSampleIndex` which SOURCE sample it shows,
    /// which is what makes the waveform follow cuts and zoom without the audio
    /// ever being re-read: the samples are the recording's, the axis is the
    /// edit's. A column with no source behind it (past the trimmed end) draws
    /// nothing rather than repeating the last value.
    private func drawWaveform(_ samples: WaveformSamples, in rect: NSRect,
                              muted: Bool, gain: Double) {
        guard !samples.peaks.isEmpty, rect.height > 2 else { return }
        let kept = KeptRanges.compute(duration: duration, cuts: cuts.map(\.range))
        let midY = rect.midY
        let halfHeight = (rect.height - 2) / 2
        let normal = NSColor.labelColor.withAlphaComponent(muted ? 0.2 : 0.55)
        // Clipping stays visible on a muted track: muting is an edit decision,
        // clipping is damage, and hiding the damage because the track is
        // currently silent is how it survives to the export.
        let clipping = NSColor.systemRed.withAlphaComponent(muted ? 0.5 : 0.9)

        var x = 0.0
        while x < bounds.width {
            defer { x += 1 }
            let output = geometry.outputTime(atX: x).seconds
            guard let index = TimelineSampleIndex.index(
                forOutputSeconds: output, keptRanges: kept,
                samplesPerSecond: samples.samplesPerSecond,
                sampleCount: samples.peaks.count) else { continue }
            let peak = Double(samples.peaks[index])
            let clipped = WaveformScale.isClipped(peak: peak, gain: gain)
            (clipped ? clipping : normal).setFill()
            // Logarithmic, and gain-aware: the bar shows what will be
            // exported, not what was captured (`WaveformScale`).
            //
            // A floor of half a pixel so a quiet passage still reads as "there
            // is audio here" rather than as a gap in the track.
            let height = max(0.5, WaveformScale.height(forPeak: peak, gain: gain) * halfHeight)
            NSBezierPath(rect: NSRect(x: x, y: midY - height, width: 1, height: height * 2)).fill()
            // A clipped column is marked at the band's edges too, so it is
            // findable when the whole passage is loud and every bar is tall.
            if clipped {
                NSBezierPath(rect: NSRect(x: x, y: rect.minY, width: 1, height: 2)).fill()
                NSBezierPath(rect: NSRect(x: x, y: rect.maxY - 2, width: 1, height: 2)).fill()
            }
        }
    }

    /// Where an output instant is drawn. A test seam, so a test can assert
    /// that drawing and hit-testing agree without reaching into `geometry`.
    func xForTesting(outputSeconds: Double) -> Double {
        geometry.x(atOutput: OutputTime(outputSeconds))
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()

        // D56 (M5f Task 6): three stacked tracks — a thin marker lane above
        // video, which sits above audio — replacing the single
        // undifferentiated band Task 5 left behind. Cuts remain
        // SYNCHRONISED across video and audio by default (D59 cut per-track
        // cuts from this milestone): there is exactly one `cuts`/fold
        // drawing pass below, spanning the full view height including the
        // marker lane, because a cut is one decision affecting the whole
        // stack, not a per-track one.
        // The audio band is now ONE BAND PER SOURCE (microphone, system audio)
        // rather than a single undifferentiated strip: D56 Tier 1 asked for
        // separate tracks, and drawing both sources as one meant a muted
        // source looked exactly like an unmuted one while exporting
        // differently. Sources are derived from `trackStates`, so a recording
        // made without the microphone gets no empty mic lane implying a source
        // that was never captured.
        let tracks = TimelineTrackLayout.audioTracks(in: trackStates)
        let bands = TimelineTrackLayout.bands(in: bounds,
                                              markerHeight: markerTrackHeight,
                                              audioTracks: tracks)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: bands.marker).fill()
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(rect: bands.video).fill()
        if let filmstrip { drawFilmstrip(filmstrip, in: bands.video) }
        for (track, rect) in bands.audio {
            let muted = trackStates.first { $0.track == track }?.muted ?? false
            // A muted source draws markedly fainter — the one visible
            // difference between "this audio is in the export" and "it is not".
            NSColor.tertiaryLabelColor.withAlphaComponent(muted ? 0.15 : 0.6).setFill()
            NSBezierPath(rect: rect).fill()
            if let samples = waveforms.first(where: { $0.track == track }) {
                let gain = trackStates.first { $0.track == track }?.gain ?? 1.0
                drawWaveform(samples, in: rect, muted: muted, gain: gain)
            }
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: rect.minY, width: bounds.width, height: 1)).fill()
        }

        // D56 (M5f Task 5): a cut is a FOLD — its own two edges, collapsed
        // to the single OUTPUT position they meet at (`geometry.x(atFold:)`),
        // drawn as a thin red line — not a gap, and not the red OVERLAY
        // patch Task 3 deleted (which drew a cut's REMOVED span as if it
        // still occupied space on this axis; a fold draws only the single
        // point the removal collapsed to). An EXPANDED fold
        // (`expandedCutIDs`, toggled by `foldHit` in `mouseDown`) widens
        // that line into a transparent red rect sized to the cut's own
        // SOURCE length (`expandedWidthPixels`) — "showing the folded
        // segment" — at the same pixels-per-second the rest of this
        // (output) timeline already draws at. Content drawn after a fold is
        // deliberately NOT pushed right to make room for it: this is
        // appearance only, and the property that matters is that NOTHING here
        // can move `geometry` itself — the single axis every gesture and every
        // drawn pixel share, whose divergence is M4b's Critical #1.
        //
        // Corrected 2026-09-07: the expansion IS now bounded, by
        // `TimelineFoldExtent`, so it stops at the next fold and at the view's
        // edge. Not reflowing remains a decision; drawing over the next fold
        // was simply a missing bound, and a long cut's expansion smeared across
        // everything after it.
        for cut in cuts {
            let foldX = geometry.x(atFold: cut)
            if expandedCutIDs.contains(cut.id), let span = expansionSpan(for: cut) {
                // Drawn in the space the AXIS reserved, not at `x(atFold:)`.
                // That is the instant the cut collapsed to — after insertion,
                // the band's trailing edge — so drawing from there put the band
                // a full width too far right, over the content that follows,
                // and left the reserved space blank.
                NSColor.systemRed.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: NSRect(x: span.x, y: 0, width: span.width,
                                          height: bounds.height)).fill()
            } else {
                NSColor.systemRed.setFill()
                NSBezierPath(rect: NSRect(x: foldX - 1, y: 0, width: 2,
                                          height: bounds.height)).fill()
            }
        }

        // D56 (M5f Task 4): selecting is not cutting, and is drawn as such —
        // transparent BLUE, not the old orange "about to cut" preview it
        // replaces. The live in-progress drag (`gesture.previewRange`) takes
        // priority over the last COMMITTED selection (`self.selection`), so
        // starting a fresh drag shows only the new range, not both at once;
        // once the drag ends, `previewRange` goes nil and `selection` (set
        // in `mouseUp`) takes over, so the rectangle persists on screen
        // until a new drag replaces it or a cut clears it.
        // `gesture.previewRange` is OUTPUT time (the axis gestures are
        // interpreted on) while `selection` is SOURCE time (the clock
        // `edl.cuts` is expressed in, which is what a selection is destined
        // to become) — so the two take different mapping calls to reach a
        // pixel. Both ends of a SELECTION can still fail to map (a
        // selection sitting over ground a later cut removed) — skipped
        // rather than clamped, so a half-inside-a-cut selection isn't drawn
        // as spanning territory it does not actually cover.
        let previewX = gesture.previewRange.map {
            (geometry.x(atOutput: OutputTime($0.start)), geometry.x(atOutput: OutputTime($0.end)))
        }
        let selectionX = selection.flatMap { selection -> (Double, Double)? in
            guard let startX = geometry.x(atSource: SourceTime(selection.range.start)),
                  let endX = geometry.x(atSource: SourceTime(selection.range.end)) else { return nil }
            return (startX, endX)
        }
        if let (startX, endX) = previewX ?? selectionX {
            //
            // Alpha 0.35 is the same value the old orange cut-preview used —
            // already tuned, in this same method, to read clearly over both
            // `controlBackgroundColor` (the view's own fill) and the
            // semi-transparent `tertiaryLabelColor` track without hiding
            // either. Only the hue changes here, from orange to blue; that
            // is what carries the new meaning ("selected, not yet decided")
            // instead of the old one ("about to remove this").
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: startX, y: 0, width: endX - startX,
                                      height: bounds.height)).fill()
        }

        // D50/D56 (M5f Task 6): markers draw as small glyphs confined to
        // their own lane at the top, replacing the old full-height yellow
        // line — a marker is a point in the marker track now, not a streak
        // through video and audio. The marker currently being dragged
        // (`activeMarkerDrag`) draws at its LIVE preview position instead of
        // its stale `jumpPoints` one, so it visibly follows the cursor
        // rather than jumping only once the drag ends.
        for point in markerPoints {
            // A marker whose instant was cut draws hollow rather than solid:
            // it is still there, still draggable and deletable, but it sits on
            // a fold rather than on footage anyone will see.
            if point.isInsideCut {
                NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            } else {
                NSColor.systemYellow.setFill()
            }
            let seconds = (point.id == activeMarkerDrag)
                ? (markerDragPreviewOutputTime ?? point.timeSeconds)
                : point.timeSeconds
            let x = geometry.x(atOutput: OutputTime(seconds))
            NSBezierPath(rect: NSRect(x: x - 3, y: 1, width: 6,
                                      height: max(0, markerTrackHeight - 2))).fill()
        }

        NSColor.labelColor.setFill()
        let playheadX = geometry.x(atOutput: OutputTime(playhead))
        NSBezierPath(rect: NSRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height)).fill()
    }
}
