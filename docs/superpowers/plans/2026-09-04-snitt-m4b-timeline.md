# M4b — Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The editor gets a timeline you can scrub, with cuts drawn on it, markers as jump points, and drag-to-trim that edits the EDL — closing §13's M4.

**Architecture:** All timeline logic lives in pure, testable types — a coordinate mapper between pixels and media time, and an interaction state machine for drags. The `NSView` draws and forwards events; it holds no rules. Edits mutate the EDL and rebuild through `CompositionBuilder`, so the preview keeps showing exactly what export would write (§9).

**Tech Stack:** Swift 6, AppKit (`NSView`, `NSTrackingArea`, mouse events), AVFoundation (`AVPlayerItemVideoOutput` for frame-accurate verification), SwiftUI shell, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §4.7 (SwiftUI shell, AppKit timeline and preview), §4.4 (edit scope: trim, cut, track mute), §9 (the one-builder guarantee), §4.12 (markers).

**Spikes:** `docs/superpowers/spikes/S7-frame-accurate-observable.md` (read it — it decides how scrubbing is tested) and `S6-preview-and-audio-mix.md`.

## Global Constraints

- Swift 6, strict concurrency, **zero warnings from `Sources/`** under `swift build -Xswiftc -strict-concurrency=complete`. Verify from a **clean** build.
- macOS 15 minimum (§4.6).
- `SnittDocument` imports only Foundation — it is linked into the thin CLI client (§4.9). `SnittExport` → `SnittDocument` only. `SnittAutomation` never → `SnittExport`.
- **Baseline: 379 tests** at `42c9a18` from a full unfiltered run on a clean build.
- **Never block a thread from an async context** — no `DispatchSemaphore.wait()`, no `group.wait()`, no `sleep` as synchronisation.
- Preview and timeline types are `@MainActor` (`AVPlayerItem` is main-actor isolated, `AVAudioMix` non-Sendable — S6).
- Every test names a plausible wrong implementation and is verified to fail against it.

## Verification traps — all of these have bitten this project

- **`swift test` exits 0 when the test bundle segfaults.** The crash is one inline `error: … signal code 11` line among hundreds of passing ones, and the run has **no summary line**. Verify with `swift test 2>&1 | grep -E "Test run with|signal code|error:"` and **treat a missing summary as failure**.
- Piping to `grep` returns grep's exit status, so exit codes prove nothing.
- A stale build after a struct-layout change produced a SIGSEGV. **Task 3 changes `BuiltComposition`** — `rm -rf .build` before verifying it.
- `.serialized` serialises **within** a suite, not across suites. Two suites touching the same globals still race.
- When mutating to check a test discriminates: **assert the target string was found before writing**, and grep the mutated file before running. A mutation that does not fail is as likely to be a bad mutation as a bad test.

## Spike results — measured, do not re-derive

1. `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)` returns the **actually-decoded frame** for a composition-backed item, works on a **paused, seeked** item with no playback, and delivered a buffer on the first attempt at every target.
2. Three different seek targets gave three **distinguishable** buffers (mean fingerprints 78.82 / 157.40 / 93.39).
3. **The default fixture makes this unobservable**: `writeSyntheticMovie` fills every frame with `memset(base, 128, …)`, so every frame is identical. A per-frame-varying content mode is a prerequisite, not a nicety — that is Task 1.
4. `AVPlayer.currentTime()` reports the **seek target**, not the decoded frame (M4a). It cannot verify scrubbing.

## File structure

| File | Responsibility |
|---|---|
| `Tests/SnittAppTests/SyntheticMovie.swift` (modify) | Add `.ramp` frame content so frames are distinguishable. |
| `Sources/SnittDocument/TimelineGeometry.swift` (new) | Pure: pixels ↔ media time, and cut rectangles. No AppKit. |
| `Sources/SnittDocument/TrimGesture.swift` (new) | Pure: the drag state machine producing an EDL edit. |
| `Sources/SnittApp/TimelineView.swift` (new) | `NSView` that draws and forwards events. Holds no rules. |
| `Sources/SnittApp/PreviewController.swift` (modify) | Apply an edited EDL by rebuilding through `CompositionBuilder`. |
| `Sources/SnittApp/EditorWindowController.swift` (modify) | Host the timeline beneath the player. |

