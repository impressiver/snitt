// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Combine
import SnittAutomation
import SnittCapture
import SnittDocument
import SnittExport
import SwiftUI
import UniformTypeIdentifiers

/// Owns the mutable editing state the timeline drives: the EDL a trim
/// appends a cut to, and the events a trim's re-apply must keep passing.
///
/// `PreviewController.apply(edl:events:)`'s `events` is required (M4b
/// whole-branch review, Important finding #3) — passing `[]` recomputes jump
/// points to empty rather than keeping stale ones (stale markers are a
/// silent §9 divergence, an empty scrub bar is a visible one). This type
/// exists so that every trim keeps passing the recording's real events
/// instead of silently losing every marker.
///
/// Not `private`: `@testable import SnittApp` needs to drive `onSelect` /
/// `cutSelection` and read `displayState(playhead:)` directly to verify the
/// M4b Critical finding — that a SECOND trim in one session removes a
/// distinct region — without a live `NSWindow` or SwiftUI's runtime.
@MainActor
final class EditorTimelineState: ObservableObject {
    let controller: PreviewController
    /// Every logged event — markers among them — in SOURCE time. Mutable as
    /// of M5f Task 6 (D56/D50): a marker drag or edit mutates this array and
    /// persists it to `events.json` via `applyAndSaveEvents()`, exactly as
    /// `edl` mutates and persists to `edit.json`. `private(set)`: every
    /// mutation goes through `moveMarker`/`updateMarker` below, which are
    /// what register undo and enqueue the save — a caller reaching in and
    /// assigning this directly would skip both.
    @Published private(set) var events: [LoggedEvent]
    @Published var edl: EditDecisionList

    /// The current selection (SOURCE time), or `nil`. D56 (M5f Task 4): UI
    /// state only — never written into `edl`, never persisted, and this is
    /// the ONLY place it lives; `EditDecisionList` has no field for it.
    /// `@Published` so `EditorContentView`'s Cut button can enable/disable
    /// on it and `TimelineViewRepresentable` can feed it back down to the
    /// view for drawing.
    @Published var selection: Selection?
    /// Shown in the chrome while an agent is driving this window (E10).
    ///
    /// A timed flag rather than a lasting mode, because agent commands arrive
    /// one at a time over IPC and there is no "session" to bracket: an agent
    /// that seeks, trims and exports should read as continuously active, and
    /// one that touched the window a minute ago should not.
    @Published var agentIsDriving = false

    /// Playback ▸ Show Clicks, which lives in `edit.json` — so it is read
    /// from the EDL rather than mirrored beside it. A second copy is how a
    /// checked menu ends up exporting without rings.
    var showClicks: Bool { edl.showClicks }

    /// Click positions as FRACTIONS of the picture, for the playback overlay.
    ///
    /// Empty when clicks are off, and — just as importantly — empty when the
    /// recording has none with coordinates, which is every recording made
    /// before D64. The player attaches no time observer for an empty list, so
    /// an older document costs nothing for a feature it cannot use.
    ///
    /// Derived from `events` and the CURRENT kept ranges, so trimming a cut
    /// that contained a click removes its ring without anything recomputing
    /// explicitly.
    var clickMarks: [ClickMark] {
        guard showClicks else { return [] }
        return ClickOverlay.unitMarks(events: events, keptRanges: controller.keptRanges)
    }

    var showSubtitles: Bool { edl.showSubtitles }
    var showMarkers: Bool { edl.showMarkers }

    /// Captions for the player, empty when the toggle is off or nothing was
    /// transcribed. Derived rather than stored, so a cut re-flows them the
    /// same way it re-flows the click marks.
    var subtitleCues: [SubtitleCue] {
        guard showSubtitles, transcript != nil else { return [] }
        // `audibleWords`, not `transcript.words`. Muting a track takes its
        // audio out of the export, and a caption for audio nobody can hear is
        // a subtitle of silence — the pane and the timeline lane have hidden
        // muted words since narration arrived, and this surface was reading
        // around them.
        return SubtitleCues.cues(words: audibleWords, keptRanges: controller.keptRanges)
    }

    var markerBanners: [MarkerBanner] {
        guard showMarkers else { return [] }
        return MarkerBanners.banners(events: events, keptRanges: controller.keptRanges)
    }
    /// What the toolbar names this document, and how many editable things are
    /// in it. Set by the controller, which is the only thing that knows the
    /// bundle it opened.
    var documentTitle: String = ""
    var documentSubtitle: String {
        let marks = controller.jumpPoints.count
        let folds = edl.cuts.count
        let markWord = marks == 1 ? "marker" : "markers"
        let foldWord = folds == 1 ? "fold" : "folds"
        return "\(marks) \(markWord) · \(folds) \(foldWord)"
    }
    /// Raised by the toolbar's Export button, handled by the controller that
    /// owns the save panel. The state does not present windows.
    /// Raised by the toolbar button AND by File ▸ Export…, so both open the
    /// same sheet rather than the menu keeping a save panel of its own.
    /// Bumped to ask the editor view to raise the export sheet.
    ///
    /// A counter rather than a `Bool` the view sets back to false: resetting a
    /// published flag from inside `onChange` is a write during a view update,
    /// and a flag that stays true swallows the second request. Neither is a
    /// problem a counter has.
    @Published private(set) var exportRequestToken = 0
    func requestExport() { exportRequestToken += 1 }

    /// Wired by the controller, which owns the bundle and the alerts. The
    /// state raises the intent; it does not present windows or write files.
    var onExport: ((ExportRequest) -> Void)?
    var exportOptionsProvider: (() async -> [ExportOption])?

