// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittBrand
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

    /// Double-click in the marker lane where there is no marker: make one
    /// here. Creating a mark after the fact previously meant the chapter
    /// panel's "+" and then typing a time, which is three steps to say
    /// "this moment".
    public var onCreateMarker: (Double) -> Void = { _ in }

    /// Double-click a fold: reveal what it removed AND select it, so the
    /// segment can be acted on rather than merely looked at.
    public var onExpandAndSelectFold: (UUID) -> Void = { _ in }

    /// A fold was clicked: highlight the span it removed.
    public var onSelectFold: (UUID) -> Void = { _ in }

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

    /// Half the width of a selected collapsed cut's wash — wide enough to
    /// read as a band rather than as a thicker line.
    private static let selectionWashHalfWidth: Double = 7.0

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
    /// Where the viewport has been scrolled to, or nil to let the zoom anchor
    /// decide.
    ///
    /// Nil after a zoom on purpose: `zoomed(by:anchoredAt:)` positions the
    /// viewport to keep the anchor under the same pixel, and overriding that
    /// with a stale scroll position would make zooming jump somewhere else.
    /// A deliberate scroll then takes over until the next zoom.
    private var scrollOffsetSeconds: Double?

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

    /// Which cut is selected, mirrored from
    /// `EditorTimelineState.selectedFoldID` exactly as `expandedCutIDs` is.
    /// The view decides nothing about it — it draws it (`FoldPalette`) and
    /// suppresses the ordinary selection rectangle while it is set.
    private var selectedFoldID: UUID?
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
    /// Show a `DisplayState`.
    ///
    /// The one place `DisplayState`'s fields are mapped onto this view's.
    /// `updateNSView` used to spell the fan-out out itself, which meant a
    /// field added to `DisplayState` and not passed here compiled, ran, and
    /// drew the old thing forever — how fold selection stayed invisible for a
    /// milestone.
    func apply(_ display: EditorTimelineState.DisplayState) {
        update(duration: display.duration,
               cuts: display.cuts,
               markerPoints: display.markerPoints,
               playhead: display.playhead,
               selection: display.selection,
               expandedCutIDs: display.expandedCutIDs,
               selectedFoldID: display.selectedFoldID,
               trackStates: display.trackStates,
               waveforms: display.waveforms,
               filmstrip: display.filmstrip)
    }

    public func update(duration: Double, cuts: [Cut], markerPoints: [JumpPoint],
                       playhead: Double, selection: Selection? = nil,
                       expandedCutIDs: Set<UUID> = [],
                       selectedFoldID: UUID? = nil,
                       trackStates: [TrackState] = [],
                       waveforms: [WaveformSamples] = [],
                       filmstrip: FilmstripFrames? = nil) {
        self.duration = duration
        self.cuts = cuts
        self.markerPoints = markerPoints
        self.playhead = playhead
        self.selection = selection
        self.expandedCutIDs = expandedCutIDs
        self.selectedFoldID = selectedFoldID
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
        let zoomed = zoomFactor > Self.minZoomFactor
            ? base.zoomed(by: zoomFactor, anchoredAt: OutputTime(zoomAnchorOutput)) : base
        geometry = scrollOffsetSeconds.map { zoomed.scrolled(to: $0) } ?? zoomed
    }

    // MARK: - Scrolling

    public func scroll(bySeconds delta: Double) {
        scrollOffsetSeconds = geometry.scrollOffset + delta
        rebuildGeometry()
        needsDisplay = true
    }

    /// For a scrollbar: 0 is the start, 1 is as far as it goes.
    public var scrollFraction: Double {
        let maximum = geometry.maximumScrollOffset
        guard maximum > 0 else { return 0 }
        return min(1, max(0, geometry.scrollOffset / maximum))
    }

    public func setScrollFraction(_ fraction: Double) {
        scrollOffsetSeconds = min(max(fraction, 0), 1) * geometry.maximumScrollOffset
        rebuildGeometry()
        needsDisplay = true
    }

    /// Whether there is anything off screen to scroll to.
    public var isScrollable: Bool { geometry.maximumScrollOffset > 0 }
    /// The share of the timeline on screen — a scroll thumb's width.
    public var visibleFraction: Double { geometry.visibleFraction }

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
    /// Centre a fold's label in its band, when it fits.
    ///
    /// Silently draws nothing when the band is too narrow rather than
    /// truncating to an ellipsis: at that width the text would be a smear that
    /// costs the band's colour — which does still say "something was removed
    /// here" — for no information.
    private func drawFoldLabel(_ label: String?, in rect: NSRect) {
        guard let label, !label.isEmpty, rect.width > 40 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Palette.playhead,
            // A shadow, not a backing box: the band is already a colour, and a
            // second rectangle inside it reads as a separate element.
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = .zero
                return shadow
            }(),
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        guard size.width <= rect.width - 8 else { return }
        text.draw(at: NSPoint(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2))
    }

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
    /// 24, not 14. Markers are DRAGGABLE, and WCAG 2.5.8 AA sets 24x24 as the
    /// enforceable minimum for a target — the lane shipped below it, which is
    /// a defect in the app rather than in any redesign. The proportional cap
    /// stays so a very short view still gets a lane rather than one taller
    /// than itself.
    private var markerTrackHeight: Double { min(24.0, bounds.height * 0.4) }


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


    /// One chip per phrase, positioned in OUTPUT time so a cut re-flows them.
    ///
    /// A chip narrower than a couple of points is drawn as a bare tick with no
    /// text: `TranscriptPhrases.displayText` returns "" there rather than an
    /// ellipsis, because an ellipsis alone occupies a chip, reads as text, and
    /// carries none.
    /// How many words the lane is being asked to draw — the input the tier
    /// decision is made from.
    var wordCountForTesting: Int { phrases.reduce(0) { $0 + $1.words.count } }

    /// The tier this lane can honestly draw at its current width (rev 5, W14).
    ///
    /// `WordLaneTiers` decides; this view only asks. The model, its constants
    /// and its monotonicity were built and tested (D89) before this lane
    /// existed — rev 5's spec briefly described re-deriving them, which would
    /// have produced a second answer to a settled question, and a different
    /// one: the spec's stated phrases/density boundary was 4 pt/word against
    /// the shipped `minimumPhraseWidth / wordsPerPhrase` = 11.25.
    var currentTierForTesting: WordLaneTier {
        WordLaneTiers.tier(wordCount: wordCountForTesting, laneWidth: Double(bounds.width))
    }

    private func drawPhrases(in band: NSRect) {
        switch currentTierForTesting {
        case .density: drawWordDensity(in: band)
        case .phrases, .words: drawPhraseChips(in: band)
        }
    }

    /// Where the talking is, when there is no room for words or phrases.
    ///
    /// A 30-minute recording gives this lane a fifth of a point per word.
    /// Chips are not merely small there, they are a lie — you cannot average
    /// two words. What survives downsampling is DENSITY, so that is what the
    /// lane draws: speech reads as glow, silence as nothing, and the lane
    /// stays a map of where to look.
    private func drawWordDensity(in band: NSRect) {
        guard !phrases.isEmpty, band.height > 0 else { return }
        let strip = NSRect(x: 0, y: band.midY - 3, width: bounds.width, height: 6)
        var perColumn = [Int](repeating: 0, count: max(1, Int(bounds.width)))
        for phrase in phrases {
            for word in phrase.words {
                // SOURCE time, mapped through the edit — see `drawPhraseChips`.
                guard let position = geometry.x(atSource: SourceTime(word.start))
                else { continue }
                let x = Int(position)
                guard x >= 0, x < perColumn.count else { continue }
                perColumn[x] += 1
            }
        }
        let busiest = max(1, perColumn.max() ?? 1)
        for (x, count) in perColumn.enumerated() where count > 0 {
            // Ramp from ink3 to signal: a column with one word in it is
            // structure, a column with several is speech.
            let fraction = min(1.0, Double(count) / Double(busiest))
            Palette.chip.blended(withFraction: CGFloat(fraction),
                                 of: Palette.waveform)?.setFill()
            NSBezierPath(rect: NSRect(x: Double(x), y: strip.minY,
                                      width: 1, height: strip.height)).fill()
        }
    }

    private func drawPhraseChips(in band: NSRect) {
        // No band fill. The lane's ground is the timeline's own, so the chips
        // read as objects sitting on the timeline rather than as a fourth
        // stripe competing with the waveforms above them — and silence, which
        // is most of a lane at any real zoom, shows as nothing rather than as
        // an empty box.
        // 11pt and centred. At 9pt, left-aligned against a chip edge, the
        // phrases were unreadable — which made the lane decoration rather than
        // a thing you navigate by, and navigating by what was said is the
        // entire reason it exists.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Palette.playhead.withAlphaComponent(0.85),
            .paragraphStyle: style,
        ]
        for phrase in phrases {
            // SOURCE time, mapped through the edit — NOT `x(atOutput:)`.
            //
            // A transcript's times are facts about the CAPTURE (see
            // `TranscriptPhrase`), and this lane was handing them to the
            // output axis as though they were already trimmed. With no cuts
            // the two clocks agree and it looked right; with any cut the text
            // slid away from the audio it belongs to, by the total length of
            // everything removed before it. The waveform above has always
            // mapped through `keptRanges`, so the two lanes disagreed about
            // the same instant.
            //
            // `x(atSource:)` returns nil for an instant that was cut away —
            // a phrase spoken inside a removed span has no position on the
            // timeline, and drawing it at a clamped edge would put words under
            // audio that never contained them.
            guard let startX = geometry.x(atSource: SourceTime(phrase.start)),
                  let endX = geometry.x(atSource: SourceTime(phrase.end))
            else { continue }
            let width = max(2, endX - startX)
            let chip = NSRect(x: startX, y: band.minY + 3, width: width - 1,
                              height: band.height - 6)
            guard chip.maxX > 0, chip.minX < bounds.width else { continue }
            Palette.chip.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
            let text = TranscriptPhrases.displayText(phrase, widthPoints: Double(width),
                                                     pointsPerCharacter: 7.5)
            guard !text.isEmpty else { continue }
            // Centred on BOTH axes. `draw(in:)` puts text at the rect's top,
            // so a chip taller than its line leaves the words riding the upper
            // edge rather than sitting in the pill.
            let measured = (text as NSString).size(withAttributes: attributes)
            let textRect = NSRect(x: chip.minX + 2,
                                  y: chip.midY - measured.height / 2,
                                  width: max(0, chip.width - 4),
                                  height: measured.height)
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    /// Phrase chips for the transcript lane (D89).
    ///
    /// PHRASES, not words. `WordLaneTiers` measured what a word lane costs:
    /// 0.6pt per word on a ten-minute recording, against the 40pt a chip needs
    /// to be read or clicked — word chips are a deep-zoom feature. Phrases are
    /// the tier that works at ordinary zoom, and a phrase is what someone
    /// wants to jump to anyway.
    private(set) var phrases: [TranscriptPhrase] = []

    public func update(phrases newPhrases: [TranscriptPhrase]) {
        phrases = newPhrases
        needsDisplay = true
    }

    /// The phrase whose chip contains `point`, y-gated to the transcript lane
    /// exactly as the marker lane gates its own.
    func phraseHit(at point: NSPoint) -> TranscriptPhrase? {
        let bands = TimelineTrackLayout.bands(in: bounds, markerHeight: markerTrackHeight,
                                              audioTracks: [], hasTranscript: !phrases.isEmpty)
        guard bands.transcript.height > 0, bands.transcript.contains(point) else { return nil }
        return phrases.first { phrase in
            // The same mapping the chips are DRAWN with. Hit-testing on a
            // different axis than the drawing is this view's oldest defect
            // class, and it is the reason `GestureAxisTests` exists.
            guard let start = geometry.x(atSource: SourceTime(phrase.start)),
                  let end = geometry.x(atSource: SourceTime(phrase.end))
            else { return false }
            return point.x >= start && point.x <= max(end, start + 2)
        }
    }

    /// Seeks to a clicked phrase's START. Returns whether the click was one.
    ///
    /// Split out so `mouseDown` and the tests run the SAME code. A synthetic
    /// `NSEvent` on a windowless view goes through AppKit's window-to-view
    /// conversion, which is what made the fold gate untestable that way; this
    /// is the same lesson applied without waiting to relearn it.
    @discardableResult
    private func handlePhraseClick(at point: NSPoint) -> Bool {
        guard let phrase = phraseHit(at: point) else { return false }
        // The phrase's start, not the click's x. Scrubbing lands the playhead
        // NEAR the phrase, which is what the timeline already did before this
        // lane existed — landing AT it is the whole difference.
        onScrub(phrase.start)
        // And the utterance is SELECTED, so the timeline highlights exactly
        // what Delete (or right-click ▸ Cut Selection) would remove. A phrase
        // is already a span with a start and an end; making a click report it
        // is the difference between a lane you can read and a lane you can
        // edit from.
        //
        // SOURCE time, which is what `phrase.start`/`phrase.end` already are
        // (`drawPhraseChips` maps them through `geometry.x(atSource:)`) and
        // what `Selection.range` means — `mouseUp`'s drag path converts its
        // own output range with `sourceRange(ofOutput:)` for the same reason.
        selection = Selection(range: TimeRange(start: phrase.start, end: phrase.end))
        onSelect(selection)
        // Claims the gesture, exactly as the fold branch does. Without it the
        // trailing `mouseUp` finds nothing active, falls through to the
        // plain-click path, and does two things that undo this one: it calls
        // `onSelect(nil)`, clearing what was just selected, and it scrubs to
        // the MOUSE position — which is the reported "jumps to the start of
        // the phrase, then immediately jumps to the mouse".
        activePhraseClick = true
        needsDisplay = true
        return true
    }

    /// Whether `mouseDown` resolved into a phrase selection.
    ///
    /// The sibling of `activeFoldClick`, and it exists for the identical
    /// reason — see that property. A press that resolves during `mouseDown`
    /// without beginning a gesture has to say so, or `mouseUp` reads it as a
    /// bare click on empty timeline.
    private var activePhraseClick = false

    func phraseHitForTesting(at point: NSPoint) -> TranscriptPhrase? { phraseHit(at: point) }
    @discardableResult
    func handlePhraseClickForTesting(at point: NSPoint) -> Bool { handlePhraseClick(at: point) }

    /// Test seam for the shared, x-only cut hit test.
    func foldHitForTesting(atX x: Double) -> Cut? { foldHit(atX: x) }

    /// How the view would draw `id` right now. The property that matters is
    /// that this reflects what `update` was handed: the model tracked fold
    /// selection correctly for a whole milestone while the view drew every
    /// cut identically, and no test could tell, because every test asked the
    /// model.
    func foldAppearanceForTesting(_ id: UUID) -> FoldPalette.Appearance {
        FoldPalette.appearance(expanded: expandedCutIDs.contains(id),
                               selected: id == selectedFoldID)
    }

    var markerTrackHeightForTesting: Double { markerTrackHeight }

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
        // Hand the viewport back to the anchor: zooming should keep what you
        // were looking at under the cursor, not restore where you had
        // previously scrolled to.
        scrollOffsetSeconds = nil
        rebuildGeometry()
        needsDisplay = true
    }

    /// Step 3's "a control": callable with no mouse event at all (a
    /// keyboard shortcut, see `keyDown`, or code driving this view directly
    /// in a test) — anchored on the PLAYHEAD, per the brief's own wording,
    /// since there is no cursor position to anchor on instead.
    public func zoomIn() { setZoom(zoomFactor * 2, anchoredAtOutput: playhead) }

    /// The zoom, for a continuous control.
    ///
    /// The ±  buttons were the only affordance, and doubling per press means
    /// crossing the useful range takes six clicks in one direction and six
    /// back. A slider is the control this always wanted; these expose the
    /// value it binds to, on a LOG scale, because zoom is multiplicative and a
    /// linear slider would spend most of its travel at the far end.
    public var zoomFraction: Double {
        let span = log2(Self.maxZoomFactor / Self.minZoomFactor)
        guard span > 0 else { return 0 }
        return log2(zoomFactor / Self.minZoomFactor) / span
    }

    public func setZoomFraction(_ fraction: Double) {
        let span = log2(Self.maxZoomFactor / Self.minZoomFactor)
        let factor = Self.minZoomFactor * pow(2, min(max(fraction, 0), 1) * span)
        setZoom(factor, anchoredAtOutput: playhead)
    }

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
        // Horizontal PANS, vertical ZOOMS. Vertical was already the zoom
        // gesture, so the free axis is the one a two-finger swipe sideways
        // means on a timeline anyway.
        //
        // Panning is what zoom was missing: the ± buttons anchor on the
        // playhead, so past 1x the only way to see elsewhere was to move the
        // playhead there — scrubbing blind to find the thing you had zoomed
        // in to look at.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            guard geometry.maximumScrollOffset > 0, geometry.pixelsPerSecond > 0 else { return }
            scroll(bySeconds: -Double(event.scrollingDeltaX) / geometry.pixelsPerSecond)
            return
        }
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

    // MARK: - Accessibility

    /// The timeline is a Core Graphics canvas, so everything drawn on it —
    /// marks, folds, the playhead — is pixels, and pixels have no
    /// accessibility. Nothing here was reachable by VoiceOver or by anyone not
    /// using a pointer, including the marks, which are how you navigate a
    /// Snitt recording.
    ///
    /// Exposed as a group of children rather than one blob of text so the
    /// rotor can STEP between them, which is the interaction that matters:
    /// a single label reciting every mark is a paragraph, not a timeline.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { "Timeline" }

    public override func accessibilityValue() -> Any? {
        TimelineAccessibility.playheadValue(outputSeconds: playhead, duration: duration)
    }

    public override func accessibilityChildren() -> [Any]? {
        accessibilityDescriptors().map { descriptor -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(descriptor.kind == .mark ? .button : .group)
            element.setAccessibilityLabel(descriptor.label)
            element.setAccessibilityParent(self)
            // A frame is what lets VoiceOver's cursor sit on the right part of
            // the view; without one every child reads at the view's origin.
            let x = geometry.x(atOutput: OutputTime(descriptor.outputSeconds))
            element.setAccessibilityFrameInParentSpace(
                NSRect(x: x - 6, y: 0, width: 12, height: bounds.height))
            return element
        }
    }

    /// Split out so the wording and ordering can be asserted without the
    /// accessibility runtime, which a unit test cannot interrogate.
    func accessibilityDescriptors() -> [TimelineAccessibilityElement] {
        TimelineAccessibility.elements(
            marks: markerPoints,
            folds: cuts.map {
                FoldDescriptor(outputSeconds: geometry.timebase.foldPosition(for: $0).seconds,
                               removedSeconds: $0.range.end - $0.range.start)
            })
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
        // Before the fold check and before scrub, for the same reason both of
        // those run before scrub: a chip is a small target and a click that
        // scrubbed instead would land the playhead near the phrase rather than
        // at it, which is the whole difference the lane offers.
        // Double-click first: it is the only gesture that reads the fold's
        // FULL-HEIGHT line rather than the fold lane.
        //
        // The line is drawn `height: bounds.height` on purpose — one collapse
        // across the synchronised stack — but single-click hits are y-gated to
        // the fold lane, because an ungated single click swallows scrubs meant
        // for the lanes below. That left the line visible everywhere and
        // clickable in one strip, which is the regression this restores: a
        // DOUBLE click is unambiguous, since nothing else on the timeline
        // uses one outside the marker lane.
        if event.clickCount == 2 {
            if let cut = foldHit(atX: point.x) {
                onExpandAndSelectFold(cut.id)
                // Claim the gesture, or `mouseUp` undoes it a moment later.
                //
                // Without this the trailing `mouseUp` finds no active fold
                // click, falls through to the plain-click path, and calls
                // `onSelect(nil)` — which clears `selectedFoldID`. On screen
                // the fold highlighted and then deselected itself instantly,
                // so an expanded fold could not be selected at all.
                //
                // The single-click branch below has always done this; the
                // double-click branch returned early and never did. The
                // existing test drove `mouseDown` with `clickCount: 2` and
                // stopped there, so it asserted the selection that IS made
                // and never the `mouseUp` that took it away.
                activeFoldClick = cut.id
                return
            }
            // Empty marker lane only. A double-click ON a marker never
            // reaches here: `mouseDown`'s marker branch runs first and
            // resolves to edit-or-move on `mouseUp`, which already opens the
            // editor. An arm for it here was written and deleted — it was
            // unreachable, and a sweep of every x in the lane finding no hit
            // is what showed it.
            if point.y <= markerTrackHeight, markerHit(at: point) == nil {
                onCreateMarker(geometry.outputTime(atX: point.x).seconds)
                return
            }
        }
        if handlePhraseClick(at: point) { return }
        // A SINGLE CLICK NEVER HITS A CUT (rev 5, W11).
        //
        // Cuts are drawn full height now — they are not a lane — and a
        // full-height hit region with a 6pt margin took every single click
        // within 12pt of a cut, in every lane, away from the lane under the
        // pointer. That was measured rather than assumed: deleting the old
        // y-gate and running `GestureMatrixTests` failed seven assertions,
        // toggling a fold from the marker, video, audio and transcript lanes
        // and killing scrubbing at that x in all of them.
        //
        // So the resolution is a PRIORITY rule rather than a region: the
        // precise gesture yields to the lane, and the coarse ones keep their
        // reach. Double-click still expands and selects a cut from anywhere,
        // right-click still offers Remove Cut from anywhere — both ungated,
        // both already tested — and neither competes with anything, because
        // no lane assigns them a meaning at a cut's x.
        activeFoldClick = nil
        activePhraseClick = false
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
        guard activeFoldClick == nil, !activePhraseClick else { return }
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
        if activePhraseClick {
            // Same rule, same reason — and this branch is the whole of the
            // reported defect: without it the phrase's selection was cleared
            // and the playhead re-seeked to the pointer, both between one
            // press and its own release.
            activePhraseClick = false
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
        contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    /// The context menu for a point in VIEW coordinates.
    ///
    /// Split out for the same reason `handlePhraseClick` was: a synthetic
    /// `NSEvent` on a windowless view exercises AppKit's window-to-view
    /// conversion, not this logic, so a test driving `menu(for:)` cannot tell
    /// a gated hit from an ungated one. A mutant that re-gated this survived
    /// exactly that way.
    func contextMenu(at point: NSPoint) -> NSMenu? {
        // `foldHit(atX:)`, ungated. The fold's line is drawn full height on
        // purpose, and a right-click is unambiguous — nothing else on the
        // timeline claims one. Gating this to the fold lane was collateral
        // damage from stopping ungated LEFT clicks swallowing scrubs, and it
        // silently removed Remove Cut everywhere except one 24pt strip.
        guard let cut = foldHit(atX: point.x) else { return nil }
        // Right-clicking a cut SELECTS it, which is what the rest of the app
        // was already built for and nothing could reach.
        //
        // `FoldPalette` has drawn a `collapsedSelected` appearance since M5f,
        // and `deleteSelection` has removed a selected fold for just as long —
        // but `onSelectFold` was declared, wired to the state, and called by
        // no gesture at all. So a cut LINE could never be selected: the only
        // route in was a double-click, which expands it first, and Delete
        // could therefore never remove a collapsed cut.
        //
        // Right-click is the gesture that fits. W11 ruled a single click must
        // yield to the lane under the pointer, so selecting on left-click is
        // out; a right-click already reaches a fold from anywhere, and
        // selecting the thing you just right-clicked is what every other app
        // does. It also makes the menu act on something visibly chosen rather
        // than on an invisible hit test.
        onSelectFold(cut.id)
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
    /// The waveform's bar rhythm: a bar every `waveformBarStride` points,
    /// `waveformBarWidth` wide, leaving a point of ground between them.
    ///
    /// Drawn as discrete bars rather than as a filled shape, which is what the
    /// design asks for and what every meter looks like — a solid orange mass
    /// says "there is audio" and nothing else, while bars with air between
    /// them read as samples and let the eye follow the envelope. The painter
    /// filled every 1pt column, so at any real width the columns touched and
    /// the lane became a silhouette.
    ///
    /// Nothing is lost by striding: each bar takes the LOUDEST peak in the
    /// span it covers, so a transient between two bars still raises one.
    static let waveformBarStride: Double = 3
    static let waveformBarWidth: Double = 2

    /// Half the thinnest bar the waveform will draw, so the whole bar is a
    /// point tall. Anything present gets at least this; only a span with no
    /// samples at all gets nothing.
    static let minimumWaveformHalfHeight: Double = 0.5

    private func drawWaveform(_ samples: WaveformSamples, in rect: NSRect,
                              muted: Bool, gain: Double) {
        guard !samples.peaks.isEmpty, rect.height > 2 else { return }
        let kept = KeptRanges.compute(duration: duration, cuts: cuts.map(\.range))
        let midY = rect.midY
        let halfHeight = (rect.height - 2) / 2
        let normal = muted ? Palette.waveformMuted : Palette.waveform
        // Clipping stays visible on a muted track: muting is an edit decision,
        // clipping is damage, and hiding the damage because the track is
        // currently silent is how it survives to the export.
        let clipping = Palette.clipping.withAlphaComponent(muted ? 0.5 : 0.9)

        // One pass over the peaks. A column exists only where SAMPLES exist —
        // the guard below is the whole of "no audio data for this segment",
        // and it is the only thing that leaves the lane blank.
        struct Column { let x: Double; let peak: Double; let clipped: Bool }
        var columns: [Column] = []
        var x = 0.0
        while x < bounds.width {
            defer { x += 1 }
            // THE PEAK OVER THE SPAN THIS COLUMN COVERS, not the one sample
            // that happens to land under its left edge.
            //
            // Point-sampling is why the waveform "glitched in and out" while
            // zooming: at any zoom-out a column spans many samples, and
            // whether it drew tall or vanished depended on whether its single
            // sample fell on a peak or in a trough between two syllables.
            // Zoom changed which samples were hit, so the envelope flickered
            // and long stretches of real speech read as silence.
            //
            // Taking the max over the span makes the drawing an ENVELOPE:
            // vertically the same at every zoom.
            let output = geometry.outputTime(atX: x).seconds
            let nextOutput = geometry.outputTime(atX: x + 1).seconds
            guard let start = TimelineSampleIndex.index(
                forOutputSeconds: output, keptRanges: kept,
                samplesPerSecond: samples.samplesPerSecond,
                sampleCount: samples.peaks.count) else { continue }
            // One past the end of the span, clamped by `index` itself. A
            // column narrower than a sample gives start == end, so the range
            // below still reads exactly one value.
            let end = TimelineSampleIndex.index(
                forOutputSeconds: nextOutput, keptRanges: kept,
                samplesPerSecond: samples.samplesPerSecond,
                sampleCount: samples.peaks.count) ?? start
            let span = samples.peaks[min(start, end)...max(start, end)]
            let peak = Double(span.max() ?? 0)
            columns.append(Column(x: x, peak: peak,
                                  clipped: span.contains {
                                      WaveformScale.isClipped(peak: Double($0), gain: gain)
                                  }))
        }
        guard !columns.isEmpty else { return }

        // One bar per stride, carrying the loudest peak it spans.
        var index = 0
        while index < columns.count {
            let stride = Int(Self.waveformBarStride)
            let group = columns[index..<min(index + stride, columns.count)]
            defer { index += stride }
            guard let first = group.first else { break }

            // NOTHING IS DRAWN AS A BASELINE ANY MORE (product-owner
            // direction, 2026-09-11): "minimum 1px unless literally no audio
            // data was received during that segment".
            //
            // W12 drew sub-threshold spans as a slate hairline, arguing that a
            // short bar reads as "quiet audio" while a baseline reads as
            // "nothing here" — a preview of what Auto-Trim would take. In use
            // that is the wrong trade: a quiet passage IS audio, and painting
            // it a different colour at the midline made real speech look like
            // dead space. Blankness now has one honest meaning — no samples
            // for this span — and that is the `continue` above.
            //
            // Auto-Trim is untouched: it still asks
            // `SpeechChunker.silenceThreshold` for what to cut. How this lane
            // paints was never what decided that.
            // The loudest peak in the span, so striding hides no transient —
            // averaging would, which is why this takes a max.
            let loudest = group.filter { _ in true }.max { $0.peak < $1.peak } ?? first
            let clipped = group.contains { $0.clipped }
            (clipped ? clipping : normal).setFill()
            // Logarithmic, and gain-aware: the bar shows what will be
            // exported, not what was captured (`WaveformScale`).
            //
            // A floor of half a point EACH SIDE of the midline, so the
            // thinnest bar this lane can draw is a full point tall. Below
            // that a quiet passage rounds away to nothing on a 1x display and
            // the lane lies about what was recorded.
            let height = max(Self.minimumWaveformHalfHeight,
                             WaveformScale.height(forPeak: loudest.peak, gain: gain) * halfHeight)
            NSBezierPath(rect: NSRect(x: first.x, y: midY - height,
                                      width: Self.waveformBarWidth,
                                      height: height * 2)).fill()
            // A clipped span is marked at the band's edges too, so it is
            // findable when the whole passage is loud and every bar is tall.
            if clipped {
                NSBezierPath(rect: NSRect(x: first.x, y: rect.minY,
                                          width: Self.waveformBarWidth, height: 2)).fill()
                NSBezierPath(rect: NSRect(x: first.x, y: rect.maxY - 2,
                                          width: Self.waveformBarWidth, height: 2)).fill()
            }
        }
    }

    /// Where an output instant is drawn. A test seam, so a test can assert
    /// that drawing and hit-testing agree without reaching into `geometry`.
    func xForTesting(outputSeconds: Double) -> Double {
        geometry.x(atOutput: OutputTime(outputSeconds))
    }

    /// The timeline's own surface colours.
    ///
    /// Explicit greys rather than the semantic `NSColor`s this view used to
    /// fill with, for two reasons.
    ///
    /// The first is a bug. The bands were filled with `tertiaryLabelColor` and
    /// the waveform drawn in `labelColor` — LABEL colours used as BACKGROUND
    /// fills. Label colours invert with the appearance, so in dark mode the
    /// audio band rendered as a pale slab and the waveform, also pale, sank
    /// into it. The band was at its least readable in the appearance the rest
    /// of the window was already using.
    ///
    /// The second is deliberate. A timeline is a dark surface in every editor
    /// that has one, because the content on it — waveforms, thumbnails, cut
    /// marks — is what should carry the colour. So these do not follow the
    /// system appearance in either direction, which is also why the playhead
    /// and separators are spelled out here: on a fixed dark ground, a
    /// `labelColor` playhead would be black-on-black under a light system
    /// theme.
    /// The timeline's surfaces, forwarding to `SnittPalette` (rev 5, W1).
    ///
    /// This enum stays as the timeline's own vocabulary — forty-odd call
    /// sites read `Palette.videoBand` rather than `SnittPalette.ink1`, and
    /// renaming them all would have buried a colour change inside a diff
    /// nobody could review. What changed is where the values come from: a
    /// tuned neutral grey ramp became the app's navy ink ramp, and the
    /// waveform's `NSColor.systemOrange` became brand amber.
    ///
    /// The two tokens that used to live here and no longer do:
    ///
    /// - `markerLane` (`grey(0.26)`) drew two different things — the marks
    ///   band and the transcript's phrase chips. The rev 5 style sheet gives
    ///   each its own answer (marks are transparent on `ink0`; chips are
    ///   `ink2`), so one token cannot serve both and neither call site needs
    ///   a value of its own.
    /// - `audioBandMuted` (`grey(0.155)`) is `ink1`. Its whole job is to sit
    ///   a step below `audioBand`, which `ink1` does; a dedicated token would
    ///   have landed within 0.008 luminance of `ink1` — a distinction no eye
    ///   resolves and one more thing to keep in step.
    enum Palette {
        static let background = SnittPalette.ink0
        static let videoBand = SnittPalette.ink1
        /// Lighter than `background`, so an audio band reads as a band rather
        /// than as the waveform floating on the view's backdrop.
        static let audioBand = SnittPalette.ink2
        /// A muted source draws flatter and darker — the one visible
        /// difference between "this audio is in the export" and "it is not".
        static let audioBandMuted = SnittPalette.ink1
        static let separator = SnittPalette.ink3
        static let playhead = SnittPalette.playheadInk
        static let waveform = SnittPalette.signal
        static let waveformMuted = SnittPalette.signal.withAlphaComponent(0.28)
        /// Word and phrase chips: `ink2`, per the rev 5 style sheet.
        static let chip = SnittPalette.ink2
        /// Marks are time, and time is amber. This was `NSColor.systemYellow`
        /// — a fourth opinion about colour, and the one the eye lands on
        /// first, since a mark is what you are usually looking for.
        static let mark = SnittPalette.signal
        /// Clipping is damage rather than an edit, but it is still red, and
        /// one red is the point: `NSColor.systemRed` beside a brand-red cut
        /// read as two unrelated warnings.
        static let clipping = SnittPalette.recordRed
    }

    public override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
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
                                              audioTracks: tracks,
                                              hasTranscript: !phrases.isEmpty)
        if bands.transcript.height > 0 { drawPhrases(in: bands.transcript) }
        // The marks lane carries no band of its own: the rev 5 style sheet
        // makes it transparent on `ink0`, so what identifies it is its amber
        // ticks and flags, not a shade a hair off the ground behind them.
        Palette.background.setFill()
        NSBezierPath(rect: bands.marker).fill()
        Palette.videoBand.setFill()
        NSBezierPath(rect: bands.video).fill()
        if let filmstrip { drawFilmstrip(filmstrip, in: bands.video) }
        for (track, rect) in bands.audio {
            let muted = trackStates.first { $0.track == track }?.muted ?? false
            (muted ? Palette.audioBandMuted : Palette.audioBand).setFill()
            NSBezierPath(rect: rect).fill()
            if let samples = waveforms.first(where: { $0.track == track }) {
                let gain = trackStates.first { $0.track == track }?.gain ?? 1.0
                drawWaveform(samples, in: rect, muted: muted, gain: gain)
            }
            Palette.separator.setFill()
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
            let foldLook = FoldPalette.appearance(
                expanded: expandedCutIDs.contains(cut.id),
                selected: cut.id == selectedFoldID)
            if expandedCutIDs.contains(cut.id), let span = expansionSpan(for: cut) {
                // Drawn in the space the AXIS reserved, not at `x(atFold:)`.
                // That is the instant the cut collapsed to — after insertion,
                // the band's trailing edge — so drawing from there put the band
                // a full width too far right, over the content that follows,
                // and left the reserved space blank.
                let band = NSRect(x: span.x, y: 0, width: span.width,
                                  height: bounds.height)
                FoldPalette.fill(foldLook).setFill()
                NSBezierPath(rect: band).fill()
                let border = FoldPalette.borderWidth(foldLook)
                if border > 0 {
                    // Two vertical edges, not a stroked rectangle. The band
                    // already spans the full height, so the horizontal halves
                    // of a rectangle border would draw along the very top and
                    // bottom of the whole timeline and say nothing; the edges
                    // are where the removed segment starts and ends, which is
                    // the fact worth marking.
                    //
                    // Filled rather than stroked so a band narrower than two
                    // borders degrades into a solid bar instead of a stroke
                    // straddling its own edge — a sub-second cut at low zoom
                    // is a fraction of a pixel wide, and `insetBy` on that
                    // yields a negative-width rect.
                    FoldPalette.border(foldLook).setFill()
                    NSBezierPath(rect: NSRect(x: band.minX, y: 0, width: border,
                                              height: band.height)).fill()
                    NSBezierPath(rect: NSRect(x: band.maxX - border, y: 0,
                                              width: border,
                                              height: band.height)).fill()
                }
                // The fold's own words, drawn in the space expanding it
                // reserved. Only here: a COLLAPSED fold is two pixels wide and
                // has nowhere to put them, and expanding one is the gesture
                // that says "tell me what was here".
                drawFoldLabel(cut.label, in: NSRect(x: span.x, y: 0,
                                                    width: span.width,
                                                    height: bounds.height))
            } else {
                let width = FoldPalette.lineWidth(foldLook)
                // The armed wash first, so the seam sits on top of it.
                if let wash = FoldPalette.selectionWash(foldLook) {
                    wash.setFill()
                    NSBezierPath(rect: NSRect(x: foldX - Self.selectionWashHalfWidth, y: 0,
                                              width: Self.selectionWashHalfWidth * 2,
                                              height: bounds.height)).fill()
                }
                FoldPalette.fill(foldLook).setFill()
                NSBezierPath(rect: NSRect(x: foldX - width / 2, y: 0,
                                          width: width,
                                          height: bounds.height)).fill()
                // A notch at the top, where the ruler is. A three-point line
                // crossing a busy stack is easy to mistake for a lane
                // boundary; the notch is the bit that says "this is an object,
                // and it is here".
                NSBezierPath(roundedRect: NSRect(x: foldX - 5, y: 0, width: 10, height: 6),
                             xRadius: 2, yRadius: 2).fill()
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
        // A SELECTED FOLD is drawn by `FoldPalette` above, in red, and
        // `selectFold` sets `selection` to the cut's source range alongside
        // `selectedFoldID`. Drawing that range here too would be a second,
        // blue highlight for the same thing — today it renders as nothing
        // (both ends map into removed ground and the draw is skipped), which
        // is luck rather than intent: a cut whose range happens to straddle
        // kept footage would map, and paint a blue band over the red one.
        let selectionX = selectedFoldID != nil ? nil : selection.flatMap { selection -> (Double, Double)? in
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
            // The USER's accent, not a fixed blue (rev 5, W9). §6 keeps
            // selection on the system accent everywhere — it is the one thing
            // on screen that means "you picked this", and that is the colour
            // the rest of their Mac uses for it. `NSColor.systemBlue` looked
            // like the accent on a default install and stopped being it the
            // moment anybody changed theirs.
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
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
                Palette.mark.withAlphaComponent(0.35).setFill()
            } else {
                Palette.mark.setFill()
            }
            let seconds = (point.id == activeMarkerDrag)
                ? (markerDragPreviewOutputTime ?? point.timeSeconds)
                : point.timeSeconds
            let x = geometry.x(atOutput: OutputTime(seconds))
            NSBezierPath(rect: NSRect(x: x - 3, y: 1, width: 6,
                                      height: max(0, markerTrackHeight - 2))).fill()
        }

        Palette.playhead.setFill()
        let playheadX = geometry.x(atOutput: OutputTime(playhead))
        NSBezierPath(rect: NSRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height)).fill()
    }
}