---

### Task 1: A fixture whose frames are distinguishable

**Files:**
- Modify: `Tests/SnittAppTests/SyntheticMovie.swift`, `Tests/SnittExportTests/SyntheticMovie.swift`
- Test: `Tests/SnittAppTests/SyntheticMovieTests.swift` (new)

**Interfaces:**
- Produces: `SyntheticFrameContent.ramp` — each frame filled with a value derived from its index.

**Why this is first.** Spike S7 measured that every frame of the current fixture is `memset(base, 128, …)` — identical flat gray. Any property of the form "which frame is on screen" is **unobservable** with it, which is precisely what M4b's scrubbing needs to assert. The spike's first run reported "frames indistinguishable" and that was a defect in the instrument, not a finding about the API.

This is the third time this project has had to make a fixture able to show a property: `.noise` so size targeting was observable, `.tone` so muting was observable, and now `.ramp` so frame identity is observable. **Follow the same shape: opt-in, default unchanged**, so no existing test shifts and the suite does not get slower.

**The two copies of the helper have DIVERGED, and Task 1 must handle that** — verified before this plan was written:

- `Tests/SnittExportTests/SyntheticMovie.swift` **has** `enum SyntheticFrameContent { case flat, noise }` and takes `content:`.
- `Tests/SnittAppTests/SyntheticMovie.swift` has **no such enum at all** — it hardcodes `memset(base, 128, …)` — and its signature is `(to:seconds:size:fps:maxKeyFrameInterval:audioTrackCount:)`, with a `maxKeyFrameInterval` the export copy lacks.

So this is not a symmetric two-line edit. The `SnittApp` copy needs the enum introduced (`flat` as the default, plus `ramp`) and a `content:` parameter added; the `SnittExport` copy needs only the `ramp` case. Tasks 5's `makeTestBundle(seconds:content:)` calls the `SnittApp` side, so that is the copy that must gain the parameter.

They are deliberate near-duplicates in different test targets (`SnittExport` must not depend on `SnittCapture`) and each carries a comment saying the other exists and must be kept in step. That comment is already out of date — the drift above is exactly what it was written to prevent. **Note in your report whether the two are now closer or further apart**, and do not attempt to merge them.

- [ ] **Step 1: Write the failing test**

```swift
@Test("Ramp frames are distinguishable from one another")
func rampFramesDiffer() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ramp-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeSyntheticMovie(to: url, seconds: 2, content: .ramp)

    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var fingerprints: Set<Int> = []
    for seconds in [0.2, 1.0, 1.8] {
        let image = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        fingerprints.insert(meanSample(of: image))
    }
    // The whole point. With the default `.flat` content this is 1, and every
    // "which frame is showing" assertion in M4b would pass vacuously.
    #expect(fingerprints.count == 3)
}

@Test("Flat content is still the default, so existing fixtures are unchanged")
func flatRemainsDefault() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flat-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeSyntheticMovie(to: url, seconds: 1)   // no content: argument

    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    var fingerprints: Set<Int> = []
    for seconds in [0.2, 0.8] {
        let image = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        fingerprints.insert(meanSample(of: image))
    }
    // Discriminating against making `.ramp` the default, which would silently
    // change every other fixture in the suite.
    #expect(fingerprints.count == 1)
}
```