    /// Where an export defaults to: beside the recording, named after it.
    ///
    /// Set by the controller, which is the only thing that knows the bundle it
    /// opened — the same reason `documentTitle` is.
    var defaultExportURL: URL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "export.mp4")

    /// Which folds are currently expanded, by `Cut.id` (D56, M5f Task 5).
    ///
    /// UI state ONLY, exactly like `selection` above: nothing here is ever
    /// written into `edl`, never persisted, and `EditDecisionList`/`Cut`
    /// have no field for it at all. That is the whole point — the dispatch's
    /// first trap. Expanding a fold must not change `Timebase.outputDuration`
    /// or where the playhead maps, and the only way to GUARANTEE that rather
    /// than merely intend it is for the expansion set to live somewhere
    /// `edl`-mutating code (`applyCut`, `restore`, `removeCut` below) never
    /// touches — `toggleExpansion(of:)` is the one place this changes, and it
    /// does not call `applyAndSave()`, so no compositor rebuild, no
    /// `persist`, and no undo registration ever happens for it. Compare
    /// `removeCut(id:)`, which DOES mutate `edl` and goes through exactly
    /// that machinery, because removing a cut is a real edit and expanding
    /// one is only ever a way of looking at it.
    @Published var expandedCutIDs: Set<UUID> = []

    /// The window's `UndoManager` (Task 7), set once the window exists —
    /// this type is constructed before the `NSWindow` that owns it. Task
    /// 1's Edit menu already wires `undo:`/`redo:` to the responder chain;
    /// registering against the window's own manager, rather than a private
    /// one, is what makes those menu items resolve to something instead of
    /// nothing.
    weak var undoManager: UndoManager?
    /// The timeline view, so the on-screen zoom controls can reach it.
    ///
    /// Zoom has existed since M5f Task 8 — `zoomIn()`, `zoomOut()`, scroll and
    /// pinch — but nothing on screen called any of it, so the only ways in were
    /// a trackpad gesture and a keyboard shortcut on a view that has to be
    /// first responder. A feature reachable only by guessing is not reachable.
    weak var timelineView: TimelineView?

    /// The TAIL of the autosave chain: every save awaits the one before it,
    /// so awaiting this one awaits all of them (whole-branch review F2).
    ///
    /// This used to be "the most recent save", overwritten on every trim and
    /// never awaited or cancelled — two trims inside one compositor-build
    /// window ran concurrently, and if the OLDER one's `persist` landed last
    /// the disk kept one cut while the screen showed two. Chaining is what
    /// makes the last write the latest state rather than the slowest task's
    /// state; `EditorPersistenceTests.laterTrimIsNotOverwrittenByAnEarlierSave`
    /// is the test that walks into that inversion deliberately.
    private var pendingSaveTask: Task<Void, Never>?

    /// Saves enqueued but not yet finished. Read at termination (F9): ⌘Q
    /// immediately after a trim must not exit before that trim is on disk.
    private(set) var outstandingSaves = 0

    /// The last EDL that both APPLIED and PERSISTED — the state on disk, and
    /// the state the preview is actually showing. A rejected edit reverts
    /// to this rather than leaving the screen claiming a change that never
    /// reached the file.
    /// Whether any edit has been applied and saved since this window opened.
    ///
    /// Drives the Finder icon's refresh on close. `EditDecisionList` is not
    /// `Equatable`, and making it so would mean conforming `TrackState` too —
    /// a shared type changed for a decoration. A flag set where edits are
    /// already being saved answers the same question without that.
    var editsChangedTheRecording = false

    private var lastSavedEDL: EditDecisionList

    /// The events-side twin of `lastSavedEDL` (Task 6): the last `events`
    /// value that both applied and persisted, for `eventEditWasRejected(_:)`
    /// to revert to.
    private var lastSavedEvents: [LoggedEvent]

    /// Called when the compositor refuses an edit, so the window can tell
    /// the user. A refused trim that merely skips the write still leaves a
    /// silent no-op in front of a person who just dragged across the
    /// timeline (whole-branch review F1).
    var onEditRejected: ((Error) -> Void)?

    init(controller: PreviewController, edl: EditDecisionList, events: [LoggedEvent]) {
        self.controller = controller
        // Every document the editor opens comes through here, whatever the
        // route — a recording that just stopped, File ▸ Open, a Finder
        // double-click, an import. One place, so a document narrated before
        // the lane existed cannot arrive without one.
        self.edl = edl
        self.lastSavedEDL = edl
        self.events = events
        self.lastSavedEvents = events
        loadWaveforms()
        // The capture's tracks and the takes come from DIFFERENT FILES, so one
        // call cannot fetch both. `loadWaveforms` samples `capture.mov`; this
        // samples each take, and without it a document that is opened rather
        // than just recorded draws the microphone as it was captured — showing
        // audio the export has replaced.
        //
        // Both are fired here rather than lazily on first draw: a waveform
        // that appears only after some unrelated redraw is worse than one that
        // takes a moment, because nothing on screen says it is coming.
        loadOverdubWaveforms()
    }

    /// Peak amplitudes per audio track, empty until the read finishes.
    ///
    /// Empty is a legitimate state the timeline draws as a plain band, not an
    /// error: reading every audio sample of a long recording takes real time,
    /// and blocking the editor's first paint on it would be a worse trade than
    /// a waveform that arrives a moment later.
    /// What the timeline draws: the capture's lanes, with every take written
    /// over the microphone. Composed by `rebuildWaveforms` from the two inputs
    /// below rather than mutated in place.
    ///
    /// The inputs are kept separately because they arrive from different files
    /// on different tasks, and a shared array edited by whichever finished
    /// first is exactly the race that shipped once already: a plain assignment
    /// wiped the other's work, so a lane drew or did not depending on which
    /// decode won. Composing from inputs cannot have that failure — each task
    /// sets its own input and asks for a rebuild.
    @Published var waveforms: [WaveformSamples] = []
    /// `capture.mov`'s own lanes, before any take is applied.
    private var capturedWaveforms: [WaveformSamples] = []
    /// One entry per take, by its index in `edl.overdubs`.
    private var takeWaveforms: [Int: WaveformSamples] = [:]
    /// The take being recorded right now, sampled at the playhead's rate.
    private var liveTake: (samples: WaveformSamples, overdub: Overdub)?

    /// Recomposes what the timeline draws.
    ///
    /// Takes are applied in `edl.overdubs` order so a later one overwrites an
    /// earlier one, matching `MicrophoneTimeline`'s precedence exactly — a
    /// lane that disagreed with the audio would be worse than no lane.
    func rebuildWaveforms() {
        var takes: [MicrophoneWaveform.Take] = []
        for (index, overdub) in edl.overdubs.enumerated() {
            guard let samples = takeWaveforms[index] else { continue }
            takes.append(MicrophoneWaveform.Take(overdub: overdub, samples: samples))
        }
        // The in-progress take goes LAST, because it is the most recent thing
        // said and is what the author is listening to.
        if let liveTake {
            takes.append(MicrophoneWaveform.Take(overdub: liveTake.overdub,
                                                 samples: liveTake.samples))
        }
        guard !takes.isEmpty else {
            waveforms = capturedWaveforms
            return
        }
        let duration = controller.sourceDurationSeconds
        // A recording made with the MICROPHONE OFF and spoken over afterwards
        // has no captured microphone lane to write into, so one is created.
        // Without this the take would be in the file, in the mix and in the
        // export, and invisible — which is the shape of the bug D93 shipped
        // with, arriving by a different route.
        //
        // Silent, and the take is written over the silence: that is exactly
        // what the audio does, since there was nothing there before.
        var base = capturedWaveforms
        if !base.contains(where: { $0.track == "microphone" }) {
            let rate = base.first?.samplesPerSecond
                ?? takes.first?.samples.samplesPerSecond
                ?? Self.voiceoverLevelRate
            base.append(WaveformSamples(
                track: "microphone", samplesPerSecond: rate,
                peaks: [Float](repeating: 0, count: Int((duration * rate).rounded(.up)))))
        }
        waveforms = base.map { lane in
            guard lane.track == "microphone" else { return lane }
            return MicrophoneWaveform.overdubbed(lane, takes: takes, sourceDuration: duration)
        }
    }
    /// Whether waveform sampling has FINISHED, regardless of what it found.
    ///
    /// `waveforms.isEmpty` alone cannot tell "this recording has no audio" from
    /// "the audio has not been decoded yet", and those need opposite answers
    /// from `autoDeepTrim`.
    @Published var waveformsLoaded = false

    /// Thumbnails for the video track, empty until decoding finishes — drawn
    /// as a plain band until then, for the same reason as `waveforms`.
    @Published var filmstrip: FilmstripFrames?

    /// Sampled ONCE per document, against the source recording. Cuts and zoom
    /// change which sample a pixel column reads (`TimelineSampleIndex`), never
    /// the samples themselves, so no edit re-triggers this.
    /// The capture's sample, so a test can await it rather than race it.
    private(set) var captureWaveformLoadForTesting: Task<Void, Never>?

    private func loadWaveforms() {
        let url = controller.captureURL
        captureWaveformLoadForTesting = Task { [weak self] in
            let samples = try? await WaveformSampler.sample(movieAt: url)
            await MainActor.run {
                // Sets its OWN input and asks for a rebuild. The version this
                // replaces assigned the shared array, which wiped whatever the
                // take loader had already put there — the bug reported as
                // "there's no waveform, just an empty audio track where there
                // definitely should be audio", and the reason it looked like a
                // load that never happened: on an idle machine the capture
                // finished first and the other survived, under load it did not.
                self?.capturedWaveforms = samples ?? []
                self?.rebuildWaveforms()
                // Set even when the result is empty: a recording with no audio
                // track samples to nothing, and without this flag that is
                // indistinguishable from "still decoding" forever.
                self?.waveformsLoaded = samples != nil
            }
        }
        Task { [weak self] in
            // Separate task from the waveform's: a long audio read must not
            // delay the filmstrip, and vice versa. Whichever finishes first
            // paints first.
            let frames = try? await FilmstripSampler.sample(movieAt: url)
            await MainActor.run { self?.filmstrip = frames }
        }
    }

    /// Everything `TimelineView` needs. `duration`/`cuts`/`selection` stay on
    /// the SOURCE clock because that is the clock they ARE: `edl.cuts` and a
    /// `Selection` destined to become one are source-time ranges, and
    /// `duration` is `capture.mov`'s own length — the INPUT the view builds
    /// its `Timebase` (and therefore its one output-axis `TimelineGeometry`)
    /// from, not an axis it interprets anything against.
    ///
    /// This comment used to say the view's own interaction "must keep
    /// computing against the recording's FULL, unchanging length regardless
    /// of what has already been cut", citing M4b Critical finding #1. The
    /// M5f whole-branch review measured that arrangement and found it
    /// REPRODUCED the finding it cited: a fixed axis makes the same pixels
    /// mean the same source span forever, so a second drag over them cuts
    /// nothing. Interaction is interpreted on the axis being drawn — see
    /// `TimelineView.time(for:)`.
    ///
    /// `jumpPoints`/`playhead`, by contrast, are OUTPUT time, UNCONVERTED
    /// (M5f Task 3): `TimelineGeometry` now draws on the export's own axis
    /// (D56's first requirement — a cut shortens the timeline instead of
    /// leaving a red patch in it), and `controller.player.currentTime()` /
    /// `controller.jumpPoints` are ALREADY exactly that clock —
    /// `CompositionBuilder` only ever builds kept ranges into the
    /// composition. Converting them to source time here, as this method did
    /// before Task 3, was correct while the view drew on the source axis and
    /// is BACKWARDS now that it draws on the output axis: it would hand
    /// `TimelineView` a source-time value for a mapping function that
    /// expects output time, silently landing the playhead and every marker
    /// on the wrong pixel the moment anything has been cut — precisely the
    /// clock confusion this milestone exists to prevent.
    struct DisplayState {
        let duration: Double
        /// WITH identity (M5f Task 5) — `edl.cuts` itself, not
        /// `.map(\.range)`. `TimelineView.foldHit(atX:)` reports a click back
        /// by `Cut.id` (to `onToggleExpansion`/`onRemoveCut`), so the id has
        /// to survive the trip down to the view; a bare `TimeRange` here
        /// would strip exactly the identity the fold UI needs.
        let cuts: [Cut]
        /// The marker TRACK's points — includes markers inside cuts, drawn at
        /// the fold. Not `controller.jumpPoints`, which drops them.
        let markerPoints: [JumpPoint]
        let playhead: Double
        let selection: Selection?
        /// See `expandedCutIDs`'s own doc comment.
        let expandedCutIDs: Set<UUID>
        /// Which cut is selected, so the timeline can DRAW the selection it
        /// has been tracking since M5f. Without this the state was complete
        /// and invisible: `selectFold` also sets `selection`, but a cut's
        /// source range is exactly the ground that cut removed, so neither
        /// end maps onto the output axis and the blue rectangle is skipped.
        let selectedFoldID: UUID?
        /// Which audio sources exist and whether each is muted. The timeline
        /// draws one band per source, so muting has a visible effect — until
        /// now `TrackState.muted` changed the export and nothing on screen.
        let trackStates: [TrackState]
        /// Which of those sources get a LANE, already resolved (D110).
        ///
        /// Carried rather than re-derived by the view: the evidence is
        /// `CaptureHealth` and whether a take is open, neither of which a
        /// timeline view has or should have.
        let audioLanes: [String]
        /// Source-time peaks per track; empty until sampling finishes.
        let waveforms: [WaveformSamples]
        /// Source-time thumbnails; nil until decoding finishes.
        let filmstrip: FilmstripFrames?
    }

    func displayState(playhead outputPlayhead: Double) -> DisplayState {
        DisplayState(duration: controller.sourceDurationSeconds,
                    cuts: edl.cuts,
                    // Derived from `events` — the @Published source of truth —
                    // NOT from `controller.markerTrackPoints`.
                    //
                    // That cache is refreshed inside `applyAndSaveEvents`'s
                    // async task, and `PreviewController` is a plain class with
                    // no @Published anything, so nothing re-renders when it
                    // lands. Dragging a marker mutated `events` synchronously,
                    // SwiftUI re-rendered at once and read the STALE cache, and
                    // the marker snapped back to where it started — until some
                    // unrelated redraw (clicking the timeline) happened to pick
                    // up the new value.
                    //
                    // The same projection the chapter panel uses, for the same
                    // reason: one source, so the lane and the list cannot
                    // disagree.
                    markerPoints: MarkerTrackPoints.compute(
                        events: events, keptRanges: controller.keptRanges),
                    playhead: outputPlayhead,
                    selection: selection,
                    expandedCutIDs: expandedCutIDs,
                    selectedFoldID: selectedFoldID,
                    trackStates: edl.trackStates,
                    audioLanes: audioLaneNames,
                    waveforms: waveforms,
                    filmstrip: filmstrip)
    }

    /// `time` arrives in SOURCE time — the view's own axis — and must be
    /// mapped to TRIMMED time before seeking, since the player plays the
    /// composition built from `keptRanges`, not the source recording.
    ///
    /// A click inside a cut SNAPS to the nearest kept edge rather than
    /// doing nothing. The cut is drawn on the timeline, so it is a visible
    /// thing the user aimed at; swallowing that click with no feedback is
    /// the silent no-op this project keeps finding elsewhere.
    /// Scrubbing STOPS playback (D87). Aiming at a frame while the picture
    /// keeps moving means the frame you aimed at is gone by the time the seek
    /// lands and you look at it — and the playhead then walks away from where
    /// you just put it, which reads as the click having been ignored.
    ///
    /// Every navigation gesture shares this path deliberately — the timeline,
    /// a chapter in the panel, a word in the transcript — because they are the
    /// same act with different targets. `rewind()` is the one that does NOT,
    /// and says why.
    func onScrub(_ time: Double) {
        guard let trimmedTime = TimeRangeMapping.nearestTrimmedTime(
            toSourceTime: time, keptRanges: controller.keptRanges) else { return }
        // A scrub is the user saying where to be, and where they are saying
        // is the new target — not "no target", which is what this used to
        // record and what left navigation reading a stale clock.
        pendingSeekTarget = trimmedTime
        controller.pause()
        Task { await controller.seek(toSeconds: trimmedTime) }
        refreshPlaybackState()
    }

    /// Sends the playhead back to the start.
    ///
    /// Deliberately NOT through `onScrub`, and so deliberately does not pause:
    /// a rewind during playback restarts the run from the top, which is the
    /// replay gesture — the whole reason to press it while watching. A scrub
    /// is aiming at one frame; a rewind is aiming at a beginning.
    ///
    /// Seeks the composition directly rather than mapping through
    /// `keptRanges`: zero in OUTPUT time is the start of the edit whatever is
    /// cut, so there is nothing to resolve.
    func rewind() {
        // Outranks anything already asked for, and is itself a destination:
        // pressing Next straight after a rewind must step from zero, not from
        // wherever the playhead had not yet left.
        pendingSeekTarget = 0
        Task { await controller.seek(toSeconds: 0) }
        // A rewind while watching is a replay, not a stop — so the flag is
        // refreshed rather than cleared, and stays whatever the player is.
        refreshPlaybackState()
    }

    /// One toggle, not two buttons.
    ///
    /// Play and Pause shipped as separate controls, which meant one of them
    /// was always a no-op — press Play while playing and nothing happens, with
    /// no way to tell that from a broken button.
    func togglePlayback() {
        if controller.player.rate == 0 { controller.play() } else { controller.pause() }
        refreshPlaybackState()
    }

    /// Raises the "Agent editing" cue and keeps it up for a few seconds past
    /// the last command, so a burst of verbs reads as one continuous activity
    /// rather than flickering once per call.
    ///
    /// The timer is replaced, not stacked: each command pushes the expiry out.
    func noteAgentActivity() {
        agentIsDriving = true
        agentCueExpiry?.cancel()
        agentCueExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.agentIsDriving = false
        }
    }

    private var agentCueExpiry: Task<Void, Never>?

    /// Unconditional, unlike `togglePlayback`. An agent asking to play wants
    /// the window playing, not flipped: a toggle would make the outcome depend
    /// on a state the agent cannot see, so two identical commands would leave
    /// it stopped.
    func playForAgent() { controller.play() }
    func pauseForAgent() { controller.pause() }

    /// Steps to the previous or next mark (D84).
    ///
    /// Through `onScrub`'s sibling `seek(toOutput:)` rather than a seek of its
    /// own: jump points are already OUTPUT time, and every other navigation
    /// gesture in this editor lands the playhead the same way.
    func goToPreviousMark() {
        guard let point = MarkerNavigation.previous(before: navigationOrigin,
                                                    in: controller.jumpPoints) else { return }
        jump(toMarkAt: point.timeSeconds)
    }

    func goToNextMark() {
        guard let point = MarkerNavigation.next(after: navigationOrigin,
                                                in: controller.jumpPoints) else { return }
        jump(toMarkAt: point.timeSeconds)
    }

    /// Where mark-to-mark navigation reasons FROM.
    ///
    /// **Not the player's clock, while a seek is still in flight.** Every seek
    /// in this editor hands the work to a `Task`, so `player.currentTime()`
    /// still reports the OLD position for a beat afterwards. Navigating in
    /// that beat reads a stale position, finds the same "next" mark again, and
    /// seeks to where it is already going — which on screen is a button press
    /// that did nothing.
    ///
    /// The pending target is dropped as soon as the player reaches it, so
    /// playback moving the head elsewhere takes over immediately rather than
    /// leaving navigation reasoning from a stale intention.
    private var navigationOrigin: Double {
        let decision = MarkerNavigation.origin(live: currentOutputSeconds,
                                               pending: pendingSeekTarget)
        if decision.dropPending { pendingSeekTarget = nil }
        return decision.seconds
    }

    /// Where this editor has asked the playhead to be and not yet seen it
    /// arrive — for ANY deliberate seek, not only a mark jump.
    ///
    /// It used to be armed by `jump(toMarkAt:)` alone, and every other seek
    /// CLEARED it: a scrub, a rewind, a timecode typed into the transport, a
    /// click on a marker row or a transcript word. So navigation was protected
    /// from its own in-flight seek and from nothing else, and pressing Next
    /// straight after any of those reasoned from wherever the player had been
    /// before — reliably finding the mark it was already travelling to, and
    /// looking like a click that did not register.
    ///
    /// Reported after the marker pane started nudging its seek past the marker
    /// (so a stale read now lands on the wrong side of a mark boundary more
    /// often), but the hole is older than that and is not specific to it.
    private var pendingSeekTarget: Double?

    /// Test-only: what the editor believes it is seeking to.
    var pendingSeekTargetForTesting: Double? { pendingSeekTarget }

    private func jump(toMarkAt seconds: Double) {
        // No re-arming here any more: `seek(toOutput:)` records its own
        // destination, so a mark jump is simply a seek like every other.
        seek(toOutput: seconds)
    }

    /// The mark the playhead is inside, for the transport's readout — the
    /// agent-authored label, on screen, without opening the chapters list.
    var currentMarkLabel: String? {
        MarkerNavigation.current(at: currentOutputSeconds,
                                 in: controller.jumpPoints)?.label
    }

    /// Where the playhead is, read from the player rather than cached: the
    /// pane's own `playhead` is a 20Hz sample, and a keypress should act on
    /// where the playhead actually is, not on where it was up to 50ms ago.
    var currentOutputSeconds: Double {
        let seconds = controller.player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    /// `selection` arrives from the view already resolved (SOURCE time): a
    /// real drag becomes `Selection(range:)`, a plain click — or a drag too
    /// short to count — becomes `nil`. D56 (M5f Task 4): this only ever
    /// REPLACES `self.selection`. It never touches `edl` — a drag selects,
    /// it does not cut. `cutSelection()`, below, is the one path from a
    /// selection to an actual `Cut`.
    ///
    /// Before this task, this method was `onTrim(_ range: TimeRange)` and
    /// called `applyCut(range)` directly — a completed drag became a cut
    /// the instant the mouse came up, with no decision in between. That is
    /// the defect D56 names.
    /// Which fold is highlighted, if the selection came from clicking one.
    ///
    /// A range selection and a selected FOLD look the same on screen — both
    /// are a highlighted span — but Delete means opposite things for them: cut
    /// this out, versus put this back. Keeping the distinction explicit is
    /// what lets one key do both without guessing.
    @Published private(set) var selectedFoldID: UUID?

    func onSelect(_ selection: Selection?) {
        // Any ordinary selection clears the fold. Without this, dragging a new
        // range after clicking a fold would leave Delete still meaning "remove
        // that cut" while the highlight showed something else entirely.
        selectedFoldID = nil
        self.selection = selection
    }

    /// Highlights the span a fold removed, so Delete can put it back.
    func selectFold(id: UUID) {
        guard let cut = edl.cuts.first(where: { $0.id == id }) else { return }
        selection = Selection(range: cut.range)
        selectedFoldID = id
    }

    /// What Delete does, and the only place that decides.
    ///
    /// A highlighted fold is a cut you are deciding about — Delete removes it.
    /// A highlighted range is footage you are deciding about — Delete cuts it.
    /// Same key, opposite edits, told apart by how the highlight was made
    /// rather than by a second control.
    func deleteSelection() {
        if let id = selectedFoldID {
            removeCut(id: id)
            selectedFoldID = nil
            selection = nil
        } else {
            cutSelection()
        }
    }

    /// Cuts the current selection, if any — the one place a `Selection`
    /// (UI state, never persisted) turns into a `Cut` (persisted to
    /// `edit.json`), via the same append-and-save `applyCut` a drag used to
    /// call directly before D56 separated the two. Clears the selection
    /// afterwards: once it has become an edit, there is nothing left
    /// selected. A no-op with no selection, rather than force-unwrapping —
    /// pressing Cut with nothing selected is a plausible, harmless mistake,
    /// not a programmer error.
    func cutSelection() {
        guard let selection else { return }
        applyCut(selection.range)
        self.selection = nil
    }

    /// A fold was clicked (`TimelineView.onToggleExpansion`, D56 M5f Task 5):
    /// flips whether `id` is expanded. Deliberately the ONLY thing this
    /// method does — no `applyCut`/`restore`-style undo registration, no
    /// `applyAndSave()`. See `expandedCutIDs`'s doc comment for why that
    /// absence is the whole guarantee: a "plausible wrong implementation"
    /// the dispatch names is one that treats expanding as a temporary
    /// un-cut (restoring the segment, rebuilding the composition, then
    /// re-cutting it on collapse) — that WOULD change `outputDuration` and
    /// briefly make playback stop skipping the span, exactly the leak Task
    /// 5's first trap exists to catch.
    /// Reveal a fold and select what it removed.
    ///
    /// EXPAND, not toggle: the gesture says "show me this", and a double-click
    /// that collapsed an already-open fold would hide the thing being asked
    /// about. Selecting alongside is what makes the segment actionable — you
    /// can see the removed span AND act on it, rather than only look.
    ///
    /// The selection is the cut's SOURCE range, which is the clock `Selection`
    /// and every edit built from it already use.
    func expandAndSelect(foldID id: UUID) {
        guard edl.cuts.contains(where: { $0.id == id }) else { return }
        expandedCutIDs.insert(id)
        selectFold(id: id)
    }

    func toggleExpansion(of id: UUID) {
        if expandedCutIDs.contains(id) {
            expandedCutIDs.remove(id)
        } else {
            expandedCutIDs.insert(id)
        }
    }

    /// Right-click ▸ Remove Cut (D56, M5f Task 5): restores the segment by
    /// deleting exactly the `Cut` named by `id` from `edl.cuts` — output
    /// duration grows by that cut's own length, and nothing else in the EDL
    /// changes. Mirrors `applyCut`'s undo/save shape exactly (a whole-EDL
    /// snapshot registered before the mutation, then `applyAndSave()`),
    /// because removal is a real edit with the same undo/persist
    /// obligations as a cut — it is NOT the same operation as
    /// `toggleExpansion(of:)` above just running backwards.
    ///
    /// A no-op if `id` doesn't name a current cut — a stale fold (already
    /// removed by an earlier right-click, or by an undo that has since
    /// dropped it) offering "Remove Cut" a second time is a plausible,
    /// harmless double-click, not a programmer error, matching
    /// `cutSelection()`'s own no-op-over-force-unwrap stance above.
    func removeCut(id: UUID) {
        guard edl.cuts.contains(where: { $0.id == id }) else { return }
        var updated = edl
        updated.cuts.removeAll { $0.id == id }
        let previous = edl
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        edl = updated
        // The removed cut can no longer be expanded — nothing left to fold.
        expandedCutIDs.remove(id)
        applyAndSave()
    }

    // MARK: - Markers (D50/D56, M5f Task 6)

    /// A marker was dragged to a new position on the timeline.
    ///
    /// `outputTime` arrives in OUTPUT time — the timeline's own drawing
    /// axis (Task 3) — and MUST be converted back to SOURCE time before
    /// it is stored: `events.json` holds source time, the same clock
    /// `edl.cuts` uses, and storing the output value directly would be the
    /// M4b defect wearing a different hat — a marker that moves on screen
    /// and lands at the wrong instant in the file, silently, the moment
    /// anything has been cut. `Timebase.sourceTime(forOutput:)` (Task 3) is
    /// the one place that conversion lives; this is not a second one.
    ///
    /// `Timebase.sourceTime(forOutput:)` can never resolve to an instant
    /// INSIDE a cut — the output timeline has no cuts in it by construction
    /// (see that method's own doc comment) — so a drag can never place a
    /// marker into a cut merely by landing on a pixel; every reachable
    /// output position already names a kept source instant. The opposite
    /// case — a marker that already sits inside a cut before any drag — has
    /// no output position at all, so `TimelineView` never draws it in the
    /// marker track and this method is never reached for it: there is
    /// nothing on screen for a person to grab.
    ///
    /// A no-op if `id` doesn't name a current event (already moved by a
    /// concurrent edit, or the marker was removed) or if `outputTime`
    /// resolves to nothing (everything is currently cut, so there is no
    /// output timeline to land on) — both plausible, harmless races, not
    /// programmer errors, matching `removeCut(id:)`'s own no-op stance.
    func moveMarker(id: UUID, toOutput outputTime: Double) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let timebase = Timebase(sourceDuration: controller.sourceDurationSeconds, edl: edl)
        guard let sourceTime = timebase.sourceTime(forOutput: OutputTime(outputTime))?.seconds else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events[index].timeSeconds = sourceTime
        applyAndSaveEvents()
    }

    /// A marker's label and transcript (D50) were edited. Both are written
    /// together — the one UI that calls this always presents both fields at
    /// once, so there is no partial-edit case to support, and supporting
    /// one independently would risk a caller silently clobbering the other
    /// with a stale value.
    ///
    /// A no-op if `id` doesn't name a current event, matching `moveMarker`
    /// and `removeCut(id:)` above.
    func updateMarker(id: UUID, label: String?, transcript: String?) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events[index].label = label
        events[index].transcript = transcript
        applyAndSaveEvents()
    }

    // MARK: - Automatic trimming (D57)

    /// What the last automatic trim did, for the caption beside the button.
    @Published var lastTrimOutcome: DeepTrimOutcome?

    /// Why an automatic trim found nothing, when it found nothing.
    ///
    /// A button that silently does nothing is indistinguishable from a broken
    /// one, and the two reasons this finds nothing are completely different
    /// problems: "there was no dead air" is a fine outcome, "the recording has
    /// not finished loading its waveform yet" is a wait.
    enum DeepTrimOutcome: Equatable {
        case cut(spans: Int, seconds: Double)
        case nothingToCut
        case notReady
    }

    /// Cuts every span of the recording where nothing happened (D57).
    ///
    /// Runs over the signals the editor has ALREADY decoded for the timeline —
    /// the waveforms, the filmstrip, the event log and the transcript — so this
    /// costs a pass over arrays in memory rather than a second decode of the
    /// movie. D57 called a dedicated decode "a real architectural fork"; this
    /// takes the other branch, and the cost is resolution: the filmstrip is
    /// capped at a few hundred frames, so on a long recording the picture is
    /// sampled every few seconds and only generously-sized dead spans are
    /// detectable. That is the right trade for the feature's actual job, which
    /// is removing the minute someone spent reading documentation, not the
    /// half-second between two clicks.
    ///
    /// The result is ordinary cuts on the shared undo stack — reversible folds
    /// (D56 Tier 1), individually removable — rather than a bulk edit that has
    /// to be accepted whole.
    @discardableResult
    func autoDeepTrim(preset: DeepTrimPreset) -> DeepTrimOutcome {
        func finish(_ outcome: DeepTrimOutcome) -> DeepTrimOutcome {
            lastTrimOutcome = outcome
            return outcome
        }
        guard waveformsLoaded, let filmstrip, !filmstrip.frames.isEmpty else {
            return finish(.notReady)
        }
        // A recording with no audio track is SILENT, not unmeasured — and
        // those are the recordings most likely to have dead air, since a
        // silent screencast is usually an agent's.
        let audio: AudioEvidence = waveforms.isEmpty ? .silentByConstruction
                                                     : .sampled(waveforms)
        let kept = KeptRanges.compute(duration: controller.sourceDurationSeconds,
                                      cuts: edl.cuts.map(\.range))
        let found = AutoDeepTrim.deadSpans(
            duration: controller.sourceDurationSeconds,
            audio: audio,
            frames: FrameActivity.from(filmstrip),
            transcript: transcript,
            events: events,
            criteria: .preset(preset))
        // Anything already removed is not proposed again: re-running this after
        // a trim would otherwise stack a second fold onto material that is
        // already gone, which reads as the button misbehaving.
        let fresh = found.filter { span in
            kept.contains { $0.start < span.end && span.start < $0.end }
        }
        guard !fresh.isEmpty else { return finish(.nothingToCut) }

        let previous = edl
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        edl.cuts.append(contentsOf: fresh.map {
                Cut(range: $0, label: FoldLabel.describe(span: $0, markers: events))
            })
        applyAndSave()
        return finish(.cut(spans: fresh.count,
                           seconds: fresh.reduce(0) { $0 + ($1.end - $1.start) }))
    }

    // MARK: - Chapter index (the marker pane)

    /// The markers as a chapter list, in the order they occur.
    ///
    /// Derived rather than stored: `events` is the single source of truth for
    /// markers, and a parallel list would be one more thing to keep in step
    /// with cuts, undo, and the timeline lane — which all already read
    /// `events`.
    ///
    /// Built on `MarkerTrackPoints` — the SAME projection the timeline lane
    /// draws — rather than re-deriving the source-to-output arithmetic here.
    /// `MarkerJumpPoints.swift` warns in its own comment that "a chapter list
    /// and a scrub bar that disagree about the same recording are worse than
    /// either alone"; two implementations of one projection is how they come
    /// to disagree. This one shares the lane's, so the panel and the lane
    /// cannot drift.
    ///
    /// `MarkerTrackPoints` rather than `MarkerJumpPoints` because the latter
    /// DROPS markers inside cuts. That is right for a bare seek list and wrong
    /// here: a marker vanishing from the index because a nearby cut swallowed
    /// it looks like data loss, when the marker is still in `events.json` and
    /// moving the cut brings it back. Kept, folded to the cut's edge, and
    /// labelled as such.
    var chapters: [MarkerChapter] {
        // Whether a label is the user's or the fallback — `JumpPoint.label`
        // has already applied "Marker" by the time it arrives, so the
        // distinction has to come from the event itself.
        var custom: [UUID: String] = [:]
        for event in events where event.kind == .marker {
            if let label = event.label, !label.isEmpty { custom[event.id] = label }
        }
        return MarkerTrackPoints.compute(events: events, keptRanges: controller.keptRanges)
            .enumerated()
            .map { index, point in
                MarkerChapter(
                    id: point.id,
                    outputTime: point.timeSeconds,
                    isInsideCut: point.isInsideCut,
                    label: custom[point.id] ?? "Marker \(index + 1)",
                    hasCustomLabel: custom[point.id] != nil,
                    transcript: point.transcript)
            }
    }

    /// Which chapter the playhead is inside.
    ///
    /// A chapter runs until the NEXT one starts — that is what makes this an
    /// index rather than a list of instants. Highlighting only while the
    /// playhead sits exactly on a marker would mean nothing is ever
    /// highlighted, since a marker has no duration.
    func currentChapterID(atOutputSeconds outputSeconds: Double) -> UUID? {
        var current: UUID?
        for chapter in chapters {
            // A small tolerance so seeking TO a chapter highlights it rather
            // than landing a hair before its own start.
            if chapter.outputTime <= outputSeconds + 0.01 { current = chapter.id } else { break }
        }
        return current
    }

    /// Drops a marker at the playhead.
    ///
    /// Until now markers could only be created while recording, which means a
    /// recording made by an agent — or by anyone who did not think to press
    /// the key at the right moment — could never be chaptered at all.
    func addMarker(atOutput outputTime: Double) {
        let timebase = Timebase(sourceDuration: controller.sourceDurationSeconds, edl: edl)
        guard let sourceTime = timebase.sourceTime(forOutput: OutputTime(outputTime))?.seconds
        else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events.append(LoggedEvent(timeSeconds: sourceTime, kind: .marker))
        // Kept in time order for the same reason `Recorder` sorts before
        // writing: every consumer reads this array as a timeline.
        events.sort { $0.timeSeconds < $1.timeSeconds }
        applyAndSaveEvents()
    }

    /// Removes a marker. Undoable on the same stack as every other edit.
    func deleteMarker(id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }),
              events[index].kind == .marker else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events.remove(at: index)
        applyAndSaveEvents()
    }

    /// Renames a marker, keeping its transcript.
    ///
    /// Goes through `updateMarker` rather than writing `label` directly,
    /// because that method's whole contract is that both fields are written
    /// together — a rename that passed `transcript: nil` would silently
    /// destroy narration text the sheet had set.
    func renameMarker(id: UUID, to label: String) {
        guard let event = events.first(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMarker(id: id, label: trimmed.isEmpty ? nil : trimmed,
                     transcript: event.transcript)
    }

    /// One chapter edit — the time and the label together — as a single
    /// mutation.
    ///
    /// Deliberately NOT `moveMarker` followed by `renameMarker`. Undo is not
    /// the reason: `UndoManager.groupsByEvent` is on by default, so two
    /// registrations in one run-loop pass collapse into one ⌘Z anyway (a first
    /// version of this claimed otherwise and its test passed against both
    /// implementations, which is how the claim was caught). The reasons are
    /// that two calls write `events.json` twice for one edit, and that between
    /// them `events` is published with the new time and the OLD name — a state
    /// the user never typed, rendered by every view watching the array. This
    /// assigns once, so there is no such frame.
    ///
    /// A `timeText` that does not parse leaves the time alone rather than
    /// moving the chapter to zero — a half-typed "1:" is a person still
    /// typing, not a request to jump to the start. A time past the end is
    /// clamped rather than ignored, matching a drag, which cannot go past the
    /// end because there is no timeline there to drop on.
    ///
    /// A no-op if `id` doesn't name a current event, matching `moveMarker`.
    func applyChapterEdit(id: UUID, timeText: String, label: String) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let timebase = Timebase(sourceDuration: controller.sourceDurationSeconds, edl: edl)
        var newSource: Double?
        if let typed = MarkerPane.parseTimestamp(timeText) {
            let clamped = min(max(typed, 0), timebase.outputDuration)
            newSource = timebase.sourceTime(forOutput: OutputTime(clamped))?.seconds
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        // One assignment, not two: `events` is @Published, and mutating two
        // fields in place publishes twice — the second of which is the only
        // one anybody should see.
        var updated = events
        if let newSource { updated[index].timeSeconds = newSource }
        updated[index].label = trimmed.isEmpty ? nil : trimmed
        events = updated
        applyAndSaveEvents()
    }

    /// Seeks the preview to a chapter. Through `onScrub` for the same reason
    /// `seek(toWord:)` is: it is the one path that keeps the timeline playhead
    /// and the panes agreeing about where playback is.
    /// Put the playhead at an OUTPUT instant.
    ///
    /// **Not through `onScrub`**, which is the bug this replaced. `onScrub`
    /// takes SOURCE time and converts it with
    /// `TimeRangeMapping.nearestTrimmedTime(toSourceTime:)`; handing it a time
    /// that was already output ran that conversion a second time, so every
    /// caller landed EARLY by the total length of everything cut before the
    /// target. With no cuts the two clocks agree and it looked correct.
    ///
    /// Everything that calls this passes output time — mark navigation, a
    /// marker row in the rail (`chapter.outputTime`), a timecode typed into
    /// the transport — so all three drifted the moment a recording had a cut
    /// in it, and drifted further the more was removed. "Next marker doesn't
    /// line up with the actual markers" is what that looks like from the
    /// outside, because the markers are DRAWN at `x(atOutput:)` and only the
    /// jump was being converted.
    ///
    /// Seeks the composition directly, exactly as `rewind()` does and for the
    /// same stated reason: the composition's clock IS output time.
    /// Seeks so a marker's BANNER is on screen, not merely so the playhead is
    /// at the marker (D51).
    ///
    /// The distinction is the whole of the fix: `MarkerBanners.appearance`
    /// returns opacity 0 at a banner's own moment, because that is the first
    /// frame of its arrival, so "click a marker in the pane and see it" landed
    /// on the one instant in its window where there is nothing to see.
    ///
    /// Reads `markerBanners`, which is empty whenever Show Markers is off — so
    /// with the preview off this is exactly `seek(toOutput:)`, and the playhead
    /// still lands precisely on the marker.
    func seekToMarker(atOutput seconds: Double) {
        seek(toOutput: MarkerBanners.previewTime(forMarkerAt: seconds, in: markerBanners))
    }

    func seek(toOutput seconds: Double) {
        // The destination is RECORDED, not cleared. This is the one line the
        // reported defect turned on: navigation reads `pendingSeekTarget` when
        // the player's clock has not caught up yet, and a nil here sent it back
        // to that stale clock.
        pendingSeekTarget = seconds
        controller.pause()
        Task { await controller.seek(toSeconds: seconds) }
        refreshPlaybackState()
    }

    /// The events-side twin of `restore(_:)`: pushes the CURRENT `events`
    /// back onto the undo stack as the redo before installing `snapshot`, so
    /// marker undo/redo is multi-level exactly like cut undo/redo.
    private func restoreEvents(_ snapshot: [LoggedEvent]) {
        let current = events
        undoManager?.registerUndo(withTarget: self) { $0.restoreEvents(current) }
        events = snapshot
        applyAndSaveEvents()
    }

    /// The marker-edit sibling of `applyAndSave()`: persists `events.json`
    /// only, WITHOUT rebuilding the composition. A marker's own position,
    /// label or transcript changes nothing `CompositionBuilder` builds —
    /// only `edl.cuts` does — so this calls `controller.refreshJumpPoints`
    /// directly instead of the full `apply(edl:events:)` rebuild `cuts` need.
    ///
    /// Chained onto the SAME `pendingSaveTask` `applyAndSave()` uses, not a
    /// second, parallel chain: F2's "last write is the latest state" and
    /// F9's "⌘Q waits for every outstanding save" both need to hold for a
    /// marker edit exactly as they do for a cut, and two independent chains
    /// could let a cut and a marker edit race each other onto disk.
    private func applyAndSaveEvents() {
        let events = self.events
        let controller = self.controller
        let previousSave = pendingSaveTask
        outstandingSaves += 1
        pendingSaveTask = Task { @MainActor [weak self] in
            await previousSave?.value
            do {
                try controller.persistEvents(events)
                controller.refreshJumpPoints(events: events)
                self?.lastSavedEvents = events
            } catch {
                self?.eventEditWasRejected(error)
            }
            self?.outstandingSaves -= 1
        }
    }

    /// The events-side twin of `editWasRejected(_:)`: reverts to the last
    /// events value that IS on disk and reuses the same alert path — a
    /// marker write failing (disk full, permissions) deserves the same
    /// visible refusal a rejected cut gets, not a silently reverted marker.
    private func eventEditWasRejected(_ error: Error) {
        events = lastSavedEvents
        lastSaveError = error
        onEditRejected?(error)
    }

    /// Appends `range` and registers its inverse as a whole-EDL snapshot,
    /// not an inverse operation (Task 7 ruling): a stack of whole-value
    /// restores is multi-level by construction and cannot drift from the
    /// applied state the way a stack of inverse ops can.
    private func applyCut(_ range: TimeRange) {
        let previous = edl
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        // Cutting a selection is always a brand-new cut — it has no
        // established identity to preserve, so it mints its own id here.
        edl.cuts.append(Cut(range: range))
        applyAndSave()
    }

    /// Whether narration is being recorded right now (D93).
    /// The over-dub transport's state (D102). Everything about what the two
    /// buttons do lives in `OverdubTransport`; this holds the answer.
    @Published private(set) var overdubState: OverdubTransport.State = .idle
    /// The count-in's timer, kept so cancelling actually stops it.
    private var countInTimer: Timer?
    /// The runs this take has been recorded in, closed off by each pause.
    private var takeRuns: [OverdubPlacement.TakeRun] = []
    /// The level index each run began at, for the LIVE lane. Level readings
    /// and the recorder's own elapsed time are different clocks, and the live
    /// lane can only count the former — the file cannot be decoded while it is
    /// still being written.
    private var takeLevelStarts: [Int] = []
    /// How much audio was in the file when the current run began.
    private var takeFileOffset: Double = 0
    /// Swapped in tests so a count-in can be counted rather than heard.
    var countInTick = CountInTick()

    @Published private(set) var isRecordingVoiceover = false
    /// Levels captured so far in the current take, for the lane drawn while it
    /// runs. Empty when nothing is recording.
    @Published private(set) var voiceoverLevels: [Float] = []
    /// The timeline's zoom, mirrored so the slider re-renders when a scroll or
    /// a pinch changes it.
    ///
    /// The control used to read `timelineView.zoomFraction` directly, which is
    /// a plain property on an `NSView` and publishes nothing — so the slider
    /// followed the ± keys (they route through SwiftUI) and ignored the mouse.
    /// It only looked right during playback, where the 20Hz playhead poll was
    /// re-rendering the transport anyway.
    @Published var timelineZoomFraction: Double = 0
    /// Where in OUTPUT time the current take began, so the live lane knows
    /// where to start drawing.
    @Published private(set) var voiceoverStartedAt: Double = 0
    private let voiceoverRecorder = VoiceoverRecorder()

    /// Samples the finished voiceover and adds it as a third lane.
    ///
    /// Re-indexed onto the CAPTURE's clock by `VoiceoverWaveform`, because
    /// `TimelineView.drawWaveform` maps every pixel column through
    /// `KeptRanges` into source seconds — drawn unmapped, narration recorded
    /// over source 30 would appear at the start of the recording.
    /// The in-flight sample, so a test can AWAIT it rather than poll for it.
    ///
    /// Polling was tried and does not work here: the first version waited four
    /// seconds, passed alone, and timed out on the full run; twenty seconds
    /// timed out too. Whatever the contention is, a longer wait is a worse
    /// test, not a passing one — and "assert the loader was called" would be
    /// the adjacent-property trap this project keeps finding. Awaiting the
    /// actual work keeps the assertion on the actual outcome.
    private(set) var overdubWaveformLoad: Task<Void, Never>?
    /// Why a take is missing from the microphone lane, when one is.
    private(set) var overdubWaveformFailure: String?

    func loadOverdubWaveforms() {
        guard !edl.overdubs.isEmpty else { return }
        let bundle = controller.snittBundle.url
        let takes = edl.overdubs.enumerated().map {
            ($0.offset, bundle.appendingPathComponent($0.element.filename))
        }
        overdubWaveformLoad = Task { [weak self] in
            for (index, url) in takes {
                var sampled: [WaveformSamples] = []
                var failure: String?
                do { sampled = try await WaveformSampler.sample(movieAt: url) }
                catch { failure = (error as NSError).localizedDescription }
                guard let first = sampled.first else {
                    // Recorded rather than swallowed. A `try?` here made "the
                    // take could not be read" and "there is no take" the same
                    // flat lane, which is the difference between a transient
                    // failure worth retrying and nothing to draw.
                    await MainActor.run {
                        self?.overdubWaveformFailure =
                            failure ?? "no audio track in \(url.lastPathComponent)"
                    }
                    continue
                }
                await MainActor.run {
                    // Keyed by index rather than appended, so re-reading a
                    // take replaces its own entry instead of adding a second.
                    self?.takeWaveforms[index] = first
                    self?.rebuildWaveforms()
                }
            }
        }
    }

    /// Levels are taken at the playhead's rate, so this IS that rate.
    static let voiceoverLevelRate: Double = 20

    /// Takes one level reading and redraws the lane, on the playhead's tick.
    ///
    /// The live lane is an ordinary `WaveformSamples` named "voiceover",
    /// source-aligned exactly like the finished one — so `TimelineView` draws
    /// it with the code it already has, through the same cuts and the same
    /// zoom. Nothing in the timeline knows a take is running.
    func sampleVoiceoverLevel() {
        // `isCapturingAudio`, not `isRecordingVoiceover`. A PAUSED take is
        // still open — the button is lit and the file is waiting — so the
        // older guard kept the meter running with the recorder stopped: the
        // levels went on accumulating and the lane drew a take that was
        // getting longer while nothing was being recorded.
        guard overdubState.isCapturingAudio else { return }
        voiceoverRecorder.sampleLevel()
        voiceoverLevels = voiceoverRecorder.levels
        guard !voiceoverLevels.isEmpty else { return }

        let duration = Double(voiceoverLevels.count) / Self.voiceoverLevelRate
        // Placed from the RUNS, so a take that was paused and carried on draws
        // in the two places it was spoken rather than as one block from where
        // it first started.
        let runs = OverdubPlacement.liveRuns(
            outputStarts: takeRuns.map(\.outputStart),
            levelStarts: takeLevelStarts,
            levelCount: voiceoverLevels.count,
            levelsPerSecond: Self.voiceoverLevelRate)
        let live = Overdub(
            filename: "",
            durationSeconds: duration,
            segments: runs.isEmpty
                ? OverdubPlacement.segments(outputStart: voiceoverStartedAt,
                                            duration: duration,
                                            keptRanges: controller.keptRanges)
                : OverdubPlacement.segments(runs: runs, keptRanges: controller.keptRanges))
        liveTake = (WaveformSamples(track: "microphone",
                                    samplesPerSecond: Self.voiceoverLevelRate,
                                    peaks: voiceoverLevels),
                    live)
        rebuildWaveforms()
    }

    /// Starts narrating over the edit, from the playhead.
    ///
    /// Playback is STARTED, not left paused. A voiceover is spoken against
    /// what is on screen, and narrating over a still frame produces narration
    /// anchored to one instant — which the placement model would then spread
    /// across whatever footage happened to follow it.
    func startVoiceover() -> VoiceoverRecorder.StartFailure? {
        let start = currentOutputSeconds
        // The filename is chosen HERE, because the recorder needs somewhere to
        // write before anyone knows whether the take will be worth keeping. A
        // UUID rather than a position in the list: takes can be deleted, and a
        // name derived from an index stops matching the list the moment one is.
        let filename = controller.snittBundle.overdubFilename()
        if let failure = voiceoverRecorder.start(
            writingTo: controller.snittBundle.overdubURL(filename: filename),
            fromOutputSeconds: start) {
            return failure
        }
        pendingOverdubFilename = filename
        isRecordingVoiceover = true
        voiceoverLevels = []
        voiceoverStartedAt = start
        // No TrackState is added any more. A take lands on the MICROPHONE
        // (D102), which already has one — the lane it draws into is the lane
        // that was always there, and the live waveform is what distinguishes
        // recording from playing.
        controller.play()
        return nil
    }

    /// Where the take in progress is being written. Held from start to stop
    /// because the recorder is told the path and the document is told the
    /// name, and those are two different moments.
    private var pendingOverdubFilename: String?

    /// Ends the take and writes it into the EDL.
    ///
    /// The whole-EDL snapshot undo every other edit uses, so narration is as
    /// undoable as a cut — and because the audio file is left on disk, an undo
    /// followed by a redo does not have to re-record anything.
    func stopVoiceover(runs: [OverdubPlacement.TakeRun] = []) {
        guard let duration = voiceoverRecorder.stop() else { return }
        isRecordingVoiceover = false
        voiceoverLevels = []
        controller.pause()
        guard duration > 0.05 else {
            // A take shorter than a syllable is a mis-click, not speech.
            // Recorded as nothing rather than as a span nobody can hear — and
            // the live lane goes with it, or the microphone would keep drawing
            // a take the document does not have.
            liveTake = nil
            rebuildWaveforms()
            return
        }
        let previous = edl
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        // Resolved to SOURCE spans HERE, once, against the edit that was in
        // force while it was spoken. Re-deriving later would need that edit,
        // which the document does not keep — see `Overdub.segments`.
        // From the RUNS when the take was paused and carried on, and from the
        // single start when it was not. One arithmetic either way — the
        // multi-run form delegates to the single-run one — so a paused take
        // and an unpaused one cannot be placed by two different rules.
        let segments: [OverdubSegment]
        if runs.count > 1 {
            // The last run's length is whatever the file has beyond the runs
            // already closed off, which is the only number the recorder can
            // still be asked for after it has stopped.
            var closed = runs
            let accounted = closed.dropLast().reduce(0) { $0 + $1.durationSeconds }
            closed[closed.count - 1].durationSeconds = max(0, duration - accounted)
            segments = OverdubPlacement.segments(runs: closed,
                                                 keptRanges: controller.keptRanges)
        } else {
            segments = OverdubPlacement.segments(
                outputStart: voiceoverRecorder.startedAtOutput,
                duration: duration,
                keptRanges: controller.keptRanges)
        }
        // APPENDED, so punching in twice keeps both takes and the later one
        // wins only where they actually overlap. Replacing the list would make
        // a second correction throw away the first, which is the opposite of
        // what recording again means.
        edl.overdubs.append(Overdub(
            filename: pendingOverdubFilename ?? controller.snittBundle.overdubFilename(),
            durationSeconds: duration,
            segments: segments))
        pendingOverdubFilename = nil
        let recorded = edl.overdubs[edl.overdubs.count - 1]
        liveTake = nil
        applyAndSave()
        loadOverdubWaveforms()
        transcribeNewTake(recorded)
    }

    /// Re-transcribes a take the moment it is recorded (D102).
    ///
    /// Without this the transcript is a lie the instant a take lands: it still
    /// shows what the CAPTURED microphone said over those seconds — audio the
    /// export has replaced — and none of what was just said instead. That is
    /// worse than being out of date, because the words on screen are
    /// specifically the ones the take exists to get rid of.
    ///
    /// **Only when the recording already has a transcript.** Transcription is
    /// consent-gated (§4.10: ask at first USE), so a document nobody has
    /// transcribed must not be pushed through the Speech grant because a take
    /// happened to be recorded. Having a transcript IS the opt-in, and this
    /// keeps it true rather than creating one.
    ///
    /// Only the NEW take is recognised, and it merges against a list holding
    /// only that take — so the words dropped are exactly the ones under it.
    /// Passing every take would re-drop earlier takes' words, which are
    /// already in the transcript and indistinguishable from captured ones.
    private func transcribeNewTake(_ overdub: Overdub) {
        guard Transcriber.shouldAutoTranscribeTake(
            hasTranscript: transcript != nil,
            availability: Transcriber.availability()) else { return }

        let bundle = controller.snittBundle
        transcriptionStatus = .transcribing
        Task { [weak self] in
            let words = (try? await Transcriber.transcribeOverdub(
                bundle: bundle, overdub: overdub)) ?? []
            await MainActor.run {
                guard let self, let current = self.transcript else { return }
                // A SECOND undo step, deliberately. The take's own undo
                // restores the EDL; this restores the transcript. Folding them
                // into one would mean an undo registered before the words
                // existed — the recogniser finishes long after the take does —
                // and the alternative, leaving the words behind on undo, keeps
                // a transcript of audio the document no longer has.
                self.undoManager?.registerUndo(withTarget: self) {
                    $0.restoreTranscript(current)
                }
                let merged = Transcriber.merging(overdub, words: words, into: current)
                if let merged { self.transcript = merged }
                self.transcriptionStatus = .ready
                self.applyAndSaveTranscript()
            }
        }
    }

    /// Applies a crop drawn over the preview.
    ///
    /// `sub` is expressed in the coordinates of the frame CURRENTLY on screen,
    /// which is already cropped if a crop exists — so it composes rather than
    /// replaces (`CropRect.composing`). Undo goes through the same whole-EDL
    /// snapshot `cutSelection` uses, so a crop is as undoable as a cut and the
    /// two interleave on one stack.
    func applyCrop(_ sub: CropRect) {
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.crop = (edl.crop ?? .full).composing(sub)
        applyAndSave()
    }

    // MARK: - Transcript (D62)

    enum TranscriptionStatus: Equatable {
        /// No transcript and no way to make one (no mic track, or unsupported).
        case none
        /// Available but the user has not been asked for the Speech grant yet —
        /// §4.10: ask at first USE, so the pane shows a button, not a dialog.
        case needsPermission
        case transcribing
        case ready
        case failed(String)
    }

    @Published var transcript: Transcript?

    /// The transcript minus anything on a muted track.
    ///
    /// A muted track is not in the exported file, so its speech is not in the
    /// recording anyone will watch — and a transcript still showing it invites
    /// editing against something that is not there: cutting a phrase to remove
    /// speech already silenced, or reading narration nobody will hear as part
    /// of the piece.
    ///
    /// Every surface reads THIS rather than `transcript.words`, so the pane,
    /// the timeline lane and anything added later cannot disagree about what
    /// is audible.
    var audibleWords: [TranscriptWord] {
        AudibleTranscript.audible(transcript?.words ?? [], trackStates: edl.trackStates)
    }

    /// Whether this recording has narration anybody can hear.
    ///
    /// Derived from `audibleWords` rather than from `trackStates`, so muting
    /// the voiceover puts the pane back to its single-voice appearance instead
    /// of leaving a lane rule on every row marking a distinction that no
    /// longer exists on screen.
    var hasNarration: Bool {
        audibleWords.contains(where: AudibleTranscript.isVoiceover)
    }
    @Published var transcriptionStatus: TranscriptionStatus = .none

    /// Words currently removed by the EDL, for striking through.
    ///
    /// Derived, never stored on the word: the EDL is the single source of what
    /// is cut, so undoing a cut un-strikes the words with no bookkeeping.
    var cutWordIDs: Set<UUID> {
        guard let transcript else { return [] }
        return TranscriptEditing.cutWordIDs(in: transcript, cuts: edl.cuts)
    }

    /// Loads transcript.json if the bundle has one. Separated from
    /// `beginTranscriptionIfNeeded` so tests can exercise the load/edit path
    /// without the TCC-gated recognizer anywhere near them.
    func loadTranscript() {
        guard let existing = try? Transcript.read(from: controller.snittBundle) else { return }
        transcript = existing
        lastSavedTranscript = existing
        transcriptionStatus = .ready
    }

    /// Kicks off transcription when there is no transcript yet and the
    /// recognizer is usable. Called by the window controller after the editor
    /// opens — deliberately NOT from init, so the test host never constructs a
    /// recognizer as a side effect of making a state.
    func beginTranscriptionIfNeeded() {
        guard transcript == nil, transcriptionStatus == .none else { return }
        switch Transcriber.availability() {
        case .unsupported, .denied: transcriptionStatus = .none
        case .notYetRequested: transcriptionStatus = .needsPermission
        case .available: startTranscription()
        }
    }

    /// The §4.10 rung: the user clicked "Transcribe", so NOW the dialog has a
    /// visible cause.
    func requestTranscriptionPermission() {
        Task { [weak self] in
            let granted = await Transcriber.requestAuthorization()
            await MainActor.run {
                guard let self else { return }
                if granted { self.startTranscription() } else { self.transcriptionStatus = .none }
            }
        }
    }

    /// The terms the recogniser is told to expect (D81), as the pane edits them.
    ///
    /// Comma or newline separated, because that is how somebody pastes a list
    /// of symbol names. Loaded from the recording so the field shows what the
    /// current transcript was actually made with, not a blank box.
    @Published var vocabularyText: String = ""

    /// Whether the "write a line of narration" field is showing, and what is
    /// in it.
    ///
    /// ON THE MODEL, not in the pane, and that is a bug fix rather than a
    /// preference. The `+` is drawn in the accordion's HEADER, which means
    /// `TranscriptPane.addButton` is produced from a pane value that is never
    /// itself installed as a view — only the `Button` it returns is. Writing
    /// `@State` from there goes to storage nothing observes, so the button
    /// looked correct, ran its action, and did nothing at all.
    ///
    /// `MarkerPane.addButton` has always worked for exactly this reason: it
    /// calls a method on this object rather than touching view-local state.
    /// `vocabularyText` above is the same shape — a draft string that lives
    /// here because more than one place needs it.
    @Published var isWritingNarration = false
    @Published var narrationDraft = ""

    /// Opens the narration field. A method rather than a setter so the two
    /// properties cannot drift apart: a field showing yesterday's half-typed
    /// line is worse than one that starts empty.
    func beginWritingNarration() {
        narrationDraft = ""
        isWritingNarration = true
    }

    func cancelWritingNarration() {
        narrationDraft = ""
        isWritingNarration = false
    }

    /// Commits the draft, and reports whether it took.
    ///
    /// Leaves the field OPEN when it did not. The only ways to fail are an
    /// empty line or a playhead sitting inside a cut, and both are worth
    /// seeing rather than having the text silently swallowed.
    @discardableResult
    func commitWrittenNarration(atOutput output: Double) -> Bool {
        guard addNarration(narrationDraft, atOutput: output) else { return false }
        narrationDraft = ""
        isWritingNarration = false
        return true
    }

    /// Testing seam: install a transcript without running the recogniser,
    /// which is TCC-gated and absent on a machine that has not granted it.
    func setTranscriptForTesting(_ value: Transcript) {
        transcript = value
        lastSavedTranscript = value
        transcriptionStatus = .ready
    }

    /// Load the recording's stored vocabulary into the editable field.
    func loadVocabulary() {
        let stored = (try? RecordingMetadata.read(from: controller.snittBundle))?.vocabulary
        vocabularyText = (stored ?? []).joined(separator: ", ")
    }

    /// Transcribe again, with whatever the field now says.
    ///
    /// Replaces the transcript outright, which DISCARDS in-place corrections
    /// (D62) — a corrected word is only marked by `confidence == 1.0`, which a
    /// confident recognition also produces, so there is no way to tell them
    /// apart and preserve one. Undo is the answer instead: the old transcript
    /// goes on the shared stack before the new one lands, so ⌘Z brings the
    /// corrections back. The pane says so before the button is pressed.
    func retranscribe() {
        let terms = Vocabulary.prepare(
            vocabularyText.split(whereSeparator: { $0 == "," || $0.isNewline })
                .map(String.init)).terms
        // Persisted BEFORE transcribing, so a re-transcription that crashes or
        // is closed mid-run still leaves the recording knowing what it was
        // asked to expect.
        if var meta = try? RecordingMetadata.read(from: controller.snittBundle) {
            meta.vocabulary = terms.isEmpty ? nil : terms
            try? meta.write(to: controller.snittBundle)
        }
        if let current = transcript {
            undoManager?.registerUndo(withTarget: self) { $0.restoreTranscript(current) }
        }
        startTranscription(vocabulary: terms)
    }

    private func startTranscription(vocabulary: [String]? = nil) {
        transcriptionStatus = .transcribing
        let bundle = controller.snittBundle
        let overdubs = edl.overdubs
        Task { [weak self] in
            do {
                let spoken = try await Transcriber.transcribe(
                    bundle: bundle, vocabulary: vocabulary)
                // ONE PASS PER TAKE, over its own file. The capture and each
                // take are different audio recorded at different times, so one
                // analyzer cannot be given them together — they merge after.
                //
                // Run even when the capture pass found nothing: a recording
                // made with the mic off and spoken over afterwards has a
                // transcript consisting entirely of takes, and gating this on
                // the first result would leave it empty.
                var takeWords: [TranscriptWord] = []
                for overdub in overdubs {
                    takeWords += try await Transcriber.transcribeOverdub(
                        bundle: bundle, overdub: overdub, vocabulary: vocabulary)
                }
                guard let result = Transcriber.merge(spoken, overdubs: overdubs,
                                                     takeWords: takeWords) else {
                    // No mic track and no takes — a normal recording, not a
                    // failure.
                    await MainActor.run { self?.transcriptionStatus = .none }
                    return
                }
                try result.write(to: bundle)
                await MainActor.run {
                    self?.transcript = result
                    self?.lastSavedTranscript = result
                    self?.transcriptionStatus = .ready
                }
            } catch {
                await MainActor.run {
                    self?.transcriptionStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// The word being spoken at `outputSeconds`, for playback highlighting.
    ///
    /// Derived on demand rather than stored: the playhead moves ten times a
    /// second and the answer is a pure function of it, so caching would add a
    /// second source of truth for something already cheap to compute.
    func currentWordID(atOutputSeconds outputSeconds: Double) -> UUID? {
        guard let transcript else { return nil }
        return TranscriptPlayhead.currentWordID(outputSeconds: outputSeconds,
                                                words: transcript.words,
                                                keptRanges: controller.keptRanges)
    }

    /// Whether the preview is actually playing, so the transcript follows only
    /// then — auto-scrolling while someone is reading and selecting would drag
    /// the text out from under them.
    /// Whether the player is running, PUBLISHED rather than computed.
    ///
    /// It was `controller.player.rate != 0`, read during a render — and the
    /// only thing causing renders was the playhead changing on the 20Hz tick.
    /// So when playback ran off the end, the rate dropped to zero, the
    /// playhead stopped moving, nothing re-rendered, and the transport kept
    /// showing Pause over a stopped player. The button was right until the
    /// moment it mattered.
    ///
    /// A value the tick pushes in is not the "cached flag" the old comment
    /// warned about. That warning was about a flag set when somebody pressed
    /// play, which goes stale because nothing tells it the player stopped.
    /// This is told, twenty times a second.
    @Published private(set) var isPlaying = false

    /// Where playback is, in OUTPUT seconds — for the commands that act at the
    /// playhead without a view to ask.
    var outputPlayhead: Double {
        let seconds = controller.player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    /// Follows the player's rate. Takes the rate rather than reading it, so
    /// the rule — non-zero means playing — is testable without a player that
    /// can be made to run on demand.
    ///
    /// Guarded, because `@Published` notifies on every assignment: an
    /// unguarded write would re-render the whole editor twenty times a second
    /// while nothing was happening.
    func updatePlayback(rate: Float) {
        let playing = rate != 0
        if isPlaying != playing { isPlaying = playing }
    }

    /// Reads the flag off the player it belongs to.
    ///
    /// Called from every method here that starts or stops playback, so the
    /// flag is right IMMEDIATELY rather than within one tick — the tick is the
    /// backstop for the change nothing here causes, which is the player
    /// running off the end of the recording. That was the whole bug: nothing
    /// in this file tells you playback finished.
    func refreshPlaybackState() { updatePlayback(rate: controller.player.rate) }

    /// Whether a written line has anywhere to go — the transcript pane's own
    /// gate, so Edit ▸ Add Narration and the pane's `+` cannot disagree.
    var acceptsWrittenNarration: Bool {
        TranscriptPanePresentation.decide(
            status: transcriptionStatus,
            hasTranscript: transcript != nil,
            wordCount: transcript?.words.count ?? 0).acceptsWrittenNarration
    }

    /// One press of zoom in (+1) or out (-1).
    ///
    /// A sixth of the range per press, which is what makes the slider's own
    /// doc comment true: "the ± buttons double per press, so crossing the
    /// range takes six clicks each way".
    static let zoomStep = 1.0 / 6.0

    func zoomTimeline(by direction: Double) {
        let target = min(1, max(0, timelineZoomFraction + direction * Self.zoomStep))
        timelineView?.setZoomFraction(target)
        timelineZoomFraction = target
    }

    /// Corrects one recognized word's text (D62 second slice).
    ///
    /// Text only — the timing is untouched, because the word WAS said at that
    /// instant; only the spelling was wrong. Changing timing here would move
    /// cut spans out from under existing edits.
    ///
    /// Confidence becomes 1.0: a human typed this, so the doubt-dimming the
    /// recognizer earned no longer applies. That also makes "which words did I
    /// fix" visible — corrected words render at full opacity.
    ///
    /// Empty or whitespace text is a NO-OP, not a removal: removing a word
    /// from the transcript is not an operation that exists — deleting what was
    /// SAID is `deleteWords`, which cuts the footage. A transcript word with
    /// no footage behind it would be a lie about the recording.
    func correctWord(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var current = transcript,
              let index = current.words.firstIndex(where: { $0.id == id }),
              current.words[index].text != trimmed else { return }

        let snapshot = current
        undoManager?.registerUndo(withTarget: self) { $0.restoreTranscript(snapshot) }
        current.words[index].text = trimmed
        current.words[index].confidence = 1.0
        transcript = current
        applyAndSaveTranscript()
    }

    /// The transcript's twin of `restore(_:)`: whole-value snapshots, so undo
    /// is multi-level by construction and redo falls out of registering the
    /// current value on the way back.
    private func restoreTranscript(_ snapshot: Transcript) {
        guard let current = transcript else { return }
        undoManager?.registerUndo(withTarget: self) { $0.restoreTranscript(current) }
        transcript = snapshot
        applyAndSaveTranscript()
    }

    /// Chained onto the same save queue as EDL and event writes, so the three
    /// sidecars cannot interleave their failure handling — and a failed write
    /// reverts to the last value that IS on disk, exactly as event edits do.
    private func applyAndSaveTranscript() {
        guard let transcript else { return }
        let controller = self.controller
        let previousSave = pendingSaveTask
        outstandingSaves += 1
        pendingSaveTask = Task { @MainActor [weak self] in
            await previousSave?.value
            do {
                try transcript.write(to: controller.snittBundle)
                self?.lastSavedTranscript = transcript
            } catch {
                self?.transcriptEditWasRejected(error)
            }
            self?.outstandingSaves -= 1
        }
    }

    private var lastSavedTranscript: Transcript?

    private func transcriptEditWasRejected(_ error: Error) {
        transcript = lastSavedTranscript
        lastSaveError = error
        onEditRejected?(error)
    }

    /// Writes a line of narration at the playhead (D100).
    ///
    /// SOURCE time, converted from the output time the playhead reads in,
    /// because every word in a transcript is in source time and a phrase
    /// anchored in output time would move whenever a cut above it changed.
    ///
    /// Returns whether anything was added, so a caller can keep its draft on
    /// screen when it was not.
    @discardableResult
    func addNarration(_ text: String, atOutput output: Double) -> Bool {
        guard let source = TimeRangeMapping.sourceTime(ofTrimmedTime: output,
                                                       keptRanges: controller.keptRanges)
        else { return false }
        let words = AuthoredNarration.words(text, sourceStart: source)
        guard !words.isEmpty else { return false }

        // A transcript may not exist yet: writing narration is the one way to
        // get one without running the recogniser, and refusing here would mean
        // a recording with no speech could never be given any.
        let current = transcript ?? Transcript(words: [], locale: Locale.current.identifier)
        undoManager?.registerUndo(withTarget: self) { [hadTranscript = transcript != nil] target in
            hadTranscript ? target.restoreTranscript(current) : target.discardTranscript()
        }
        var updated = current
        updated.words = AuthoredNarration.inserting(words, into: current.words)
        transcript = updated
        applyAndSaveTranscript()
        return true
    }

    /// Undo for the first authored line in a recording that had no transcript.
    ///
    /// `restoreTranscript` cannot express this: it puts back a VALUE, and the
    /// value being restored here is the absence of one. Without it, undoing
    /// the first line leaves an empty transcript behind — which reads as "the
    /// recogniser ran and heard nothing", a different and discouraging claim.
    private func discardTranscript() {
        guard let current = transcript else { return }
        undoManager?.registerUndo(withTarget: self) { $0.restoreTranscript(current) }
        transcript = nil
        try? FileManager.default.removeItem(at: controller.snittBundle.transcriptURL)
        lastSavedTranscript = nil
    }

    /// Deletes words: their spans become cuts on the SAME EDL every other edit
    /// uses (D62's payoff). Undoable through the same whole-EDL snapshot as
    /// cuts, crop and gain, so a text deletion and a drag-cut interleave on one
    /// stack.
    ///
    /// AUTHORED lines are removed from the transcript instead, because cutting
    /// is the wrong verb for them. The way to unsay something somebody said is
    /// to remove the seconds in which they said it; a written line has no
    /// seconds behind it, so cutting there would delete whatever footage the
    /// script happened to be anchored over — video the user never asked to
    /// lose, at a moment they were only using as a bookmark.
    ///
    /// A mixed selection does both, each to its own words, rather than
    /// refusing: a selection dragged across a written line and a spoken one is
    /// an ordinary thing to do and has an obvious meaning.
    func deleteWords(ids: Set<UUID>) {
        guard let transcript else { return }
        let selected = transcript.words.filter { ids.contains($0.id) }
        let authored = selected.filter(\.isAuthored)
        let spoken = selected.filter { !$0.isAuthored }

        if !authored.isEmpty {
            let removing = Set(authored.map(\.id))
            let snapshot = transcript
            undoManager?.registerUndo(withTarget: self) { $0.restoreTranscript(snapshot) }
            var updated = transcript
            updated.words.removeAll { removing.contains($0.id) }
            self.transcript = updated
            applyAndSaveTranscript()
        }

        // Computed against the ORIGINAL transcript, so removing an authored
        // line in the same gesture cannot shift the spans of the spoken words
        // beside it.
        let ranges = TranscriptEditing.cutRanges(removing: spoken, from: transcript)
        guard !ranges.isEmpty else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.cuts.append(contentsOf: ranges.map { Cut(range: $0) })
        applyAndSave()
    }

    /// Seeks the preview to where a word is spoken. Through `onScrub`, which
    /// already maps source time to the trimmed timeline and snaps a click
    /// inside a cut to the nearest kept edge.
    func seek(toWord word: TranscriptWord) { onScrub(word.start) }

    // MARK: - The over-dub transport (D102)

    /// The record button.
    func tapRecord() { apply(OverdubTransport.next(overdubState, .tapRecord)) }

    /// Play/pause, which means something different while a take is open.
    ///
    /// Returns whether the transport handled it. When it did not, the caller
    /// does its ordinary play/pause — this machine has no opinion about a
    /// transport that is not recording, and duplicating the toggle here would
    /// be a second answer to a question already answered.
    @discardableResult
    func tapPlayPause() -> Bool {
        guard overdubState != .idle else { return false }
        apply(OverdubTransport.next(overdubState, .tapPlayPause))
        return true
    }

    private func apply(_ step: OverdubTransport.Step) {
        overdubState = step.state

        if step.playTick { countInTick.play() }
        if case .countingIn = step.state { scheduleCountInBeat() } else { cancelCountIn() }

        if step.startRecording { beginTake() }
        if step.pauseRecording { closeCurrentRun() }
        if step.resumeRecording { openNewRun() }
        if step.stopRecording { finishTake() }
        if step.play { controller.play() }
        if step.pause { controller.pause() }
        updatePreviewMixForTake()
    }

    /// Silences the captured microphone for the length of a take.
    ///
    /// Driven from the transport state rather than toggled at start and stop,
    /// so a pause restores it and a resume takes it away again with no second
    /// place to keep in step.
    private func updatePreviewMixForTake() {
        let sounding = overdubState.isCapturingAudio ? edl.silencingMicrophone() : edl
        Task { [weak self] in
            // `try?`: the mix is a recording comfort, and failing to build one
            // must not stop a take. The worst case is hearing what you
            // recorded over, which is the behaviour this replaces.
            try? await self?.controller.applyAudioMix(edl: sounding)
        }
    }

    private func scheduleCountInBeat() {
        cancelCountIn()
        countInTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.apply(OverdubTransport.next(self.overdubState, .countInBeat))
            }
        }
    }

    private func cancelCountIn() {
        countInTimer?.invalidate()
        countInTimer = nil
    }

    /// Drives one count-in beat without waiting a second, for tests.
    func countInBeatForTesting() {
        apply(OverdubTransport.next(overdubState, .countInBeat))
    }

    /// Why the last take could not start, when it could not.
    ///
    /// Surfaced rather than discarded. `startVoiceover` returns a failure —
    /// a refused microphone, a recorder AVFoundation would not create — and
    /// throwing it away left the transport sitting in `.recording` with a lit
    /// button and nothing being written, which is indistinguishable from the
    /// bug this shipped with.
    @Published private(set) var overdubStartFailure: VoiceoverRecorder.StartFailure?

    private func beginTake() {
        takeRuns = []
        takeFileOffset = 0
        overdubStartFailure = startVoiceover()
        guard overdubStartFailure == nil else {
            // Back to idle, because nothing is recording. A transport that
            // stayed armed would promise a take that cannot exist.
            overdubState = .idle
            return
        }
        takeRuns.append(OverdubPlacement.TakeRun(outputStart: voiceoverStartedAt,
                                                 durationSeconds: 0))
        takeLevelStarts = [0]
    }

    /// Closes the run that was running, using the recorder's own count of what
    /// it has written rather than a wall clock.
    private func closeCurrentRun() {
        guard let elapsed = voiceoverRecorder.pause(), !takeRuns.isEmpty else { return }
        takeRuns[takeRuns.count - 1].durationSeconds = elapsed - takeFileOffset
        takeFileOffset = elapsed
    }

    private func openNewRun() {
        guard voiceoverRecorder.resume() else { return }
        // A NEW run at wherever the playhead is now. Resuming usually carries
        // on from the same instant, but nothing stops somebody scrubbing while
        // paused — and a take that assumed otherwise would place everything
        // after the pause over the wrong footage.
        takeRuns.append(OverdubPlacement.TakeRun(outputStart: currentOutputSeconds,
                                                 durationSeconds: 0))
        takeLevelStarts.append(voiceoverLevels.count)
    }

    private func finishTake() {
        // NOT `closeCurrentRun()` first. That pauses the recorder, and a
        // paused `AVAudioRecorder` reports a `currentTime` of 0 — so stopping
        // straight afterwards read the take as zero seconds long and the
        // mis-click guard threw it away. `stopVoiceover` fills in the last
        // run's length from the finished file, which is the only number that
        // is right whether the take was paused or not.
        stopVoiceover(runs: takeRuns)
        takeRuns = []
        takeLevelStarts = []
        takeFileOffset = 0
    }

    /// Sets one audio track's gain (M5f follow-on; `TrackState.gain` has
    /// existed and been applied by the export mix since M3 with no way to set
    /// it).
    ///
    /// Clamped at 0 and at 4x. Zero is mute-by-slider, which is legitimate;
    /// negative gain inverts phase, which is never what a slider drag meant.
    /// The ceiling is where a quiet recording can be rescued without the
    /// waveform becoming a solid block of clipping.
    func setGain(track: String, gain: Double) {
        let clamped = min(max(gain, 0), 4)
        guard let index = edl.trackStates.firstIndex(where: { $0.track == track }),
              edl.trackStates[index].gain != clamped else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.trackStates[index].gain = clamped
        // `rebuild: false` — gain touches nothing but the audio mix, and a
        // rebuild would replace the player's item and send the playhead back
        // to zero on every slider tick.
        applyAndSave(.audioMixOnly)
    }

    /// Mutes or unmutes one audio track.
    func setMuted(track: String, muted: Bool) {
        guard let index = edl.trackStates.firstIndex(where: { $0.track == track }),
              edl.trackStates[index].muted != muted else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.trackStates[index].muted = muted
        applyAndSave(.audioMixOnly)
    }

    /// The audio tracks this recording actually has, in draw order — the same
    /// derivation the timeline uses, so the controls and the bands cannot
    /// disagree about which sources exist.
    var audioTracks: [TrackState] {
        audioLaneNames.compactMap { name in
            edl.trackStates.first { $0.track == name }
        }
    }

    /// The ONE derivation of which audio lanes this recording has (D110).
    ///
    /// Everything that counts lanes reads this: the bands the timeline draws,
    /// the rows the gutter puts a mute and a gain slider on, and the height
    /// budget that divides the timeline between them. They used to each call
    /// `TimelineTrackLayout.audioTracks(in:)` with whatever they had to hand,
    /// which is three chances to disagree about how many rows exist — and a
    /// gutter one row taller than the bands beside it is a control wired to
    /// nothing.
    var audioLaneNames: [String] {
        AudioTrackOrder.recorded(in: edl.trackStates,
                                 health: captureHealth,
                                 // A take that is still OPEN counts. It is
                                 // being written to the microphone right now,
                                 // and a lane that appeared only once the take
                                 // was committed would hide the recording
                                 // while it was being made.
                                 overdubbed: edl.hasOverdubs || overdubState != .idle)
    }

    /// What the capture measured, or `nil` for a bundle that predates
    /// `CaptureHealth` and for an imported video.
    ///
    /// Read once, from `loadCaptureHealth()`, rather than computed: this
    /// decides how many lanes are drawn, and `draw` runs on every scrub.
    private(set) var captureHealth: CaptureHealth?

    /// Reads `meta.json`'s health, if it has any.
    ///
    /// Called by the controller after `init`, exactly as `loadTranscript()`
    /// is and for the same reason — a state built by a test must not do file
    /// I/O as a side effect of existing. A state that never loads it keeps
    /// every lane, which is the pre-D110 behaviour.
    func loadCaptureHealth() {
        captureHealth = (try? RecordingMetadata.read(from: controller.snittBundle))?.health
    }

    /// Removes the crop entirely. Distinct from cropping to the full frame only
    /// in what reaches disk — `nil` writes no `crop` key at all.
    func resetCrop() {
        guard edl.crop != nil else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.crop = nil
        applyAndSave()
    }

    /// Restores a prior whole-EDL snapshot and pushes the CURRENT state back
    /// onto the undo stack as the redo — this is what makes undo/redo
    /// multi-level rather than a single toggle between two states.
    private func restore(_ snapshot: EditDecisionList) {
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl = snapshot
        applyAndSave()
    }

    /// Rebuilds the preview and persists ONLY IF that rebuild succeeded
    /// (Task 7 ordering, corrected by whole-branch review F1).
    ///
    /// The previous spelling was `try? await apply` followed by an
    /// unconditional `try? persist`, under a comment claiming the ordering
    /// protected the document. It did not: ordering alone accomplishes
    /// nothing, only GATING does. `CompositionBuilder` throws
    /// `everythingCut` for a drag across the whole timeline, that EDL was
    /// written anyway, and `DocumentOpener.open` then threw `everythingCut`
    /// forever — D45's own defect ("a `.snitt` could be written and never
    /// reopened") reintroduced by D46's autosave, reachable by one gesture.
    ///
    /// Each save is chained onto the previous one (F2) rather than racing
    /// it, so the last write is the latest state and never the slowest
    /// task's stale one.
    /// Waits for any in-flight save.
    ///
    /// The icon refresh on close reads `edit.json` back from disk, so it has
    /// to run after the save that produced it — otherwise it composes a poster
    /// from the EDL as it was BEFORE the user's last edit.
    func awaitPendingSave() async { await pendingSaveTask?.value }

    /// - Parameter rebuild: whether the change needs a NEW composition. True
    ///   for anything that moves material — cuts, folds, crop, scale. False
    ///   for mute and gain, which are expressed entirely in the audio mix:
    ///   rebuilding for those calls `replaceCurrentItem`, which resets the
    ///   playhead, so adjusting gain while listening to a passage sent you
    ///   back to the start. Everything else about the save is identical,
    ///   including the serialization against the previous save — a gain
    ///   change and a cut both write the whole `edit.json`, so they must not
    ///   race each other.
    /// How much of the pipeline an edit actually needs.
    ///
    /// Was a `rebuild: Bool`, which had no way to say "the composition did not
    /// change at all". Show Clicks is the first edit of that kind: it changes
    /// what is drawn OVER the video, never the video, so rebuilding — or even
    /// re-applying the audio mix, which interrupts playback — would be work the
    /// user can see for no reason.
    enum EDLApplication {
        case rebuild
        case audioMixOnly
        case saveOnly
    }

    /// Playback ▸ Show Clicks, for this document.
    ///
    /// `.saveOnly`: the flag changes what is drawn OVER the video, never the
    /// video, so neither a rebuild nor an audio-mix re-apply is warranted —
    /// both would interrupt playback to change nothing about it.
    func setShowClicks(_ enabled: Bool) {
        guard edl.showClicks != enabled else { return }
        edl.showClicks = enabled
        applyAndSave(.saveOnly)
    }

    func setShowSubtitles(_ enabled: Bool) {
        guard edl.showSubtitles != enabled else { return }
        edl.showSubtitles = enabled
        applyAndSave(.saveOnly)
    }

    func setShowMarkers(_ enabled: Bool) {
        guard edl.showMarkers != enabled else { return }
        edl.showMarkers = enabled
        applyAndSave(.saveOnly)
    }

    private func applyAndSave(_ application: EDLApplication = .rebuild) {
        // Marked here, synchronously, NOT inside the save task below. The EDL
        // has already changed by the time this is called, and a user who cuts
        // and immediately closes the window would otherwise race the save: the
        // close reads this flag, finds it still false, and the icon keeps
        // showing material the recording no longer has. Cutting the dead end
        // off a take and closing straight away is a completely ordinary thing
        // to do.
        editsChangedTheRecording = true
        let edl = self.edl
        let events = self.events
        let controller = self.controller
        let previousSave = pendingSaveTask
        outstandingSaves += 1
        pendingSaveTask = Task { @MainActor [weak self] in
            await previousSave?.value
            do {
                switch application {
                case .rebuild:
                    try await controller.apply(edl: edl, events: events)
                case .audioMixOnly:
                    try await controller.applyAudioMix(edl: edl)
                case .saveOnly:
                    break
                }
                try controller.persist(edl)
                self?.lastSavedEDL = edl
            } catch {
                self?.editWasRejected(error)
            }
            self?.outstandingSaves -= 1
        }
    }

    /// The compositor refused this edit, so nothing was written — put the
    /// editor back on the state that IS on disk and say so.
    ///
    /// No re-apply is needed: `PreviewController.apply` builds before it
    /// touches the player, so a build that threw has changed nothing and
    /// the preview is still showing `lastSavedEDL`. Reverting `edl` is what
    /// makes the timeline agree with it again.
    ///
    /// The undo entry the refused gesture registered is deliberately left
    /// on the stack: `UndoManager` has no way to pop one, and clearing the
    /// stack would throw away the user's real history to tidy up a failed
    /// edit. It restores the state we have just reverted to, so pressing
    /// ⌘Z once after a refusal is a no-op rather than a surprise.
    private func editWasRejected(_ error: Error) {
        edl = lastSavedEDL
        // Recorded BEFORE the callback, so `applyFromAgent` sees it whether or
        // not anything is listening. `onEditRejected` is the person's path and
        // is nil in a headless host.
        lastSaveError = error
        onEditRejected?(error)
    }

    // MARK: - Agent control (D109)

    /// The last save error, so an agent's edit can be told it failed.
    ///
    /// Route's third precondition. A person's refused edit reaches
    /// `presentEditRejection`, which raises an `NSAlert` — documented there as
    /// `nil` in production, "where the alert is the whole point". An
    /// unattended agent would hang on it, so the agent path needs the error as
    /// a VALUE. This carries it from `applyAndSave`'s detached save task to
    /// `applyFromAgent` awaiting that task.
    private var lastSaveError: Error?

    /// Applies an agent's edit INSIDE this window, so it lands where a person
    /// can see it instead of under them (W7).
    ///
    /// This is Route. `AutomationHost` used to read `edit.json`, compute a new
    /// EDL and write the file — and the window's next `applyAndSave` took
    /// `self.edl` and overwrote it, silently. W4 first settled that by
    /// REFUSING such an edit, which ended the data loss and left an agent
    /// unable to show its work; W7 supersedes it now that the control surface
    /// pays for two of Route's three preconditions anyway.
    ///
    /// **The transform runs against the WINDOW's EDL, not the file's.** That
    /// is what one writer means: the window holds edits that are applied but
    /// not yet persisted, so an agent computing from disk would compute from a
    /// stale document and reintroduce the divergence by a longer route. The
    /// host therefore hands over a transform rather than a finished EDL, and
    /// precomputes anything asynchronous (a media duration) BEFORE calling,
    /// because this runs synchronously against the live value.
    ///
    /// **One agent command is one undo entry** (E7), grouped explicitly.
    /// `UndoManager.groupsByEvent` is on by default and collapses whatever
    /// lands in a single run-loop pass, so an `auto-deep-trim` making twenty
    /// cuts would be one entry or twenty depending on the run loop rather than
    /// on anyone's decision.
    ///
    /// Throws if the compositor refused the edit, so the agent gets a value
    /// and no alert is raised.
    func applyFromAgent(_ actionName: String,
                        _ transform: (EditDecisionList) -> EditDecisionList) async throws
        -> EditDecisionList {
        let snapshot = edl

        // The group brackets the MUTATION only. `applyAndSave` enqueues a task
        // that finishes long after this returns; bracketing that instead would
        // close the group on a run loop pass unrelated to this command.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { $0.restore(snapshot) }
        edl = transform(edl)
        // The selection is cleared, not remapped (E13). It names OUTPUT
        // seconds, and ANY cut shifts output time, so a selection kept across
        // an edit silently points at different footage than the one the caller
        // selected — and `auto-deep-trim` can remove exactly the selected
        // range, leaving it pointing at seconds the timeline no longer has.
        // Remapping through the edit is the other defensible answer and is a
        // larger piece of work; clearing is the one that cannot be subtly
        // wrong, and an agent that wants a selection afterwards can set one.
        selection = nil
        selectedFoldID = nil
        undoManager?.endUndoGrouping()

        lastSaveError = nil
        applyAndSave()
        await waitForPendingSave()

        if let failure = lastSaveError {
            lastSaveError = nil
            throw failure
        }
        return edl
    }

    /// Cuts the current selection, as one undo entry, and reports whether
    /// there was anything to cut.
    ///
    /// `false` means NOTHING WAS SELECTED, which the caller turns into a
    /// refusal rather than a cheerful success: an agent cannot see the
    /// timeline, so "cut" and "cut nothing" must not look the same (§8).
    /// A person pressing Delete with no selection gets a harmless no-op,
    /// which is right for a keystroke and wrong for a command.
    func cutSelectionFromAgent() async throws -> Bool {
        guard let selection else { return false }
        _ = try await applyFromAgent("Cut") { edl in
            var updated = edl
            updated.cuts.append(Cut(range: selection.range, label: nil))
            return updated
        }
        return true
    }

    /// The transcript-side twin, for `narrate`.
    ///
    /// Needed for the same reason the EDL one is: the editor holds
    /// `transcript` as published state and `applyAndSaveTranscript` writes it
    /// WHOLE, so narration written to the file under an open window is
    /// overwritten by that window's next transcript save. Leaving this one
    /// verb refusing while the other three routed would be an inconsistency
    /// nobody could predict from the outside.
    ///
    /// A recording may legitimately have no transcript yet — narration is the
    /// one way to get one without running the recogniser — so the transform
    /// takes and returns a value rather than requiring an existing one.
    func applyTranscriptFromAgent(_ actionName: String,
                                  _ transform: (Transcript?) -> Transcript) async throws
        -> Transcript {
        let snapshot = transcript

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { target in
            guard let snapshot else { return }
            target.restoreTranscript(snapshot)
        }
        transcript = transform(transcript)
        undoManager?.endUndoGrouping()

        lastSaveError = nil
        applyAndSaveTranscript()
        await waitForPendingSave()

        if let failure = lastSaveError {
            lastSaveError = nil
            throw failure
        }
        return transcript ?? transform(nil)
    }

    /// The events-side twin, for verbs that write `events.json` (markers).
    func applyEventsFromAgent(_ actionName: String,
                              _ transform: ([LoggedEvent]) -> [LoggedEvent]) async throws
        -> [LoggedEvent] {
        let snapshot = events

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { $0.restoreEvents(snapshot) }
        events = transform(events)
        undoManager?.endUndoGrouping()

        lastSaveError = nil
        applyAndSaveEvents()
        await waitForPendingSave()

        if let failure = lastSaveError {
            lastSaveError = nil
            throw failure
        }
        return events
    }

    // MARK: - Testing seam

    /// Awaits the WHOLE chain of enqueued saves, not just the newest task.
    /// Awaiting only the newest is what let F2's older-save-lands-last
    /// inversion slip past every test in this suite.
    func waitForPendingSave() async {
        while let task = pendingSaveTask {
            await task.value
            // Another save may have been enqueued while we were awaiting
            // this one; that new task is now the tail.
            if pendingSaveTask == task { return }
        }
    }
}

/// Embeds `TimelineView` (AppKit) in the SwiftUI shell, driving it from
/// `state` and forwarding its callbacks back into `state`.
struct TimelineViewRepresentable: NSViewRepresentable {
    @ObservedObject var state: EditorTimelineState
    let playhead: Double
    /// Surfaces a marker click up to `EditorContentView`'s own `@State`
    /// (Task 6) — unlike the other callbacks below, this one opens UI
    /// (a sheet), not a model mutation, so it does not belong on
    /// `EditorTimelineState` alongside `onSelect`/`toggleExpansion`/
    /// `removeCut`, which all mutate testable state directly.
    let onEditMarker: (UUID) -> Void

    func makeNSView(context: Context) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 480, height: 56))
        // Set here as well as in `updateNSView` so the zoom buttons work from
        // the first render rather than only after the first update pass.
        state.timelineView = view
        view.onScrub = { [weak state] in state?.onScrub($0) }
        view.onSelect = { [weak state] in state?.onSelect($0) }
        view.onToggleExpansion = { [weak state] in state?.toggleExpansion(of: $0) }
        view.onExpandAndSelectFold = { [weak state] in state?.expandAndSelect(foldID: $0) }
        view.onSelectFold = { [weak state] in state?.selectFold(id: $0) }
        // Straight to `addMarker(atOutput:)`, which already does the
        // output-to-source conversion. A `createMarker` wrapper was written
        // here first and deleted — that is the fourth duplicate this session
        // that existed because the existing one was not looked for.
        view.onCreateMarker = { [weak state] in state?.addMarker(atOutput: $0) }
        view.onZoomChanged = { [weak state] in state?.timelineZoomFraction = $0 }
        view.onRemoveCut = { [weak state] in state?.removeCut(id: $0) }
        // D50/D56 (M5f Task 6): a marker drag reports the OUTPUT time it was
        // dropped at, converted back to SOURCE time by `moveMarker` itself
        // (see that method's doc comment) — never converted here in the
        // untestable AppKit seam.
        view.onMoveMarker = { [weak state] id, outputTime in state?.moveMarker(id: id, toOutput: outputTime) }
        view.onEditMarker = onEditMarker
        return view
    }

    /// Deliberately a one-line delegation to `state.displayState(playhead:)`
    /// and `TimelineView.apply(_:)` — the axis-mapping logic that matters
    /// lives in the first and the field-by-field fan-out in the second, both
    /// testable without AppKit or SwiftUI's runtime; this stays the thin,
    /// untestable seam.
    ///
    /// It used to do the fan-out itself, ten arguments long. That is what
    /// made adding `selectedFoldID` to `DisplayState` and forgetting it here
    /// a silent, invisible failure — and a mutant that blanked it survived a
    /// test suite that reached every layer except this one.
    func updateNSView(_ nsView: TimelineView, context: Context) {
        state.timelineView = nsView   // also set in makeNSView; see there
        nsView.apply(state.displayState(playhead: playhead))
        // Phrases, not words: `WordLaneTiers` measured that word chips need
        // 0.6pt each on a ten-minute recording against the 40pt they need to
        // be clickable. Grouped through the SAME pause rule the reading pane
        // uses, so a chip boundary always agrees with a paragraph break.
        // `audibleWords`, not `transcript.words`: muting a track takes its
        // speech out of the lane as well as out of the file.
        nsView.update(phrases: TranscriptPhrases.phrases(from: state.audibleWords))
    }
}