#if DEBUG
// The timeline is where every "correct model, no pixels" defect in this
// project has landed: the filmstrip that never shrank, the fold selection the
// view was never told about, the lane heights that were tuned in a budget the
// renderer did not read. All of them were arithmetic-clean and visibly wrong.
//
// Four previews, chosen as the states that hide bugs from each other: a
// comfortable window, the floor, a selected fold, and a selected fold left
// collapsed.
#Preview("Timeline — comfortable") {
    PreviewFixtures.timeline(size: NSSize(width: 900, height: 200))
}

#Preview("Timeline — at the floor") {
    // Where the lane budget starts collapsing. A stack that looks correct at
    // 200pt and overlaps here has failed the constraint the budget exists for.
    PreviewFixtures.timeline(
        size: NSSize(width: 900,
                     height: TimelineLaneBudget.minimumTimelineHeight))
}

#Preview("Timeline — cut expanded and selected") {
    // Both cuts open. The long one shows the band and its edge bars; the
    // 0.4s one shows what the band degenerates to at this zoom, which is the
    // case a single-cut fixture never reveals.
    PreviewFixtures.timeline(
        size: NSSize(width: 900, height: 200),
        selectedFold: PreviewFixtures.cuts[0].id,
        expanded: Set(PreviewFixtures.cuts.map(\.id)))
}

#Preview("Timeline — cut selected but collapsed") {
    // What a single click in the fold lane leaves behind, and the state
    // Delete acts on. The selected line must be distinguishable from its
    // unselected neighbour — that is the entire content of this preview.
    PreviewFixtures.timeline(
        size: NSSize(width: 900, height: 200),
        selectedFold: PreviewFixtures.cuts[0].id)
}
#endif