`meanSample(of:)` is a small helper over `CGImage` — sample a sparse stride and average. Put it beside the tests.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "rampFramesDiffer|flatRemainsDefault"`
Expected: FAIL — `.ramp` is not a case of `SyntheticFrameContent`.

- [ ] **Step 3: Implement**

Add `case ramp` to `SyntheticFrameContent` in both copies, and in the frame loop:

```swift
                case .ramp:
                    // Each frame a different value, so "which frame is on
                    // screen" is observable at all. The default `.flat` fills
                    // every frame identically (spike S7), which makes every
                    // frame-identity assertion pass vacuously.
                    memset(base, Int32(20 + (videoProgress.value * 7) % 200),
                           CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
```

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 381.

- [ ] **Step 5: Verify the tests discriminate**

Make `.ramp` behave like `.flat` and confirm `rampFramesDiffer` fails. Make `.ramp` the default and confirm `flatRemainsDefault` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Tests/
git commit -m "test: add ramp frame content so frame identity is observable"
```

---

### Task 2: Timeline geometry

**Files:**
- Create: `Sources/SnittDocument/TimelineGeometry.swift`
- Test: `Tests/SnittDocumentTests/TimelineGeometryTests.swift`

**Interfaces:**
- Consumes: `TimeRange`.
- Produces:
```swift
public struct TimelineGeometry: Equatable, Sendable {
    public init(width: Double, duration: Double)
    public func time(atX x: Double) -> Double
    public func x(atTime time: Double) -> Double
    public func cutRects(_ cuts: [TimeRange]) -> [(x: Double, width: Double)]
}
```

**Why pure and in `SnittDocument`.** This is the arithmetic every timeline interaction depends on, and it is the only part testable without a window, a run loop, or a mouse. Keeping it out of the `NSView` is what makes the view thin enough to trust by inspection — §4.7 chose AppKit for gestures, not for rules.

**The properties that matter.** Round-tripping (`time(atX: x(atTime: t)) == t`), clamping at both ends, and zero-width or zero-duration not producing a division by zero or a NaN. A NaN reaching a drawing call is silent garbage on screen; the audio path already produced one NaN bug this milestone family.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Time and x round-trip")
func timeAndXRoundTrip() {
    let g = TimelineGeometry(width: 800, duration: 20)
    for t in [0.0, 3.7, 10.0, 19.99, 20.0] {
        #expect(abs(g.time(atX: g.x(atTime: t)) - t) < 0.001)
    }
}

@Test("The ends map to the ends")
func endsMapToEnds() {
    let g = TimelineGeometry(width: 800, duration: 20)
    #expect(g.x(atTime: 0) == 0)
    #expect(g.x(atTime: 20) == 800)
    #expect(g.time(atX: 0) == 0)
    #expect(abs(g.time(atX: 800) - 20) < 0.001)
}

@Test("Positions outside the view clamp instead of extrapolating")
func outOfRangeClamps() {
    let g = TimelineGeometry(width: 800, duration: 20)
    // A drag can leave the view; extrapolating gives a negative time or one
    // past the end, and an EDL cut built from it is nonsense.
    #expect(g.time(atX: -50) == 0)
    #expect(abs(g.time(atX: 900) - 20) < 0.001)
    #expect(g.x(atTime: -5) == 0)
    #expect(g.x(atTime: 25) == 800)
}

@Test("A zero-width or zero-duration timeline yields no NaN")
func degenerateGeometryIsFinite() {
    // A view gets laid out at zero width before its first real layout pass,
    // and a bundle can be a fraction of a second long. Division by either
    // produces NaN, and a NaN reaching a drawing call is silent garbage.
    let zeroWidth = TimelineGeometry(width: 0, duration: 20)
    #expect(zeroWidth.time(atX: 10).isFinite)
    #expect(zeroWidth.x(atTime: 5).isFinite)
    let zeroDuration = TimelineGeometry(width: 800, duration: 0)
    #expect(zeroDuration.time(atX: 400).isFinite)
    #expect(zeroDuration.x(atTime: 1).isFinite)
}

@Test("Cut rectangles cover the cut ranges and nothing else")
func cutRectsCoverCuts() {
    let g = TimelineGeometry(width: 800, duration: 20)
    let rects = g.cutRects([TimeRange(start: 5, end: 10)])
    #expect(rects.count == 1)
    // 5s of 20 across 800px = x 200, width 200. An implementation that maps
    // start correctly but computes width from the end coordinate rather than
    // the span passes a start-only assertion.
    #expect(abs(rects[0].x - 200) < 0.001)
    #expect(abs(rects[0].width - 200) < 0.001)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TimelineGeometry`
Expected: FAIL — `cannot find 'TimelineGeometry' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Maps between timeline pixels and media seconds.
///
/// Pure and in `SnittDocument` deliberately: this is the arithmetic every
/// timeline interaction depends on, and the only part of the timeline
/// testable without a window or a mouse. The `NSView` draws and forwards
/// events; the rules live here.
public struct TimelineGeometry: Equatable, Sendable {
    public let width: Double
    public let duration: Double

    public init(width: Double, duration: Double) {
        self.width = width
        self.duration = duration
    }

    /// Zero width or zero duration would divide to NaN, and a NaN reaching a
    /// drawing call is silent garbage on screen rather than a crash. A view
    /// is laid out at zero width before its first real layout pass, so this
    /// is reachable on every launch, not a theoretical edge.
    private var isDegenerate: Bool { width <= 0 || duration <= 0 }

    public func time(atX x: Double) -> Double {
        guard !isDegenerate else { return 0 }
        return min(max(x / width * duration, 0), duration)
    }

    public func x(atTime time: Double) -> Double {
        guard !isDegenerate else { return 0 }
        return min(max(time / duration * width, 0), width)
    }

    public func cutRects(_ cuts: [TimeRange]) -> [(x: Double, width: Double)] {
        cuts.map { cut in
            let start = x(atTime: cut.start)
            // The SPAN, not the end coordinate — those differ the moment the
            // start clamps.
            return (x: start, width: x(atTime: cut.end) - start)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 386.

- [ ] **Step 5: Verify the tests discriminate**

Remove the clamps and confirm `outOfRangeClamps` fails. Remove the `isDegenerate` guard and confirm `degenerateGeometryIsFinite` fails. Compute `cutRects` width from the end coordinate rather than the span and confirm `cutRectsCoverCuts` fails. Restore each.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittDocument/TimelineGeometry.swift Tests/SnittDocumentTests/TimelineGeometryTests.swift
git commit -m "feat(timeline): pixel-to-time geometry, clamped and NaN-free"
```

---

### Task 3: The drag gesture as a state machine

**Files:**
- Create: `Sources/SnittDocument/TrimGesture.swift`
- Test: `Tests/SnittDocumentTests/TrimGestureTests.swift`

**Interfaces:**
- Consumes: `TimelineGeometry`, `TimeRange`, `EditDecisionList`.
- Produces:
```swift
public struct TrimGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, dragging(from: Double) }
    public private(set) var phase: Phase
    public init()
    public mutating func began(atTime: Double)
    public mutating func moved(toTime: Double)
    public mutating func ended(atTime: Double) -> TimeRange?
    public var previewRange: TimeRange? { get }
}
```

**Why a state machine, and why pure.** Drag handling is where UI code usually hides its bugs, because the interesting cases — a drag that ends where it started, a drag backwards, a drag that never began — only occur under a real mouse. As a value type they are five ordinary tests.

**The cases that matter, each a real user action:**
- A **backwards drag** (right to left) must produce a normalised range, not one with `end < start`. `EditDecisionList` assumes `start <= end`; an inverted range silently cuts nothing or everything.
- A **zero-length drag** — a click, not a drag — must produce **no** cut. Clicking a timeline to seek is the most common interaction there is, and turning every click into a zero-length cut would fill the EDL with garbage.
- `ended` **without** `began` must return nil rather than crashing or inventing a range from a stale value.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A forward drag produces the range it covered")
func forwardDragProducesRange() {
    var g = TrimGesture()
    g.began(atTime: 2.0)
    g.moved(toTime: 5.0)
    let range = g.ended(atTime: 5.0)
    #expect(range == TimeRange(start: 2.0, end: 5.0))
}

@Test("A backwards drag is normalised, not inverted")
func backwardsDragIsNormalised() {
    // Dragging right-to-left is as natural as left-to-right. EditDecisionList
    // assumes start <= end, so an inverted range silently cuts nothing —
    // the user drags, sees no change, and has no idea why.
    var g = TrimGesture()
    g.began(atTime: 8.0)
    g.moved(toTime: 3.0)
    let range = g.ended(atTime: 3.0)
    #expect(range == TimeRange(start: 3.0, end: 8.0))
}

@Test("A click is not a zero-length cut")
func clickProducesNoCut() {
    // Clicking to seek is the most common timeline interaction. An
    // implementation that returns a range whenever a drag ends fills the EDL
    // with zero-length cuts, one per click.
    var g = TrimGesture()
    g.began(atTime: 4.0)
    let range = g.ended(atTime: 4.0)
    #expect(range == nil)
}

@Test("Ending without beginning yields nothing")
func endWithoutBeginYieldsNothing() {
    var g = TrimGesture()
    #expect(g.ended(atTime: 3.0) == nil)
}

@Test("A drag in progress previews the range it would cut")
func draggingPreviewsRange() {
    // The view needs to draw the pending cut while the mouse is down.
    var g = TrimGesture()
    g.began(atTime: 2.0)
    g.moved(toTime: 6.0)
    #expect(g.previewRange == TimeRange(start: 2.0, end: 6.0))
    // Discriminating against a preview that only appears after the drag
    // ends, which is a preview of nothing.
    #expect(g.phase != .idle)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TrimGesture`
Expected: FAIL — `cannot find 'TrimGesture' in scope`.

- [ ] **Step 3: Implement**

The state machine, with `normalised(_:_:)` ordering its two endpoints and a minimum-length threshold below which `ended` returns nil. State the threshold and why in a comment — it is the difference between a click and a cut, and a user's hand moves a pixel or two on any click.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 391.

- [ ] **Step 5: Verify the tests discriminate**

Return the raw `(from, to)` without normalising and confirm `backwardsDragIsNormalised` fails. Drop the minimum-length check and confirm `clickProducesNoCut` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittDocument/TrimGesture.swift Tests/SnittDocumentTests/TrimGestureTests.swift
git commit -m "feat(timeline): drag-to-trim as a pure state machine"
```

---

### Task 4: Applying an edit rebuilds through the one builder

**Files:**
- Modify: `Sources/SnittApp/PreviewController.swift`
- Test: `Tests/SnittAppTests/PreviewControllerTests.swift`

**Interfaces:**
- Produces: `PreviewController.apply(edl: EditDecisionList) async throws` — rebuilds the composition and re-attaches, keeping `jumpPoints` in step.

**Why this is the §9 task.** M4a's controller attaches a `BuiltComposition` and never builds one. Editing changes that: the timeline produces a new EDL and something must turn it into a new composition. **That something must be `CompositionBuilder.build`.** A controller that instead mutates the existing `AVMutableComposition` in place — removing a time range directly, which AVFoundation makes easy — is how preview and export drift apart, because export would still build from the EDL.

The test that catches it asserts the controller's composition is a **different object** after an edit, and that its duration matches what the builder would produce for that EDL. An in-place mutation keeps the same object.

**Jump points must be recomputed too.** They are positions in the trimmed timeline (M4a), so a new cut moves every marker after it. A controller that rebuilds the composition but keeps the old jump points puts every marker at the wrong place — and the scrub bar and the exported chapters disagree again.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test("Applying an edit rebuilds through CompositionBuilder")
func applyRebuildsComposition() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])
    let before = controller.player.currentItem?.asset

    var edited = EditDecisionList()
    edited.cuts = [TimeRange(start: 1.0, end: 2.0)]
    try await controller.apply(edl: edited)

    let after = try #require(controller.player.currentItem?.asset)
    // A controller that mutates the existing AVMutableComposition in place
    // keeps the same object and passes any duration-only assertion.
    #expect(after !== before)
    #expect(abs(controller.durationSeconds - 3.0) < 0.1)
}

@MainActor
@Test("Applying an edit moves the jump points with it")
func applyRecomputesJumpPoints() async throws {
    let bundle = try await makeTestBundle(seconds: 6)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let marker = LoggedEvent(timeSeconds: 5.0, kind: .marker, label: "late")
    let points = MarkerJumpPoints.compute(events: [marker], keptRanges: built.keptRanges)
    let controller = PreviewController(built: built, jumpPoints: points)
    #expect(abs((controller.jumpPoints.first?.timeSeconds ?? -1) - 5.0) < 0.01)

    var edited = EditDecisionList()
    edited.cuts = [TimeRange(start: 1.0, end: 3.0)]
    try await controller.apply(edl: edited, events: [marker])

    // The marker sat at 5s; a 2s cut before it moves it to 3s in the trimmed
    // timeline. A controller that rebuilds the composition but keeps the old
    // jump points leaves it at 5s, and the scrub bar disagrees with the
    // exported chapters — the exact divergence §9 exists to prevent.
    #expect(abs((controller.jumpPoints.first?.timeSeconds ?? -1) - 3.0) < 0.01)
}
```

`apply` therefore needs the events to recompute from — take them as a parameter rather than re-reading the bundle, so the controller stays a pure attach-and-rebuild unit.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "applyRebuilds|applyRecomputes"`
Expected: FAIL — no `apply` method.

- [ ] **Step 3: Implement**

`apply` builds via `CompositionBuilder.build(bundle:edl:scale:)`, recomputes jump points with `MarkerJumpPoints.compute(events:keptRanges:)` against the **new** `keptRanges`, replaces the player item, and updates `durationSeconds`. It needs the bundle and scale it was constructed with — store them.

- [ ] **Step 4: Run to verify it passes**

`rm -rf .build` first — `BuiltComposition` is involved and its layout has bitten before. Full unfiltered run; expect 393.

- [ ] **Step 5: Verify the tests discriminate**

Mutate `apply` to call `composition.removeTimeRange` on the existing object instead of rebuilding, and confirm `applyRebuildsComposition` fails on identity. Keep the old jump points and confirm `applyRecomputesJumpPoints` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp/PreviewController.swift Tests/SnittAppTests/PreviewControllerTests.swift
git commit -m "feat(timeline): applying an edit rebuilds through the shared builder"
```

---

### Task 5: Frame-accurate scrubbing, verified against the frame actually shown

**Files:**
- Modify: `Sources/SnittApp/PreviewController.swift`
- Test: `Tests/SnittAppTests/PreviewControllerTests.swift`

**Interfaces:**
- Produces: `PreviewController.currentFrameFingerprint() -> Int?` — a test-facing observable reading the decoded frame through `AVPlayerItemVideoOutput`.

**Why this task exists.** M4a documented that `AVPlayer.currentTime()` reports the **seek target**, not the decoded frame, so `seekIsExact` and `jumpSeeksToMarkerTime` cannot prove anything about where a seek landed. Spike S7 established that `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)` **can**: it returns the actually-decoded frame, works on a paused seeked item with no retries, and yields distinguishable buffers for different targets.

M4b's headline feature is frame-accurate scrubbing. Shipping it on an observable that cannot see it would repeat the whole class of defect this project keeps finding.

**This is a test seam in production code.** That is a real cost — justify it in the doc comment, keep it small, and note that `AVPlayerItemVideoOutput` must be attached at construction for it to work.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test("Seeking to different times shows different frames")
func seekingShowsDifferentFrames() async throws {
    // Requires `.ramp` content — with the default flat fixture every frame
    // is identical and this passes no matter what seeking does (spike S7).
    let bundle = try await makeTestBundle(seconds: 4, content: .ramp)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])

    var seen: Set<Int> = []
    for t in [0.5, 2.0, 3.5] {
        await controller.seek(toSeconds: t)
        seen.insert(try #require(controller.currentFrameFingerprint()))
    }
    #expect(seen.count == 3)
}

@MainActor
@Test("Seeking twice to the same time shows the same frame")
func seekingIsRepeatable() async throws {
    let bundle = try await makeTestBundle(seconds: 4, content: .ramp)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])

    await controller.seek(toSeconds: 2.0)
    let first = try #require(controller.currentFrameFingerprint())
    await controller.seek(toSeconds: 0.5)
    await controller.seek(toSeconds: 2.0)
    let second = try #require(controller.currentFrameFingerprint())

    // Discriminating against tolerant seeking: with keyframe tolerance the
    // second seek can land on a different frame than the first, which is
    // exactly the bug `toleranceBefore/.zero` prevents and which
    // `currentTime()` could never reveal.
    #expect(first == second)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "seekingShows|seekingIsRepeatable"`
Expected: FAIL — no `currentFrameFingerprint`.

- [ ] **Step 3: Implement**

Attach an `AVPlayerItemVideoOutput` in `init` (and in `apply`, on the new item). `currentFrameFingerprint()` copies the buffer at the item's current time and reduces it to an `Int` by sampling a sparse stride — S7's approach, which needs no pixel-exact comparison.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 395.

- [ ] **Step 5: Verify the tests discriminate**

Drop the zero tolerances from `seek` and confirm `seekingIsRepeatable` or `seekingShowsDifferentFrames` now fails — **this is the check M4a could not make**, and it is the reason this task exists. If neither fails even with the ramp fixture, **say so plainly with the numbers**: that would mean the observable still cannot see the property, and I want to know rather than have a test dressed up to look meaningful.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp/PreviewController.swift Tests/SnittAppTests/PreviewControllerTests.swift
git commit -m "feat(timeline): verify seeking against the frame actually decoded"
```

---

### Task 6: The timeline view

**Files:**
- Create: `Sources/SnittApp/TimelineView.swift`
- Modify: `Sources/SnittApp/EditorWindowController.swift`
- Test: `Tests/SnittAppTests/TimelineViewTests.swift`

**Interfaces:**
- Consumes: `TimelineGeometry`, `TrimGesture`, `PreviewController`.
- Produces: `@MainActor final class TimelineView: NSView` with `var onScrub: (Double) -> Void`, `var onTrim: (TimeRange) -> Void`, and `func update(duration:cuts:jumpPoints:playhead:)`.

**Why the view holds no rules.** Everything decidable lives in Tasks 2 and 3. The view converts an `NSEvent` location to a time through `TimelineGeometry`, feeds `TrimGesture`, and calls out. That keeps the untestable part — drawing and event plumbing — as small as it can be, which is the only defence available for code no test can see.

**What is testable here:** that a mouse location maps to the time the geometry says, that a drag calls `onTrim` with the normalised range, that a click calls `onScrub` and **not** `onTrim`, and that `update` with a zero-width bounds does not produce NaN. Drive these by calling `mouseDown(with:)` / `mouseDragged(with:)` / `mouseUp(with:)` directly with synthesised `NSEvent`s — no window server needed.

**Not testable, and deliberately unasserted:** anything about appearance. Do not add tests that draw without asserting; the visual check is in the manual Definition of Done below.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test("A click scrubs and does not trim")
func clickScrubsWithoutTrimming() {
    let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
    view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
    var scrubbed: Double?
    var trimmed: TimeRange?
    view.onScrub = { scrubbed = $0 }
    view.onTrim = { trimmed = $0 }

    view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
    view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))

    #expect(abs((scrubbed ?? -1) - 10.0) < 0.01)
    // Every click becoming a zero-length cut would fill the EDL with garbage.
    #expect(trimmed == nil)
}

@MainActor
@Test("A drag trims the range it covered, in either direction")
func dragTrimsNormalisedRange() {
    let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
    view.update(duration: 20, cuts: [], jumpPoints: [], playhead: 0)
    var trimmed: TimeRange?
    view.onTrim = { trimmed = $0 }

    // Right to left, the direction a naive implementation inverts.
    view.mouseDown(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
    view.mouseDragged(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
    view.mouseUp(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))

    let range = try #require(trimmed)
    #expect(abs(range.start - 5.0) < 0.01)
    #expect(abs(range.end - 15.0) < 0.01)
}

@MainActor
@Test("A zero-width view does not produce NaN")
func zeroWidthViewIsFinite() {
    // Views are laid out at zero width before their first real layout pass,
    // so this happens on every launch.
    let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 0, height: 40))
    view.update(duration: 20, cuts: [TimeRange(start: 1, end: 2)],
                jumpPoints: [], playhead: 5)
    var scrubbed: Double?
    view.onScrub = { scrubbed = $0 }
    view.mouseDown(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
    view.mouseUp(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
    #expect((scrubbed ?? .nan).isFinite)
}
```

`NSEvent.synthetic(at:in:)` is a small test helper building a `.leftMouseDown`-family event at a view-local point. Put it beside the tests.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TimelineView`
Expected: FAIL — `cannot find 'TimelineView' in scope`.

- [ ] **Step 3: Implement**

The view stores a `TimelineGeometry` rebuilt on `update` and on `layout`, a `TrimGesture`, and the two callbacks. `mouseDown` begins the gesture and scrubs; `mouseDragged` moves it and triggers a redraw; `mouseUp` ends it and calls `onTrim` when a range comes back, `onScrub` when it does not. `draw(_:)` fills the track, the cut rectangles from `cutRects`, marker ticks, and the playhead.

Wire it into `EditorWindowController` beneath the player, with `onScrub` seeking the controller and `onTrim` appending a cut to the EDL and calling `apply`.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run at least 3 times; expect 398.

- [ ] **Step 5: Verify the tests discriminate**

Call `onTrim` unconditionally on `mouseUp` and confirm `clickScrubsWithoutTrimming` fails. Use the raw drag endpoints without normalising and confirm `dragTrimsNormalisedRange` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests
git commit -m "feat(timeline): a scrubbable timeline with drag-to-trim"
```

---

## Self-review

**Spec coverage.** §13's M4 asked for "EDL model, timeline UI with marker jump-points, preview". The EDL model shipped in M3c; the preview and jump points in M4a; the timeline UI with cuts drawn, markers ticked, scrubbing and drag-to-trim is Tasks 2, 3, 6. §4.7's mixed AppKit/SwiftUI split — Task 6, with the rules pushed into Tasks 2 and 3 so the untestable part stays small. §4.4's edit scope (trim, cut, track mute) — cut and trim here, mute shipped in M4a. §9 — Task 4, which is the one that keeps editing on the shared builder.

**Deliberately excluded:** `--auto-trim-gaps` (§8 names it unscheduled, and it needs audio-aware cut points), undo/redo (not in §4.4's scope), and zooming the timeline. A recording long enough to need zoom is a real concern but not one §13 asks M4 to solve.

**Known gaps a reviewer should weigh rather than assume:**

- **Task 5 may fail to discriminate even with the ramp fixture.** S7 proved the observable distinguishes *frames*; it did not prove that dropping seek tolerance changes which frame you land on for this content. If the mutation does not fail, the honest outcome is to say so — as M4a did — not to contort the test. That would leave frame-accurate scrubbing shipped on documentation rather than proof, which is worth knowing explicitly.
- **`TrimGesture`'s minimum-length threshold is a guess.** It separates a click from a cut. Too small and a shaky click cuts a frame; too large and a deliberate short cut is ignored. Pick a value, state the reasoning, and expect a reviewer to argue with it.
- **The timeline appends cuts without merging.** Two overlapping drags produce two overlapping `TimeRange`s in the EDL. `KeptRanges.compute` already merges overlapping cuts when building, so the composition is correct — but the EDL accumulates redundant entries and the drawn rectangles overlap. Whether that matters is a judgment call; it is not a correctness bug.
- **No undo.** A mis-drag is only recoverable by editing `edit.json` by hand. That is a genuine usability gap and out of scope by §4.4, but a reviewer should confirm it is a deliberate omission rather than an oversight.

**Type consistency.** `TimelineGeometry(width:duration:)` in Tasks 2, 6. `TrimGesture` phases and `ended(atTime:) -> TimeRange?` in Tasks 3, 6. `PreviewController.apply(edl:events:)` in Tasks 4, 6. `currentFrameFingerprint()` in Task 5. `SyntheticFrameContent.ramp` in Tasks 1, 5.

## Manual verification (Definition of Done)

Automated tests here cover state and arithmetic, never appearance. These need a person:

1. Record something with two markers, stop, and confirm the timeline appears beneath the video with marker ticks at the right places.
2. Click the timeline; confirm the playhead moves there and the frame updates.
3. Drag across a section; confirm a cut is drawn and the video skips it on playback.
4. Drag right-to-left; confirm it behaves identically to left-to-right.
5. Export, and confirm the exported file has the same cuts you drew — this is §9's guarantee, checked by eye.
6. Resize the window; confirm the timeline rescales and the cuts stay on the same moments.