/// SwiftUI shell around the `AVPlayerLayer` surface: play/pause controls, the
/// timeline, and a jump-point list. §4.7 puts the video surface — and, per
/// Task 6, the timeline's gesture handling — in AppKit while everything
/// around them stays SwiftUI.
struct EditorContentView: View {
    @ObservedObject var state: EditorTimelineState
    /// Crop mode, the proposed box and whether the rail is open.
    ///
    /// Shared with the toolbar rather than owned here (D97): those controls
    /// live in the titlebar now, and an `NSToolbarItem` cannot see a SwiftUI
    /// view's private `@State`.
    @ObservedObject var chrome: EditorChromeState

    init(state: EditorTimelineState, chrome: EditorChromeState) {
        self.state = state
        self.chrome = chrome
    }
    @State private var playhead: Double = 0
    /// Re-derived from the player on every tick rather than stored: a cached
    /// flag goes stale the moment playback ends at the last frame, leaving a
    /// button labelled "Pause" over a stopped player.
    private var isPlaying: Bool { state.isPlaying }
    /// Which marker the edit sheet is open for, if any (Task 6). UI-only,
    /// like `expandedCutIDs`'s spirit but one level further out: nothing
    /// tests WHICH marker is currently open in a sheet, only that
    /// `EditorTimelineState.updateMarker`/`moveMarker` persist and undo
    /// correctly — see those methods' own tests. This lives here, not on
    /// `EditorTimelineState`, because it is presentation state a SwiftUI
    /// runtime test cannot exercise anyway.
    @State private var editingMarkerID: UUID?


    /// Whether the reading transcript is open. UI-only, like `croppingActive`:
    /// what is asserted elsewhere is that the transcript persists and edits,
    /// not which panes a window happens to be showing.
    /// The side panel: two independently-expandable indexes of one recording.
    ///
    /// When BOTH are open the transcript keeps its stored height and the
    /// markers list takes the rest, with a draggable divider between them.
    /// When only one is open it takes the whole rail — a divider between a
    /// section and a closed header would be a handle that resizes nothing.
    @ViewBuilder
    private var rail: some View {
        let markerPane = MarkerPane(state: state, playhead: playhead,
                                    onEditMarker: { editingMarkerID = $0 })
        // Built once and used for both slots, the same way `markerPane` is: two
        // constructions would be two pieces of `@State`, so the `+` would open
        // a field on a pane the header is not showing.
        let transcriptPane = TranscriptPane(state: state, playhead: playhead)
        let hasTranscript = state.transcriptionStatus != .none
        VStack(spacing: 0) {
            AccordionSection(title: "Markers",
                             subtitle: state.chapters.isEmpty
                                 ? nil : "\(state.chapters.count)",
                             isExpanded: $markersExpanded,
                             accessory: { markerPane.addButton },
                             content: { markerPane })
                .frame(maxHeight: RailLayout.markersHeight(markersExpanded: markersExpanded)
                       .maxHeight(fillIsInfinite: true))
            if hasTranscript {
                // ONE line between the sections, whichever kind it is.
                // `ResizableDivider` draws its own rule, so a plain `Divider`
                // above it put two hairlines and a gap between the markers
                // list and the Transcript heading — a seam that read as a
                // layout mistake rather than as a division.
                if RailLayout.showsDivider(markersExpanded: markersExpanded,
                                           transcriptExpanded: transcriptExpanded) {
                    ResizableDivider(axis: .horizontal, direction: -1) { delta in
                        let base = dragStartWidth ?? paneWidths.transcript
                        if dragStartWidth == nil { dragStartWidth = base }
                        paneWidths.transcript = PaneWidths.clampTranscript(base + delta)
                    } onCommit: {
                        dragStartWidth = nil
                        paneWidths.save()
                    }
                } else {
                    // No handle to draw when only one section is open — see
                    // `RailLayout.showsDivider` — but the two headings still
                    // need separating.
                    Divider()
                }
                AccordionSection(title: "Transcript",
                                 subtitle: state.transcript.map { "\($0.words.count) words" },
                                 isExpanded: $transcriptExpanded,
                                 accessory: { transcriptPane.addButton },
                                 content: { transcriptPane })
                // Its stored height only while sharing the rail; the whole of
                // it when the markers list is closed. `RailLayout` owns that
                // rule, because it has branches and this file cannot test them.
                .frame(maxHeight: RailLayout.transcriptHeight(
                    markersExpanded: markersExpanded,
                    transcriptExpanded: transcriptExpanded,
                    stored: paneWidths.transcript).maxHeight(fillIsInfinite: true))
                // `initial: true` so a recording whose transcript was already
                // loaded — reopening a document, or a second pass through this
                // view — gets the same answer as one that loads it a moment
                // later. Without it the rule only ever fires on the race it
                // was written for.
                .onChange(of: state.transcript?.words.count ?? 0, initial: true) { _, words in
                    guard RailLayout.transcriptOpensItself(
                        wordCount: words, alreadyDecided: transcriptDefaultApplied)
                    else { return }
                    transcriptDefaultApplied = true
                    transcriptExpanded = true
                }
            }
            Spacer(minLength: 0)
        }
    }


    /// Which sections are open. Both can be, at once — see `AccordionSection`
    /// for why an either/or accordion would be the wrong shape for two indexes
    /// of the same recording.
    ///
    /// The transcript starts closed and opens itself once the recording turns
    /// out to have words — see `RailLayout.transcriptOpensItself`. Closed is
    /// still the right STARTING state: the transcript loads after the editor
    /// opens, so a section that began open would flash empty on every
    /// recording that has no transcript at all.
    @State private var markersExpanded = true
    @State private var transcriptExpanded = false
    /// Whether the open-by-default rule has already had its say. Without it,
    /// closing the section and then editing a word would spring it open again.
    @State private var transcriptDefaultApplied = false
    /// Pane widths, loaded once and written back when a drag ENDS.
    ///
    /// Not on every frame of the drag: `UserDefaults` writes during a
    /// continuous gesture are dozens of writes for one decision, and a
    /// half-dragged width is not a width anybody chose.
    @State private var paneWidths = PaneWidths.load()
    /// The width being dragged, before it is committed.
    @State private var dragStartWidth: Double?
    /// The export sheet's live request, and the measured menu behind it.
    @State private var showingExport = false
    @State private var exportRequest = ExportRequest(
        destination: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "export.mp4"))
    @State private var exportOptions: [ExportOption] = []
    @State private var measuringExport = false

    /// A folder chooser, not a save panel: the filename is already decided
    /// from the recording's own name, and only the folder is worth asking
    /// about.
    static func chooseFolder(startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private var controller: PreviewController { state.controller }

    /// What to say after an automatic trim.
    static func trimCaption(_ outcome: EditorTimelineState.DeepTrimOutcome) -> String {
        switch outcome {
        case .cut(let spans, let seconds):
            let unit = spans == 1 ? "span" : "spans"
            return String(format: "Cut %d %@, %.1fs", spans, unit, seconds)
        case .nothingToCut:
            return "No dead air found"
        case .notReady:
            // The distinction that matters: this is a WAIT, not an answer.
            return "Still loading the waveform"
        }
    }

    /// The marker the sheet below is editing, re-derived from
    /// `state.events` on every access rather than cached at click time — a
    /// concurrent edit (undo, another drag) must not let the sheet open on
    /// stale label/transcript text.
    private var editingMarkerBinding: Binding<LoggedEvent?> {
        Binding(
            get: { editingMarkerID.flatMap { id in state.events.first { $0.id == id } } },
            set: { newValue in editingMarkerID = newValue?.id }
        )
    }

    /// What the timeline needs for THIS recording, capped by the window.
    ///
    /// Computed from the lanes this recording actually has rather than always
    /// claiming the window share — a recording with no transcript and no cuts
    /// needs two fewer lanes, and taking the height anyway would stretch the
    /// remaining ones to fill it.
    private var timelineHeight: Double {
        TimelineLaneBudget.timelineHeight(
            forWindowHeight: windowHeight,
            audioTracks: state.audioLaneNames,
            hasTranscript: state.transcript != nil)
    }

    /// The window's content height, measured once and read by the timeline.
    @State private var windowHeight: Double = 731
    /// Focus for the crop overlay, so Return and Escape reach it.
    @FocusState private var cropFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            content
                .onChange(of: geometry.size.height, initial: true) { _, height in
                    windowHeight = height
                }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // The document actions used to be a row right here, standing in
            // for a titlebar. They are `EditorWindowToolbar`'s items now, so
            // the content starts at the picture — and the `Divider()` that
            // separated the row from it goes too, because the system draws the
            // titlebar's own separator.
            HStack(alignment: .top, spacing: 0) {
                PlayerLayerView(player: controller.player,
                                clickMarks: state.clickMarks,
                                cues: state.subtitleCues,
                                banners: state.markerBanners)
                    .frame(minWidth: EditorWindowController.minimumPlayerSize.width,
                           minHeight: EditorWindowController.minimumPlayerSize.height)
                    .overlay {
                        // Only while cropping: an always-live drag layer would
                        // swallow clicks meant for the player.
                        if chrome.croppingActive {
                            CropDragOverlay(
                                videoSize: controller.player.currentItem?.presentationSize
                                    ?? CGSize(width: 16, height: 9),
                                box: $chrome.cropBox)
                                // Return commits the box, Escape abandons it.
                                //
                                // Here rather than on a button in the titlebar:
                                // a commit button had to appear beside the Crop
                                // toggle while the mode was on, and a toolbar
                                // item keeps the width it was built with — so
                                // the button drew over the Export icon next to
                                // it. Keys cost no width.
                                //
                                // Focus is taken when the overlay appears and
                                // the overlay exists exactly while the mode
                                // does, so neither key can fire against a crop
                                // that is not being drawn.
                                .focusable()
                                .focused($cropFocused)
                                .onAppear { cropFocused = true }
                                .onKeyPress(.return) {
                                    // Nothing drawn yet is not a crop to the
                                    // whole frame — it is a press with nothing
                                    // to commit, and applying `.full` would
                                    // write a crop key for a crop nobody made.
                                    guard chrome.cropBox != .full else { return .handled }
                                    state.applyCrop(chrome.cropBox)
                                    chrome.croppingActive = false
                                    return .handled
                                }
                                .onKeyPress(.escape) {
                                    // The box goes back to whole-frame as well
                                    // as the mode closing: a half-drawn box
                                    // left behind would be what the NEXT press
                                    // of Crop started from.
                                    chrome.cropBox = .full
                                    chrome.croppingActive = false
                                    return .handled
                                }
                        }
                    }
                // The rail is on the TRAILING edge, which is where the toolbar
                // toggle has always said it would be: that button's icon is
                // `sidebar.trailing`, and it was opening a panel on the left.
                if chrome.showRail {
                    // `direction: -1` — the rail is to the RIGHT of its
                    // divider, so dragging right makes it narrower.
                    ResizableDivider(direction: -1) { delta in
                        let base = dragStartWidth ?? paneWidths.markers
                        if dragStartWidth == nil { dragStartWidth = base }
                        paneWidths.markers = PaneWidths.clampMarkers(base + delta)
                    } onCommit: {
                        dragStartWidth = nil
                        paneWidths.save()
                    }
                    rail.frame(width: paneWidths.markers)
                }
            }

            // The seam is deliberate. Appearance-following chrome meets a
            // pinned-dark timeline here, and with no edge treatment a light
            // rail against a dark instrument is the "two apps stapled
            // together" look this work started from.
            Divider().overlay(EditorChromePalette.mediaEdge)
            TransportBar(
                isPlaying: isPlaying,
                hasMarks: !state.controller.jumpPoints.isEmpty,
                currentTime: RecordingState.clock(playhead),
                totalTime: RecordingState.clock(state.displayState(playhead: playhead).duration),
                currentMark: state.currentMarkLabel,
                // Reads the PUBLISHED mirror, writes through to the view. The
                // getter used to read the view directly, which is why a scroll
                // moved the timeline and left the slider behind.
                zoomFraction: Binding(
                    get: { state.timelineZoomFraction },
                    set: { state.timelineView?.setZoomFraction($0) }),
                isScrollable: state.timelineView?.isScrollable ?? false,
                visibleFraction: state.timelineView?.visibleFraction ?? 1,
                scrollFraction: state.timelineView?.scrollFraction ?? 0,
                onScroll: { state.timelineView?.setScrollFraction($0) },
                onZoomStep: { state.zoomTimeline(by: $0) },
                canCut: state.selection != nil,
                onRewind: { state.rewind() },
                onPreviousMark: { state.goToPreviousMark() },
                overdubState: state.overdubState,
                onTapRecord: { state.tapRecord() },
                isRecordingVoiceover: state.isRecordingVoiceover,
                onStopVoiceover: { state.stopVoiceover() },
                // The transport machine gets first refusal: while a take is
                // open, play/pause means pause the TAKE. It says whether it
                // handled the press, and ordinary playback is what happens
                // when it did not.
                onTogglePlay: {
                    if !state.tapPlayPause() { state.togglePlayback() }
                },
                onNextMark: { state.goToNextMark() },
                onSeekToTime: { text in
                    if let seconds = Timecode.parse(text) { state.seek(toOutput: seconds) }
                },
                onCut: { state.cutSelection() })

            // `TimelineLaneBudget` owns the arithmetic and the collapse order;
            // `windowHeight` is measured once around the whole body, because a
            // `GeometryReader` wrapped around the timeline alone would measure
            // the slot the timeline was already given and pin it there.
            // The gutter is laid out from the SAME plan the timeline spends,
            // so the rows line up without the two views agreeing about
            // anything else. It lives beside the timeline rather than inside
            // it because `TimelineView`'s x-axis IS time — carving a gutter
            // out of it would shift every second-to-pixel calculation there.
            HStack(spacing: 0) {
                TimelineGutter(
                    plan: TimelineLaneBudget.plan(
                        availableHeight: timelineHeight,
                        audioTracks: state.audioLaneNames,
                        hasTranscript: state.transcript != nil),
                    trackStates: state.audioTracks,
                    onGain: { state.setGain(track: $0, gain: $1) },
                    onMute: { state.setMuted(track: $0, muted: $1) })
                TimelineViewRepresentable(state: state, playhead: playhead,
                                          onEditMarker: { editingMarkerID = $0 })
            }
            .frame(height: timelineHeight)
        }
        // `documentSubtitle` counts markers and folds, so it changes on every
        // mark and every cut. Pushed from here rather than observed by the
        // controller because this view already re-reads it on each render —
        // `initial: true` so a window that opens with markers shows them
        // rather than waiting for the first edit.
        .onChange(of: state.documentSubtitle, initial: true) { _, subtitle in
            chrome.applySubtitle?(subtitle)
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            // 20Hz, raised from 10 when the playhead stopped being decoration.
            // It now selects which transcript word is highlighted, and the
            // recognizer emits words as short as 0.06s ("the", in this
            // project's first real recording) — at 10Hz those were skipped
            // entirely and the highlight jumped over them.
            //
            // The comment here used to say this value was "appearance only,
            // not asserted by any test", which stopped being true the moment
            // `TranscriptPlayhead` started consuming it.
            //
            // Still polling rather than `addPeriodicTimeObserver`: the observer
            // is the better mechanism, but it would not change what is on
            // screen, and the open question is the opposite one — whether
            // re-rendering a long transcript at this rate is affordable. That
            // needs a ten-minute recording to answer, and is in field-notes.
            let seconds = controller.player.currentTime().seconds
            playhead = seconds.isFinite ? seconds : 0
            // Pushed rather than read at render. `playhead` stops changing the
            // instant playback ends, so a render-time read of the rate had
            // nothing left to trigger it — see `EditorTimelineState.isPlaying`.
            state.updatePlayback(rate: controller.player.rate)
            // The voiceover lane advances on the SAME tick as the playhead, so
            // the two cannot drift apart: a level drawn at a position the
            // playhead has not reached is a lane that describes a different
            // moment than the one on screen.
            state.sampleVoiceoverLevel()
        }
        // Raised by the toolbar button and by File ▸ Export… alike — the
        // menu no longer keeps a save panel of its own.
        .onChange(of: state.exportRequestToken) { _, _ in
            // Seeded from Playback ▸ Show Clicks, which is the whole point of
            // that menu item being a preference rather than a per-window
            // toggle: what you set up while watching is what you get when you
            // export. Still overridable in the sheet — this is the default,
            // not a lock.
            exportRequest = ExportRequest(destination: state.defaultExportURL,
                                          drawClicks: state.showClicks,
                                          drawSubtitles: state.showSubtitles,
                                          drawMarkers: state.showMarkers)
            exportOptions = []
            measuringExport = true
            showingExport = true
            Task { @MainActor in
                let measured = await state.exportOptionsProvider?() ?? []
                exportOptions = measured
                measuringExport = false
                // Only if nothing has been picked in the meantime: measuring
                // builds a whole composition, and a choice made while it ran
                // must not be overwritten by its result.
                if exportRequest.resolution == .source, let first = measured.first {
                    exportRequest.resolution = first.resolution
                }
            }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(
                title: state.documentTitle,
                options: exportOptions,
                isMeasuring: measuringExport,
                durationSeconds: state.displayState(playhead: playhead).duration,
                request: $exportRequest,
                onCancel: { showingExport = false },
                onExport: {
                    state.onExport?(exportRequest)
                    showingExport = false
                },
                onChooseFolder: {
                    guard let folder = EditorContentView
                        .chooseFolder(startingAt: exportRequest.destination) else { return }
                    exportRequest.destination = folder
                        .appending(path: exportRequest.destination.lastPathComponent)
                })
        }
        .sheet(item: editingMarkerBinding) { marker in
            MarkerEditSheet(label: marker.label ?? "",
                            transcript: marker.transcript ?? "",
                            timeText: MarkerPane.timestamp(marker.timeSeconds)) { label, transcript, timeText in
                state.updateMarker(id: marker.id,
                                   label: label.isEmpty ? nil : label,
                                   transcript: transcript.isEmpty ? nil : transcript)
                // Time goes through `applyChapterEdit`, which already owned
                // the move-a-mark path for the chapter panel. Routing the
                // sheet through the same call keeps one implementation of
                // "what happens when a mark's time changes" rather than a
                // second that has to remember to re-sort and re-save.
                state.applyChapterEdit(id: marker.id, timeText: timeText, label: label)
                editingMarkerID = nil
            } onCancel: {
                editingMarkerID = nil
            }
        }
    }
}

/// Mute and gain for one audio source.
///
/// `TrackState.gain` has existed and been applied by the export mix since M3
/// with no way to set it — the same shape crop had, a model feature with no
/// surface. The waveform above redraws as the slider moves, because
/// `WaveformScale` applies gain before scaling, so "how loud will this be"
/// is answered by looking rather than by exporting.
private struct AudioTrackControls: View {
    let state: TrackState
    let onGain: (Double) -> Void
    let onMute: (Bool) -> Void

    /// "microphone" is what the model calls it; "Mic" is what fits.
    private var displayName: String {
        switch state.track {
        case "microphone": return "Mic"
        case "systemAudio": return "System"
        default: return state.track
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !state.muted }, set: { onMute(!$0) })) {
                Text(displayName)
                    .frame(width: 52, alignment: .leading)
            }
            .toggleStyle(.checkbox)

            Slider(value: Binding(get: { state.gain }, set: { onGain($0) }), in: 0...4)
                .frame(maxWidth: 220)
                .disabled(state.muted)

            // The number matters: "somewhere past halfway" is not a setting
            // anyone can return to deliberately.
            Text(String(format: "%.1f×", state.gain))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// The marker-edit UI (D50/D56, M5f Task 6): label plus transcript, the two
/// fields `EditorTimelineState.updateMarker(id:label:transcript:)` accepts
/// together.
///
/// A SHEET, not an inline field or a popover: `TimelineView` is a raw
/// `NSView` with no spare room to grow a second, always-visible editing
/// surface without competing with the marker track itself for the same few
/// pixels, and a popover would need this AppKit view's exact click point
/// translated into a SwiftUI anchor — real plumbing for a feature used
/// occasionally, not every frame. A modal sheet is the smallest addition on
/// top of a shell that is already SwiftUI (`EditorContentView`):
/// `.sheet(item:)` needs only a `Binding` and an `Identifiable` item, and
/// blocking the rest of the editor while a transcript — potentially a full
/// sentence, not just a short label — is being typed is the right default,
/// not an inline field a stray click elsewhere could abandon half-written.
private struct MarkerEditSheet: View {
    @State var label: String
    @State var transcript: String
    /// The mark's own time, editable.
    ///
    /// `applyChapterEdit(id:timeText:label:)` has accepted a typed time since
    /// the chapter panel was built — the sheet simply never offered a field
    /// for it, so the only way to move a mark was to drag it on the timeline,
    /// which is imprecise by construction. Typing is how you place a mark on
    /// a word.
    @State var timeText: String
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    /// Nil while the text is not a time, which is what disables Save and
    /// colours the field — an unparseable time silently leaving the old one in
    /// place would look like the edit was accepted.
    private var parsedTime: Double? { Timecode.parse(timeText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Marker").font(.headline)
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text("Time").font(.caption).foregroundStyle(.secondary)
                TextField("0:00", text: $timeText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90)
                if parsedTime == nil {
                    Label("Not a time", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("Transcript").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $transcript)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave(label, transcript, timeText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedTime == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Hosts one editor's preview in its own `NSWindow`.
///
/// Snitt is a regular app (§4.14, D45; see `AppShell`), so its windows can
/// become key the normal way without this controller doing anything about
/// activation policy.
@MainActor
public final class EditorWindowController: NSObject, NSWindowDelegate {
    // The project's logger factory (`SnittLog.logger`), not a hand-rolled
    // `Logger` — see `DocumentOpener`'s identical note. `.compositor`
    // matches `RecordingCoordinator`'s category for the same
    // build-a-composition family of failures (export IS a composition
    // build, per §9).
    private static let log = SnittLog.logger(.compositor, target: "SnittApp")

    private let controller: PreviewController
    private let state: EditorTimelineState
    /// Crop mode, the proposed box and whether the rail is open — shared by
    /// the content view and the titlebar (D97).
    private let chrome: EditorChromeState
    /// HELD, not just installed. `NSWindow.toolbar` does not retain its
    /// delegate, so a toolbar built and dropped on the floor would lose every
    /// item the moment the window asked for one again.
    private let toolbar: EditorWindowToolbar
    public let window: NSWindow
    private var isShown = false

    /// The window's `UndoManager` (Task 7) — the same manager Task 1's Edit
    /// menu resolves `undo:`/`redo:` against through the responder chain.
    public var undoManager: UndoManager? { window.undoManager }

    private static var count = 0
    public static var openWindowCount: Int { count }

    /// Retains every open editor for as long as its window is on screen.
    ///
    /// Without this, an editor's ONLY owner is whatever created it. The stop
    /// path that Task 5 adds constructs one and calls `show()` without
    /// holding on to it afterwards — every prior caller of this type was a
    /// test that kept its own `let editor = ...` alive for the whole test, so
    /// this gap never showed up before there was a caller that didn't. A
    /// dropped `EditorWindowController` deallocates: `NSWindow.delegate` is
    /// `weak`, so `windowWillClose` stops firing, and the window itself can
    /// vanish from under a user who is still watching it.
    private static var open: [EditorWindowController] = []

    /// The document this window edits. Standardized on the way in so two
    /// spellings of one path cannot open two windows onto one document —
    /// on macOS `/tmp` is a symlink to `/private/tmp`, so a raw string
    /// comparison would let exactly that through. Once EDL autosave exists
    /// (Task 7), two windows on one bundle means two EDLs over one document
    /// and whichever saves last wins; this identity is what `existing(for:)`
    /// keys reuse on to prevent that.
    /// Where the document lives. `private(set) var`, not `let`, because an
    /// IMPORTED document moves once: it is created in a scratch directory and
    /// relocated by the first Save. Everything else about it is identical
    /// before and after, so moving the window to a new document would throw
    /// away undo history and window position for no reason.
    public private(set) var bundleURL: URL

    /// Whether this document has never been saved anywhere the person chose.
    ///
    /// True only for imports. A recording Snitt made is written to the
    /// recordings folder as it stops, so it has a home from the moment it
    /// exists; an imported video is in a scratch directory until somebody says
    /// where it belongs.
    public private(set) var isUnsaved = false

    /// Looks up an already-open window for `url`, standardizing both sides
    /// of the comparison so `/tmp/x.snitt` and `/private/tmp/x.snitt` — the
    /// same document under two spellings — are recognized as one.
    // MARK: - Agent view control (D109)

    /// The editor's VIEW state, which is the part that is not in the document.
    ///
    /// Reported by every `editor` verb, because an agent cannot watch the
    /// window: a verb returning nothing would leave it unable to tell
    /// "seeked" from "silently did nothing", which is the confidently-wrong
    /// outcome §8 forbids.
    var agentVisibleState: EditorState {
        let content = window.contentRect(forFrameRect: window.frame)
        return EditorState(bundlePath: bundleURL.path,
                           isOpen: true,
                           isPlaying: state.isPlaying,
                           playheadSeconds: state.currentOutputSeconds,
                           selectionStartSeconds: state.selection?.range.start,
                           selectionEndSeconds: state.selection?.range.end,
                           widthPoints: Double(content.width),
                           heightPoints: Double(content.height))
    }

    /// Resizes this editor, centred, clamped to the floor and the screen.
    ///
    /// Applies to an ALREADY-OPEN window as well as a fresh one: an agent that
    /// opens a recording, sees it is too large to film legibly, and asks again
    /// with a size should get the resize rather than a no-op — and re-opening
    /// an open bundle is how it would naturally ask.
    func agentResize(width: Double, height: Double) {
        state.noteAgentActivity()
        let rect = Self.requestedContentRect(
            width: width, height: height,
            on: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        window.setFrame(window.frameRect(forContentRect: rect), display: true)
    }

    /// Starts playback. Idempotent: playing an already-playing window is not
    /// an error, because an agent retrying a command it could not observe the
    /// result of is ordinary rather than exceptional.
    func agentPlay() { state.noteAgentActivity(); state.playForAgent() }
    func agentPause() { state.noteAgentActivity(); state.pauseForAgent() }

    /// Moves the playhead, in OUTPUT time — the recording with its cuts
    /// removed, which is what a person watching the window sees.
    func agentSeek(toOutput seconds: Double) {
        state.noteAgentActivity()
        state.seek(toOutput: seconds)
    }

    /// Sets or clears the timeline selection.
    ///
    /// Through `onSelect` rather than assigning `selection` directly, so an
    /// agent's selection clears `selectedFoldID` exactly as a person's drag
    /// does. Assigning the property would leave Delete meaning "remove that
    /// cut" while the highlight showed something else.
    func agentSelect(_ range: TimeRange?) {
        state.noteAgentActivity()
        state.onSelect(range.map { Selection(range: $0) })
    }

    /// Forwards an agent's edit to this window's document state (W7).
    ///
    /// The window owns the lookup (`existing(for:)`) and the state owns the
    /// apply, so the agent path needs both and `state` is private. Forwarding
    /// rather than exposing `state` keeps the agent surface to the three verbs
    /// it actually needs, instead of handing out the whole document object.
    func applyFromAgent(_ actionName: String,
                        _ transform: (EditDecisionList) -> EditDecisionList) async throws
        -> EditDecisionList {
        state.noteAgentActivity()
        return try await state.applyFromAgent(actionName, transform)
    }

    func applyTranscriptFromAgent(_ actionName: String,
                                  _ transform: (Transcript?) -> Transcript) async throws
        -> Transcript {
        state.noteAgentActivity()
        return try await state.applyTranscriptFromAgent(actionName, transform)
    }

    func agentCutSelection() async throws -> Bool {
        state.noteAgentActivity()
        return try await state.cutSelectionFromAgent()
    }

    static func existing(for url: URL) -> EditorWindowController? {
        let wanted = normalizedBundleURL(url)
        return open.first { $0.bundleURL == wanted }
    }

    /// `url.standardizedFileURL.resolvingSymlinksInPath()` alone is not
    /// enough: `resolvingSymlinksInPath()` preserves whatever
    /// has-directory-path hint `url` already carries, and `URL` computes
    /// that hint by checking the filesystem AT THE TIME a `URL` value is
    /// built. Two `URL`s for the identical `/tmp` vs `/private/tmp` bundle
    /// path can therefore resolve to the same string with, and without, a
    /// trailing slash — which `==` treats as different URLs — purely
    /// because of when each one happened to be constructed relative to the
    /// bundle existing on disk. Rebuilding from the plain path with
    /// `URL(fileURLWithPath:)` right before resolving forces both sides to
    /// recompute that hint against the SAME (current, real) filesystem
    /// state, so the trailing slash can no longer differ.
    ///
    /// Not `private`: `DocumentOpener` keys its in-flight registry (F3) on
    /// exactly this identity, and a second normalization written next door
    /// would be a second answer to "is this the same document".
    /// Where an editor window opens: **centred, at 75% of the screen**.
    ///
    /// The previous fixed 640x420 opened small, wherever AppKit chose to
    /// cascade it. A timeline is a wide scrubbing surface — at 640pt a
    /// ten-minute recording is roughly 0.75 seconds per pixel, the density
    /// `TrimGesture` documents as the reason a deliberate short cut gets
    /// swallowed. Opening larger is the cheap half of that; zoom is the other.
    ///
    /// `visibleFrame`, not `frame`: it excludes the menu bar and the Dock, so
    /// 75% of it is 75% of the space a window can actually occupy.
    ///
    /// Pure and screen-free so it is testable — a test host has no screen and
    /// `NSScreen.main` is nil there. A nil or empty screen falls back to the
    /// old fixed size rather than guessing, keeping headless behaviour
    /// unchanged instead of inventing a geometry nobody can see.
    /// The smallest the editor's content may get.
    ///
    /// Stated and tested rather than left to whatever the subviews happen to
    /// tolerate. Below this the timeline starts eating the picture — the one
    /// thing that is supposed to be largest — and "what breaks first" becomes
    /// a guess instead of an assertion.
    ///
    /// Derived from the parts, so changing a part moves the minimum with it:
    /// the chapters rail plus the player's own `minWidth` across, and the
    /// player's `minHeight` plus the smallest usable timeline plus the
    /// transport and control rows down.
    static let chaptersRailWidth: Double = 260
    static let minimumPlayerSize = NSSize(width: 480, height: 270)
    /// Transport row, audio controls and the button row beneath the timeline.
    static let editorChromeHeight: Double = 96

    /// The editor window, configured as one deck of chrome (rev 5, W3).
    ///
    /// A function rather than five lines inside `init` because the
    /// configuration is the whole of this item and is worth asserting without
    /// building a recording to get at it.
    ///
    /// `.fullSizeContentView` puts the content under the titlebar, so the
    /// toolbar row IS the titlebar rather than a second deck beneath it — the
    /// window was spending a strip on a title the row below already showed.
    static func makeWindow(contentRect: NSRect, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        // VISIBLE now, and drawn by the system (D97). It used to be hidden so
        // that the app's own row could draw a title of its own without the
        // window drawing a second copy above it — which meant the string
        // Mission Control, the Window menu and ⌘-tab read was never the string
        // anybody was looking at. One title, in one place, and the toolbar
        // lays out beside it.
        window.titleVisibility = .visible
        window.title = title
        return window
    }

    /// `.fullSizeContentView` is deliberately GONE from the mask above.
    ///
    /// It existed to pull the content up under a transparent titlebar so a
    /// hand-built row could stand in for one. With a real `NSToolbar` the
    /// titlebar IS the row, and keeping the flag would put the content under
    /// it — the toolbar drawing over the picture instead of above it.
    static let usesFullSizeContentView = false

    /// The floor a Snitt window may be dragged to: 800x600, or whatever the
    /// parts actually need if that is larger.
    ///
    /// **Both halves matter.** The derived figure is what the rail, the
    /// picture, the timeline and the chrome cannot do without, and letting a
    /// flat number override it downwards would produce a window whose contents
    /// are clipped rather than small. The flat number is what stops the window
    /// reaching a size where everything technically fits and nothing is
    /// usable — narrow enough that the transport row started dropping
    /// controls, which is where the wrapped duration was reported from.
    static let requestedMinimumSize = NSSize(width: 800, height: 600)

    static var minimumContentSize: NSSize {
        let derived = NSSize(width: chaptersRailWidth + minimumPlayerSize.width,
                             height: minimumPlayerSize.height
                                   + TimelineLaneBudget.minimumTimelineHeight
                                   + editorChromeHeight)
        return NSSize(width: max(derived.width, requestedMinimumSize.width),
                      height: max(derived.height, requestedMinimumSize.height))
    }

/// Where Export lands unless someone changes it: beside the recording,
    /// named after it, as an `.mp4`.
    ///
    /// Beside rather than in Movies or Downloads because a `.snitt` bundle
    /// already lives where its owner put it, and the export belongs with the
    /// thing it was made from. Static and pure so the naming is testable
    /// without opening a document.
    static func defaultExportURL(forBundle bundleURL: URL) -> URL {
        let folder = bundleURL.deletingLastPathComponent()
        let name = bundleURL.deletingPathExtension().lastPathComponent
        return folder.appending(path: name).appendingPathExtension("mp4")
    }

    /// Centres a REQUESTED content size on the screen, clamped to what will
    /// actually fit (D110).
    ///
    /// An agent filming the editor needs it smaller than the 75% default: at
    /// full size, scaled down to a README-width GIF, the transcript pane and
    /// the timeline labels are illegible. That is the "showing the interface"
    /// problem this whole demo exists inside, and cropping around it loses the
    /// panes that make the editor worth showing.
    ///
    /// **Clamped, then REPORTED, never silently obeyed.** `CropRect` sets the
    /// precedent: it clamps rather than throwing, and `CropSummary` returns
    /// the APPLIED rect so the adjustment is visible instead of silent. The
    /// same rule here — `EditorState` carries the size the window actually
    /// got, so an agent that asked for something impossible finds out rather
    /// than filming a window it has the wrong dimensions for.
    ///
    /// Pure and screen-free for the same reason `openingContentRect` is: a
    /// test host has no screen and `NSScreen.main` is nil there.
    static func requestedContentRect(width: Double,
                                     height: Double,
                                     on visibleFrame: NSRect?) -> NSRect {
        // The floor is the window's OWN `minimumContentSize`, not a number
        // invented here. That property already derives what the chrome, the
        // rail and the panes need, and enforces a flat 800x600 under it —
        // measured from where the transport row started dropping controls. A
        // second answer would drift from it, and this one would drift LOWER,
        // handing an agent a window macOS then silently resizes anyway.
        let floor = minimumContentSize
        let wanted = NSSize(width: max(floor.width, width),
                            height: max(floor.height, height))
        guard let visibleFrame, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return NSRect(origin: .zero, size: wanted)
        }
        // Clamped to the SCREEN as well as to the floor. A window larger than
        // the space it sits in cannot be filmed whole, and the point of asking
        // for a size is to control what the frame contains.
        let size = NSSize(width: min(wanted.width, visibleFrame.width),
                          height: min(wanted.height, visibleFrame.height))
        return NSRect(x: visibleFrame.minX + (visibleFrame.width - size.width) / 2,
                      y: visibleFrame.minY + (visibleFrame.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

        static func openingContentRect(on visibleFrame: NSRect?,
                                   scale: Double = 0.75) -> NSRect {
        guard let visibleFrame, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return NSRect(x: 0, y: 0, width: 640, height: 420)
        }
        let width = visibleFrame.width * scale
        let height = visibleFrame.height * scale
        return NSRect(x: visibleFrame.minX + (visibleFrame.width - width) / 2,
                      y: visibleFrame.minY + (visibleFrame.height - height) / 2,
                      width: width,
                      height: height)
    }

    static func normalizedBundleURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
    }

    /// Every currently open editor, for the Window menu's document list
    /// (`AppShell`'s `WindowMenuDelegate`). Not `public` — only `SnittApp`
    /// itself needs to enumerate open editors.
    static var openEditors: [EditorWindowController] { open }

    /// `edl` and `events` are REQUIRED (M4b whole-branch review, Important
    /// finding #3) — a default here existed purely so window-lifecycle tests
    /// that don't care about editing state didn't need touching, which is
    /// test convenience shaping a production signature. A real editor
    /// session must pass the recording's actual EDL and events, or every
    /// trim it draws applies against the wrong starting point and loses the
    /// recording's real markers; making the caller write `.fullRange()` /
    /// `[]` explicitly when that's genuinely what's meant turns "I forgot"
    /// into a build error instead of a silently empty scrub bar.
    /// Marks this document as living in a scratch directory until saved.
    ///
    /// Set after `init` rather than passed through it: every existing caller
    /// opens a document that already has a home, and threading a parameter
    /// none of them would ever set through the one initializer is how a
    /// default ends up meaning two things.
    public func markUnsaved() { isUnsaved = true }

    /// Test-only: where the PREVIEW believes the document lives.
    ///
    /// Read separately from `bundleURL` on purpose. The two are set by
    /// different objects during a save, and the failure worth catching is them
    /// disagreeing: the window would show the new path while every write went
    /// to the old one, silently, because those writes are fire-and-forget.
    var previewBundleURLForTesting: URL { state.controller.snittBundle.url }

    public init(controller: PreviewController, title: String, bundleURL: URL,
                edl: EditDecisionList, events: [LoggedEvent]) {
        self.controller = controller
        self.bundleURL = Self.normalizedBundleURL(bundleURL)
        let state = EditorTimelineState(controller: controller, edl: edl, events: events)
        self.state = state
        // Transcript (D62): load an existing one, or start making one. From
        // here rather than the state's init, so the TCC-gated recognizer is
        // never constructed as a side effect of a test building a state.
        state.loadTranscript()
        state.loadCaptureHealth()
        state.beginTranscriptionIfNeeded()
        let chrome = EditorChromeState()
        self.chrome = chrome
        let hosting = NSHostingView(
            rootView: EditorContentView(state: state, chrome: chrome))
        let window = Self.makeWindow(
            contentRect: Self.openingContentRect(on: NSScreen.main?.visibleFrame),
            title: title)
        state.documentTitle = title
        // Before the window is shown, so the first frame has its chrome rather
        // than growing a titlebar a moment later.
        let toolbar = EditorWindowToolbar(state: state, chrome: chrome)
        self.toolbar = toolbar
        toolbar.install(on: window)
        state.defaultExportURL = Self.defaultExportURL(forBundle: bundleURL)
        // Enforced by the window itself, not merely documented: a layout with
        // a stated minimum that nothing stops you dragging past has no
        // minimum.
        window.contentMinSize = Self.minimumContentSize
        window.contentView = hosting
        // We hold `window` for the controller's lifetime (the `window`
        // property below), so the default release-on-close would fight that
        // ownership; keep the NSWindow alive until we drop our own reference.
        window.isReleasedWhenClosed = false
        // Found by hand (manual "quit and reopen" test after Task 6 made
        // several editor windows open at once): quitting with more than one
        // editor window open segfaulted in `objc_release` inside
        // `-[_NSWindowTransformAnimation dealloc]`, torn down mid-`CATransaction`
        // commit on the main run loop — AppKit's own window-close transform
        // animation racing against several windows closing back-to-back as
        // `-[NSApplication terminate:]` tears them down for quit. `.none`
        // means AppKit never constructs that animation object for this
        // window at all, which removes the crashing class from this app's
        // code path entirely rather than trying to win a race against it.
        // A preview/editor window closing without a zoom/fade transition is
        // not a loss worth keeping this crash for.
        window.animationBehavior = .none
        self.window = window
        super.init()
        // After `super.init`, because both capture `self`.
        state.onExport = { [weak self] in self?.performExport($0) }
        state.exportOptionsProvider = { [weak self] in await self?.exportOptions() ?? [] }
        window.delegate = self
        // Set only now that `window` exists — this window's `undoManager`
        // (lazily created by AppKit on first access) is what Task 1's Edit
        // menu already resolves `undo:`/`redo:` against through the
        // responder chain.
        state.undoManager = window.undoManager
        // A refused edit has to reach the person who made it (F1). The
        // state cannot present an alert itself — it has no window — so the
        // window controller owns the presentation, exactly as it does for
        // an export failure.
        state.onEditRejected = { [weak self] in self?.presentEditRejection($0) }
    }

    /// Test seam: an alert here runs modal and would hang a test target
    /// that has no one to click it — the same reason `exportForTesting`
    /// exists rather than driving `presentExportPanel`. Set by a test that
    /// needs to observe a refusal; `nil` in production, where the alert is
    /// the whole point.
    var onEditRejectedForTesting: ((Error) -> Void)?

    /// Tells the user that the edit they just made was refused and undone.
    ///
    /// Skipping the write alone would leave a silent no-op: the drag
    /// appears to have done nothing, and the reason (the trim removed the
    /// entire recording) is invisible. `localizedDescription` is NOT shown
    /// or logged here — Snitt's error types are plain enums, so it renders
    /// as an opaque `CompositionError` string that tells a user nothing.
    private func presentEditRejection(_ error: Error) {
        let ns = error as NSError
        Self.log.error("Refused an edit the compositor rejected: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        if let observe = onEditRejectedForTesting {
            observe(error)
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snitt could not make that edit."
        alert.informativeText = "The edit was undone and nothing was saved. "
            + "A trim that removes the whole recording is the usual cause."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Brings the window to the front.
    public func show() {
        if !isShown {
            isShown = true
            Self.count += 1
            Self.open.append(self)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Stops playback and closes the window. Safe to call more than once,
    /// and safe even if the window was already closed via its own close
    /// button (`windowWillClose` runs the same teardown).
    public func close() {
        guard isShown else { return }
        teardown()
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        teardown()
    }

    /// The one place that leaves the open count and pauses playback — run
    /// exactly once per window, however the close was triggered.
    private func teardown() {
        guard isShown else { return }
        isShown = false
        // A closed window whose player keeps playing leaves audio coming
        // from a window the user can no longer see.
        controller.pause()
        Self.count -= 1
        Self.open.removeAll { $0 === self }
        // The poster is drawn from the material the EDL keeps, so trimming a
        // dead lead-in — the single most common edit this app exists to make —
        // leaves the icon showing seconds the recording no longer contains.
        // Once per editing session, not once per edit: stamping is a
        // half-second job.
        if state.editsChangedTheRecording {
            state.editsChangedTheRecording = false
            let bundle = controller.snittBundle
            let state = self.state
            Task { @MainActor in
                await state.awaitPendingSave()
                _ = await RecordingIcon.stampInBackground(bundle: bundle).value
            }
        }
    }

    // MARK: - Edit menu: Cut Selection (Task 5)

    /// Whether this editor's timeline currently has something selected —
    /// the same condition that enables/disables `EditorContentView`'s Cut
    /// button. Read by `AppDelegate`'s `NSMenuItemValidation` conformance so
    /// the Edit ▸ Cut Selection menu item (Delete/Backspace, see
    /// `AppShell.editMenuItem`) is disabled with nothing selected — Task 5's
    /// own constraint: "a user with nothing selected must not be offered an
    /// action that does nothing". It is also what keeps the Delete key from
    /// swallowing an ordinary Backspace anywhere else in the app: the item
    /// is enabled only while THIS is true for the key window's editor, so a
    /// Backspace typed into a text field — the marker inspector's title or
    /// time, a different window, or this editor's own window with nothing
    /// selected — falls through to normal text editing instead.
    var hasTimelineSelection: Bool { state.selection != nil }

    /// Whether this recording has a crop to put back, which is what greys out
    /// Edit ▸ Reset Crop when it does not.
    var hasCrop: Bool { state.edl.crop != nil }

    /// Edit ▸ Reset Crop. Same nil-target resolution as `cutTimelineSelection`
    /// below: the menu picks the key window's editor and calls this, which is
    /// the decision the titlebar's Reset button used to make before a toolbar
    /// item's fixed width made an appearing-and-disappearing button draw over
    /// its neighbour.
    func resetCrop() { state.resetCrop() }

    /// Edit ▸ Auto-Trim, at the preset the toolbar menu also calls Default.
    func autoTrimAtDefaultPreset() { _ = state.autoDeepTrim(preset: .default) }

    /// Edit ▸ Crop. Enters or leaves the mode; the box itself is committed by
    /// Return and abandoned by Escape, both handled by the drag overlay.
    func toggleCrop() { chrome.croppingActive.toggle() }

    /// View ▸ Panel.
    func togglePanel() { chrome.showRail.toggle() }

    /// Edit ▸ Add Marker, at wherever playback is.
    func addMarkerAtPlayhead() {
        state.addMarker(atOutput: state.outputPlayhead)
    }

    /// Edit ▸ Add Narration. Opens the field; the pane focuses it on appear.
    func beginWritingNarration() { state.beginWritingNarration() }

    /// Whether a written line has anywhere to go, which is what greys out
    /// Edit ▸ Add Narration — the same gate the pane's `+` uses, so the menu
    /// and the button cannot disagree about whether the feature is available.
    var acceptsWrittenNarration: Bool { state.acceptsWrittenNarration }

    /// View ▸ Zoom In / Zoom Out. `direction` is +1 or -1.
    func zoomTimeline(by direction: Double) {
        state.zoomTimeline(by: direction)
    }

    /// What View ▸ Panel should be called right now, so the menu says which
    /// way it will go rather than always claiming one — the same rule
    /// `deleteMenuTitle` follows.
    var panelMenuTitle: String { chrome.showRail ? "Hide Panel" : "Show Panel" }

    /// Edit ▸ Cut Selection (Delete/Backspace), Task 5's second requirement:
    /// "Task 4 added a Cut button but no keyboard path." `EditorWindowController`
    /// is not in the responder chain (see `AppDelegate.exportDocument`'s doc
    /// comment for why), so the menu item's nil target resolves to
    /// `AppDelegate`, which picks the key window's editor and calls this —
    /// the exact same decision `EditorContentView`'s Cut button already
    /// makes, just reachable without a mouse.
    func cutTimelineSelection() {
        // Dispatches: `deleteSelection` decides whether Delete cuts a range or
        // removes a fold. The menu item keeps one action and one key; what it
        // MEANS follows the highlight.
        state.deleteSelection()
    }

    /// What Edit ▸ Delete should be called right now, so the menu says which
    /// of the two edits it will perform rather than always claiming one.
    var deleteMenuTitle: String {
        state.selectedFoldID != nil ? "Remove Cut" : "Cut Selection"
    }

    // MARK: - Export (Task 8)

    /// Playback commands, forwarded from the app delegate's menu actions.
    ///
    /// Thin wrappers rather than exposing `state`: the delegate needs four
    /// verbs, not the whole editor model, and every other menu action here
    /// reaches the document the same way.
    /// Playback ▸ Show Clicks, for THIS document.
    ///
    /// Per document, not app-wide: the flag lives in `edit.json`, so the menu
    /// acts on whichever recording is in front — the same scoping File ▸ Export
    /// already uses. Persisted through the ordinary EDL save path so it is
    /// undoable and survives closing the window.
    public func setShowClicks(_ enabled: Bool) { state.setShowClicks(enabled) }
    public func setShowSubtitles(_ enabled: Bool) { state.setShowSubtitles(enabled) }
    public func setShowMarkers(_ enabled: Bool) { state.setShowMarkers(enabled) }

    /// What the menu's checkmarks read.
    public var showsClicks: Bool { state.edl.showClicks }
    public var showsSubtitles: Bool { state.edl.showSubtitles }
    public var showsMarkers: Bool { state.edl.showMarkers }

    public func togglePlayback() { state.togglePlayback() }
    public func rewindToStart() { state.rewind() }
    /// D93. Forwarded rather than reached through `state`, matching every
    /// other command the menu drives: the window controller is the surface the
    /// app delegate talks to.
    public var isRecordingVoiceover: Bool { state.isRecordingVoiceover }
    public func startVoiceover() -> VoiceoverRecorder.StartFailure? { state.startVoiceover() }
    public func stopVoiceover() { state.stopVoiceover() }

    public func goToPreviousMark() { state.goToPreviousMark() }
    public func goToNextMark() { state.goToNextMark() }
    /// Whether there is a mark to step to, so the menu items can disable
    /// themselves rather than looking live and doing nothing.
    public var hasMarks: Bool { !state.controller.jumpPoints.isEmpty }

    /// File ▸ Export… — the same sheet the toolbar opens.
    ///
    /// The save panel this used to raise is gone. It carried the resolution
    /// menu in its accessory slot, which worked and read as an afterthought:
    /// the sizes were there and nothing about the panel said they mattered.
    public func presentExportPanel() {
        state.requestExport()
    }

    /// Runs an export the sheet has configured, reporting the outcome in an
    /// alert. The sheet has already dismissed itself by the time this runs.
    ///
    /// Exports against `state.edl` — the exact EDL the preview is currently
    /// showing, not a re-read of `edit.json` from disk. Autosave means those
    /// normally agree, but reading the in-memory value is what keeps them
    /// agreeing even for the instant between a trim and its `applyAndSave`
    /// write landing, and it is what §9 ("preview and export share one
    /// builder") actually asks for: this is the EDL the on-screen preview was
    /// built from, not a second, separately-sourced one that merely usually
    /// matches it.
    /// File ▸ Share — macOS's own share sheet, the way QuickTime does it.
    ///
    /// Deliberately the SYSTEM picker rather than a list Snitt maintains:
    /// whatever the person has set up — AirDrop, Messages, Mail, a third-party
    /// extension — is already there and stays right without Snitt tracking it.
    /// The destination presets answer "make me a file this place accepts";
    /// this answers "send it", and they are different questions.
    ///
    /// A recording must be EXPORTED before it can be shared, because the only
    /// file that otherwise exists is `capture.mov` — raw, untrimmed, and not
    /// what anyone means by "share this". Since a source export copies its
    /// samples rather than re-encoding, that is fast enough not to feel like a
    /// step.
    func share(via service: NSSharingService) {
        let stem = state.defaultExportURL.deletingPathExtension().lastPathComponent
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension(ShareMenu.exportedType.preferredFilenameExtension ?? "mp4")
        var request = ExportRequest(destination: temporary,
                                    drawClicks: state.edl.showClicks)
        request.resolution = .source

        // A sheet, because the export takes seconds and the old version showed
        // NOTHING while it ran — the reported "about 10s to load, with no
        // indication anything is happening". Attached to the window rather
        // than free-floating, so it is obvious WHICH recording is being
        // prepared when several editors are open.
        let progress = beginSharePreparation(named: service.menuItemTitle)
        Task { @MainActor in
            defer { endSharePreparation(progress) }
            do {
                // Shares the EDITED recording, and copies it too, so the
                // clipboard and the share sheet cannot disagree about what
                // "this recording" currently means.
                try await performExport(request, pasteboard: .general)
                // The service presents its OWN interface — AirDrop's window,
                // Mail's compose sheet. Nothing here anchors anything, which
                // is what fixes the sheet appearing in a corner of the editor:
                // the old code positioned an `NSSharingServicePicker` against
                // a rectangle it computed in the content view.
                service.perform(withItems: [temporary])
            } catch {
                self.presentExportFailure(error)
            }
        }
    }

    /// Shows "Preparing to share…" on this window, and returns the sheet so it
    /// can be taken down again.
    ///
    /// Indeterminate deliberately: `MovieExporter` reports no progress, and a
    /// bar that advanced on a timer of its own would be a fiction about how
    /// far along the export is. A spinner says "working" and claims nothing
    /// more than that.
    private func beginSharePreparation(named destination: String) -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        // The same over-release trap `SettingsWindowController` documents: a
        // programmatically created NSWindow defaults `isReleasedWhenClosed` to
        // true, which frees it out from under the reference held here.
        sheet.isReleasedWhenClosed = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Preparing to share with \(destination)…")

        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        sheet.contentView = row
        sheet.setContentSize(row.fittingSize)

        window.beginSheet(sheet)
        return sheet
    }

    private func endSharePreparation(_ sheet: NSWindow) {
        window.endSheet(sheet)
    }

    /// File ▸ Save (⌘S).
    ///
    /// A document that already has a home is saved CONTINUOUSLY — every edit
    /// writes `edit.json` as it happens — so ⌘S on one has nothing left to do
    /// and says so rather than flashing a panel that changes nothing.
    ///
    /// An imported one lives in a scratch directory and has never been put
    /// anywhere on purpose, so the first ⌘S is where that is decided. After
    /// the move this is an ordinary document and the branch above applies.
    public func save() {
        guard isUnsaved else {
            AppDelegate.presentMessage(
                "This recording is already saved.\n\nEvery edit is written as you "
                + "make it, so there is nothing waiting to be saved. Use File ▸ Export "
                + "to write a video file.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Recording"
        panel.nameFieldStringValue = bundleURL.deletingPathExtension().lastPathComponent
            // The scratch name carries a uuid to keep two imports apart; the
            // person should never see it.
            .components(separatedBy: "-").dropLast(5).joined(separator: "-")
        // The app's own exported UTI (`make-app.sh`'s CFBundleDocumentTypes),
        // resolved by identifier rather than hardcoded as an extension: the
        // panel then appends `.snitt` itself and Finder shows the document
        // icon in the save sheet.
        if let type = UTType("com.impressiver.snitt.recording") {
            panel.allowedContentTypes = [type]
        }
        panel.directoryURL = OutputDirectorySettings.load().directory
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try relocate(to: destination)
        } catch {
            AppDelegate.presentMessage(
                "Snitt could not save there.\n\n\((error as NSError).localizedDescription)")
        }
    }

    /// Moves the bundle and re-points this window at it, WITHOUT reopening.
    ///
    /// Internal so a test can drive it without a save panel.
    func relocate(to destination: URL) throws {
        // A save panel already asked about overwriting, and answering yes has
        // to actually overwrite — `moveItem` refuses onto an existing path.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: bundleURL, to: destination)
        bundleURL = Self.normalizedBundleURL(destination)
        isUnsaved = false
        // The preview holds its own `SnittBundle`, and every later write goes
        // through it. Leaving it pointed at the scratch path would write edits
        // to a directory that no longer exists — silently, because the writes
        // are fire-and-forget.
        controller.relocateBundle(to: bundleURL)
        window.title = destination.deletingPathExtension().lastPathComponent
        state.documentTitle = window.title
        state.defaultExportURL = Self.defaultExportURL(forBundle: bundleURL)
        RecentDocuments.note(bundleURL)
    }

    func performExport(_ request: ExportRequest) {
        Task { @MainActor in
            do {
                try await performExport(request, pasteboard: .general)
                self.presentExportSuccess()
            } catch {
                self.presentExportFailure(error)
            }
        }
    }

    /// The resolutions worth offering for this recording, or `[]` if they
    /// could not be measured.
    ///
    /// Failure is silent by design and the only case where that is right in
    /// this file: an estimate is an aid to choosing, so losing it costs the
    /// menu and nothing else. Refusing to export because the preview of the
    /// export could not be computed would trade a working feature for a
    /// convenience.
    func exportOptions() async -> [ExportOption] {
        do {
            let bundle = try SnittBundle(opening: bundleURL)
            let estimates = try await ExportEstimator.menu(bundle: bundle, edl: state.edl)
            return ExportPreflight.options(from: estimates)
        } catch {
            Self.log.error("Export estimate failed: \(error as NSError, privacy: .public)")
            return []
        }
    }

    /// The actual export: build via `MovieExporter.export` (which builds
    /// through `CompositionBuilder`, never a second one of its own — §9),
    /// then re-copy the result to `pasteboard`, SUPERSEDING
    /// `RecordingCoordinator`'s stop-time copy of the raw, untrimmed
    /// `capture.mov`. Without this, that stale copy is the last thing that
    /// ever touched the clipboard for this recording, and a user who
    /// trimmed and pasted ships the version they just cut content out of —
    /// silently, with no error anywhere (Task 8's second defect).
    ///
    /// Rebuilds `SnittBundle` from `bundleURL` rather than keeping a
    /// `SnittBundle` of its own: `PreviewController`'s is `private` (R1 —
    /// the write belongs with the owner), and `bundleURL` is already this
    /// type's own normalized identity for exactly this document.
    ///
    /// Takes the whole `ExportRequest` rather than the three fields the
    /// sheet happens to set today. The alternative — a parameter per field —
    /// is how the test seam and the real path drift: adding `clicks` to one
    /// and not the other compiles, and the seam then proves something the
    /// app never does.
    private func performExport(_ request: ExportRequest,
                               pasteboard: NSPasteboard) async throws {
        let bundle = try SnittBundle(opening: bundleURL)
        // The sheet's overlay toggles override the document's for this one
        // export. They are seeded FROM the document when the sheet opens, so
        // leaving them alone exports what the editor was showing — but a
        // person who unticks "Draw subtitles" here must get a file without
        // them, not one that quietly follows Playback ▸ Show instead.
        var edl = state.edl
        edl.showSubtitles = request.drawSubtitles
        edl.showMarkers = request.drawMarkers
        _ = try await MovieExporter.export(
            bundle: bundle, edl: edl, scale: 1.0,
            to: request.destination, format: request.format,
            maxSizeBytes: request.maxSizeBytes,
            resolution: request.resolution, clicks: request.drawClicks)
        if !ClipboardDestination.copy(fileURL: request.destination, to: pasteboard) {
            // The export itself succeeded — the file the user asked for
            // exists at `destination` — so this is not surfaced as an
            // export failure. It IS logged: a copy that silently didn't
            // happen is exactly the kind of clipboard mismatch this task
            // exists to eliminate, just moved one step later.
            Self.log.error("Export succeeded but the clipboard copy did not.")
        }
    }

    private func presentExportSuccess() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Exported and copied to the clipboard."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Same redaction discipline as `DocumentOpener`'s catch — domain, code,
    /// never `String(describing:)` on the error and never a path — with one
    /// deliberate difference: `localizedDescription` is `.private` here.
    ///
    /// `RecordingCoordinator`'s `.public` on the same field is justified by
    /// "localizedDescription names only fixed sidecar filenames", which is
    /// true on the open paths (`manifest.json`, `edit.json`, `events.jsonl`,
    /// `capture.mov`) and FALSE here (whole-branch review F6): the export
    /// destination is chosen by the user in the export sheet's folder
    /// chooser and can be anywhere, so a Cocoa write failure names a folder of theirs in a
    /// field `snitt diagnostics export` collects verbatim.
    /// `UpdaterController` already marks this field `.private` for the same
    /// reason; this matches it rather than adding a third convention.
    private func presentExportFailure(_ error: Error) {
        let ns = error as NSError
        Self.log.error("Export failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snitt could not export this recording."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Testing seam

    /// Drives an export exactly as the export sheet's Export button would,
    /// without the sheet or the success/failure `NSAlert` (both require a
    /// live window server this test target cannot assume). `pasteboard`
    /// defaults to `.general` for parity with the real path but is
    /// overridable so a test can assert against a throwaway pasteboard
    /// instead of the machine's real clipboard.
    func exportForTesting(to url: URL, pasteboard: NSPasteboard = .general,
                          resolution: ExportResolution = .source) async throws {
        var request = ExportRequest(destination: url)
        request.resolution = resolution
        try await performExport(request, pasteboard: pasteboard)
    }

    /// Closes every editor `EditorWindowController` currently thinks is
    /// open, exactly as if each had gone through `close()`.
    ///
    /// M4a review finding #3: a test that opens an editor through
    /// `RecordingCoordinator.stopForTesting()` — which constructs the
    /// `EditorWindowController` internally and never hands it back — has no
    /// other way to tear it down, so it leaked a real window (and a bumped
    /// `openWindowCount`) for the rest of the run. `close()` itself is
    /// idempotent and per-instance; this just calls it for every instance
    /// still in `open`, using a copy of the array since `close()` mutates
    /// `open` as it runs.
    static func closeAllForTesting() {
        for editor in open {
            editor.close()
        }
    }

    /// Drives a complete select-then-cut exactly as a real drag ending
    /// followed by pressing Cut would (Task 7; D56/M5f Task 4 inserted the
    /// selection step), without a live `NSView` or SwiftUI runtime. Kept
    /// under its original `...TrimForTesting` name for the existing callers
    /// (`EditorExportTests`, `EditorPersistenceTests`) that only care about
    /// the resulting `Cut` landing in `state.edl`, not the selection D56
    /// interposed before it.
    func applyTrimForTesting(_ range: TimeRange) {
        state.onSelect(Selection(range: range))
        state.cutSelection()
    }

    /// Drives a real right-click ▸ Remove Cut (D56, M5f Task 5) exactly as
    /// `TimelineView.handleRemoveCutMenuItem` would, without a live
    /// `NSView`/`NSMenu`.
    func removeCutForTesting(id: UUID) {
        state.removeCut(id: id)
    }

    /// Drives a completed drag that only SELECTS — no Cut decision — exactly
    /// as `TimelineView.mouseUp` reporting a resolved drag would. Distinct
    /// from `applyTrimForTesting`, which selects AND immediately cuts: this
    /// exists for tests (`AppShellTests`'s Cut Selection menu validation)
    /// that need to observe `hasTimelineSelection` while something is
    /// selected but not yet turned into a `Cut`.
    func selectForTesting(_ range: TimeRange) {
        state.onSelect(Selection(range: range))
    }

    /// The in-memory EDL. Deliberately the ADJACENT property to the one
    /// `EditorPersistenceTests` cares about — see that suite's doc comments
    /// for why asserting only this would pass against the bug Task 7 fixes.
    func currentEDLForTesting() -> EditDecisionList {
        state.edl
    }

    /// The in-memory events, markers included — the events-side twin of
    /// `currentEDLForTesting()` (Task 6). Deliberately what tests assert
    /// against for a marker drag/edit's STORED result (SOURCE time, label,
    /// transcript), not `controller.jumpPoints`'s OUTPUT-time, display-only
    /// copy — the same adjacent-property trap `currentEDLForTesting()`'s own
    /// doc comment names, one field over.
    func currentEventsForTesting() -> [LoggedEvent] {
        state.events
    }

    /// Drives a real marker drag exactly as `TimelineView.mouseUp` reporting
    /// a resolved marker move would (Task 6), without a live `NSView`.
    /// `outputTime` matches `onMoveMarker`'s own parameter: OUTPUT time, the
    /// timeline's own drawing axis, converted back to SOURCE time by
    /// `EditorTimelineState.moveMarker` itself.
    func moveMarkerForTesting(id: UUID, toOutput outputTime: Double) {
        state.moveMarker(id: id, toOutput: outputTime)
    }

    /// Drives a real marker edit (label + transcript) exactly as saving the
    /// edit sheet would (Task 6), without live SwiftUI.
    func updateMarkerForTesting(id: UUID, label: String?, transcript: String?) {
        state.updateMarker(id: id, label: label, transcript: transcript)
    }

    /// Awaits the actual in-flight apply-then-persist chain, not a fixed
    /// sleep — a test that slept would be a flake this project has already
    /// paid for once.
    func waitForPendingSaveForTesting() async {
        await state.waitForPendingSave()
    }

    // MARK: - Termination (F9)

    /// Whether any open editor still has an autosave in flight.
    ///
    /// Autosave runs an unstructured `Task`, so ⌘Q (or the status item's
    /// Quit) pressed straight after a trim used to terminate the process
    /// before `apply` + `persist` finished, silently losing the edit. With
    /// F1's gate in place this is the last remaining path by which an edit
    /// disappears.
    static var hasPendingSaves: Bool {
        open.contains { $0.state.outstandingSaves > 0 }
    }

    /// Drains every open editor's autosave chain. Called from
    /// `applicationShouldTerminate` before the process exits.
    static func flushPendingSaves() async {
        for editor in open {
            await editor.state.waitForPendingSave()
        }
    }
}

/// Cross-suite serialization for tests that read `EditorWindowController`'s
/// process-global `openWindowCount` around a `before`/`after` snapshot.
///
/// `@Suite(.serialized)` (used by `DocumentOpenerTests`,
/// `EditorWindowControllerTests`, and `EditorPersistenceTests`) only
/// serializes tests WITHIN one suite — swift-testing runs different suites
/// concurrently by default. All three of those suites open real, real
/// front-ordered windows and read this same static counter, so without this
/// gate a window opened by one suite's test can land in the middle of
/// another suite's `before`/`after` window, changing the count out from
/// under an assertion that has no way to see it happening. Discovered by
/// running the full suite repeatedly after adding `EditorPersistenceTests`
/// (Task 7): two of four consecutive runs failed with
/// `EditorWindowControllerTests`'s open-count assertions off by exactly the
/// window `EditorPersistenceTests` had open at the time — not a segfault,
/// but the same class of hazard the M5c test-infrastructure note warns
/// about, one level up (a shared counter instead of a shared `NSWindow`).
///
/// `@MainActor`, not a separate `actor`: every caller here already runs on
/// `@MainActor` (these tests construct real `NSWindow`s, which requires
/// it), and `body` closures capture MainActor-isolated, non-`Sendable`
/// state (`EditorWindowController`, `PreviewController`). Routing through
/// a distinct actor would require SENDING that closure across an isolation
/// boundary — exactly the `Sendable`-crossing error `-strict-concurrency
/// =complete` exists to catch — for no benefit, since there is only ever
/// one MainActor to contend for anyway.
///
/// **Bounded, deliberately** — the same correction `SparkleTestGate` received on
/// 2026-09-09, and this gate was the LARGER exposure of the two: 52 call sites
/// across 10 files against that one's five. The original `acquire()` waited on
/// a `CheckedContinuation` with no ceiling, so a single holder that never
/// finished blocked every other windowed test forever, producing no output and
/// no failing test. A full-suite run did exactly that for ten minutes before
/// anyone could tell it apart from ordinary slow progress.
///
/// A test gate must turn a hang into a FAILURE. A failure names the culprit and
/// lets the rest of the suite finish; a hang costs the whole run and names
/// nobody. The risk is asymmetric in the same direction: too tight a bound
/// yields a loud, obvious flake, while no bound yields silence.
@MainActor
/// **An instance, with a shared one for real use.** This was an `enum` with
/// static state, which meant its OWN tests contended with every editor-window
/// test they are about: the self-test installs a deliberately stuck holder and
/// asserts a waiter's timeout names it, but the message names whoever holds
/// the gate AT THE MOMENT IT FIRES — so a real window test that took the gate
/// in between was named instead, truthfully. `SparkleTestGate` carried exactly
/// this bug and it went unattributed for four days.
///
/// A private instance removes the contention rather than timing around it,
/// which is what makes a gate's own tests deterministic under parallelism.
final class EditorWindowTestGate {

    /// The one real window tests share.
    static let shared = EditorWindowTestGate()
    /// How long a test may WAIT for the gate before giving up.
    ///
    /// Generous: window tests queue behind this gate constantly, and their
    /// reported durations under the full suite are dominated by that queueing
    /// rather than by work. This exists to catch a holder that will NEVER
    /// finish, not one that is merely slow.
    static let acquireTimeout: TimeInterval = 300

    struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    private var locked = false
    private var holderDescription = "none"

    /// Whether the gate is held, and by whom — the seam the gate's own test
    /// needs to know its holder really acquired before testing a waiter.
    var currentHolder: String? { locked ? holderDescription : nil }

    /// Forwards to `shared`, so existing call sites are unchanged.
    static var currentHolder: String? { shared.currentHolder }

    /// Polls rather than queueing on a continuation: a `CheckedContinuation`
    /// must be resumed exactly once, which makes racing it against a deadline
    /// easy to get wrong in a way that crashes the test process. On
    /// `@MainActor`, `Task.sleep` yields the actor so the holder still runs.
    /// FIFO fairness is lost and no test needs it.
    private func acquire(for label: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while locked {
            if Date() >= deadline {
                throw Timeout(description: """
                    "\(label)" waited \(Int(timeout))s for EditorWindowTestGate and gave up. \
                    It was held by "\(holderDescription)", which never released it. That holder \
                    is the defect, not this test.
                    """)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        locked = true
        holderDescription = label
    }

    private func release() {
        locked = false
        holderDescription = "none"
    }

    /// Runs `body` with the gate held for its ENTIRE duration — the whole
    /// snapshot-mutate-assert critical section a test cares about, not just
    /// the moment a window is created.
    ///
    /// `label` defaults to the calling function, so a timeout names a real test
    /// without anyone having to remember to pass a string.
    func run<T>(_ label: String = #function,
                timeout: TimeInterval = EditorWindowTestGate.acquireTimeout,
                _ body: () async throws -> T) async throws -> T {
        try await acquire(for: label, timeout: timeout)
        defer { release() }
        return try await body()
    }

    /// Forwards to `shared`. Existing call sites are unchanged.
    static func run<T>(_ label: String = #function,
                       timeout: TimeInterval = acquireTimeout,
                       _ body: () async throws -> T) async throws -> T {
        try await shared.run(label, timeout: timeout, body)
    }
}
