# M4a — Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stopping a recording opens an editor window that plays the recording through the *same* composition export writes, with the EDL's per-track mute and gain applied, and markers as jump points.

**Architecture:** `CompositionBuilder` gains an `AVAudioMix` so preview and export apply identical audio treatment. A `@MainActor` preview controller attaches `BuiltComposition` to an `AVPlayerItem` — no adapter, no second derivation. The window is an `NSWindow` hosting SwiftUI, with the `AVPlayerLayer` reached through `NSViewRepresentable` per §4.7.

**Tech Stack:** Swift 6, AVFoundation (`AVPlayer`, `AVPlayerItem`, `AVPlayerLayer`, `AVAudioMix`), AppKit (`NSWindow`, `NSHostingView`, `NSViewRepresentable`), SwiftUI, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §9 (the one-builder guarantee), §4.7 (SwiftUI shell, AppKit timeline and preview), §4.4 (edit scope), §4.12 (markers).

**Spike:** `docs/superpowers/spikes/S6-preview-and-audio-mix.md` — read it. Both of this milestone's load-bearing questions are already answered there with measurements.

**Scope note.** Spec §13's M4 is "EDL model, timeline UI with marker jump-points, preview". The EDL model shipped in M3c. This plan is the **preview half**: playback, audio mix, marker jumps, and the window that hosts them. The interactive timeline — drawing cuts, drag-to-trim, frame-accurate scrubbing — is M4b, and is deliberately excluded here. M4a ends with something a person can watch; M4b makes it something they can edit.

## Global Constraints

- Swift 6, strict concurrency, **zero warnings from `Sources/`** under `swift build -Xswiftc -strict-concurrency=complete`. Verify from a **clean** build.
- macOS 15 minimum (§4.6).
- `SnittExport` depends on `SnittDocument` only — never `SnittCapture`.
- `SnittAutomation` depends on `SnittDocument` only — never `SnittExport`. `snitt-cli` and `snitt-mcp` must not link AVFoundation (§4.9); verify with `otool -L`, not only the import scan.
- **Baseline: 349 tests** at `1d42922` from a full unfiltered run on a clean build.
- **Never block a thread from an async context** — no `DispatchSemaphore.wait()`, no `group.wait()`, no `sleep` as synchronisation.
- Every test names a plausible wrong implementation and is verified to fail against it: break the code, run it, watch it fail, restore.

## Verification traps — all of these bit us in M3d

- **`swift test` exits 0 when the test bundle segfaults.** The crash is one inline `error: … signal code 11` line among hundreds of passing ones, and the run has **no summary line**. Verify with `swift test 2>&1 | grep -E "Test run with|signal code|error:"` and **treat a missing summary as failure**.
- Piping to `grep` returns grep's exit status, so exit codes prove nothing.
- A stale incremental build produced a SIGSEGV after a struct's layout changed. **Task 1 changes `BuiltComposition`'s layout** — `rm -rf .build` before verifying it.
- Intermittent failures are real here. Run the suite **at least 3 times** before declaring green.

## Spike results — measured, do not re-derive

1. `AVPlayerItem(asset: built.composition)` with `item.videoComposition = built.videoComposition` reaches **`.readyToPlay` in ~0.1s**. `presentationSize` equals `renderSize`; `item.duration` equals the trimmed duration.
2. `AVMutableAudioMixInputParameters(track:)` binds to the composition's **own** audio tracks; `setVolume(_:at:)` expresses mute and gain; the mix attaches to the player item.
3. **`AVPlayerItem` is main-actor isolated** under Swift 6 — `init(asset:)` cannot be called off the main actor.
4. **`AVAudioMix` is non-Sendable** — it "cannot exit main actor-isolated context".

## File structure

| File | Responsibility |
|---|---|
| `Sources/SnittExport/CompositionBuilder.swift` (modify) | Build the `AVAudioMix` from the EDL's `trackStates`; carry it on `BuiltComposition`. |
| `Sources/SnittExport/MovieExporter.swift` (modify) | Apply the mix on export, so export and preview agree. |
| `Sources/SnittDocument/MarkerJumpPoints.swift` (new) | Pure: markers → preview-time jump points. No AVFoundation. |
| `Sources/SnittApp/PreviewController.swift` (new) | `@MainActor` owner of `AVPlayer`/`AVPlayerItem`. Play, pause, seek, jump. |
| `Sources/SnittApp/PlayerLayerView.swift` (new) | `NSViewRepresentable` over an `AVPlayerLayer`-backed `NSView`. |
| `Sources/SnittApp/EditorWindowController.swift` (new) | The `NSWindow`, its SwiftUI content, and activation-policy handling. |
| `Sources/SnittApp/RecordingCoordinator.swift` (modify) | Open the editor when a recording stops (§9). |

---

### Task 1: The audio mix belongs to the builder, not the preview

**Files:**
- Modify: `Sources/SnittExport/CompositionBuilder.swift`
- Modify: `Sources/SnittExport/MovieExporter.swift`
- Test: `Tests/SnittExportTests/CompositionBuilderTests.swift`

**Interfaces:**
- Consumes: `EditDecisionList.trackStates: [TrackState]` where `TrackState` is `{ track: String, muted: Bool, gain: Double }`.
- Produces: `BuiltComposition.audioMix: AVAudioMix?` — nil when there is nothing to express (no audio tracks, or every track at default gain and unmuted).

**Why this task exists, and why it is first.** M3d's whole-branch review found that `BuiltComposition` carries no audio mix, so the EDL's mute and gain are ignored by *both* preview and export. They therefore agree today — by both being wrong. The moment preview applies a mix that export does not, §9's guarantee breaks at exactly the point it was written to protect. So the mix goes in the builder, both consumers read it, and neither is allowed its own audio path.

**The `@unchecked Sendable` invariant must be restated.** `BuiltComposition` is `@unchecked Sendable`, and its soundness rests on a documented invariant: `build` returns objects it has finished mutating and never touches again. `AVAudioMix` is **non-Sendable** (spike S6), so adding it extends exactly that surface. Construct the mix inside `build`, never mutate it afterwards, and update the doc comment to say the invariant now covers three objects rather than two.

**Track naming.** `TrackState.track` is a string. The composition's audio tracks are ordered as the source's were. Map by index against a documented convention, and **state the convention in a comment**: if `trackStates` names tracks the composition does not have, or vice versa, decide what happens and write it down — silently ignoring an unmatched `TrackState` means a user mutes a track and nothing happens.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A muted track gets a zero-volume mix parameter")
func mutedTrackIsSilencedInTheMix() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 2)
    var edl = EditDecisionList()
    edl.trackStates = [TrackState(track: "audio0", muted: true, gain: 1.0),
                       TrackState(track: "audio1", muted: false, gain: 1.0)]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    #expect(mix.inputParameters.count == 2)
    // Discriminating: an implementation that builds a mix but never reads
    // `muted` produces two parameters at full volume and passes a
    // count-only assertion.
    let audioTracks = built.composition.tracks(withMediaType: AVMediaType.audio)
    let mutedID = audioTracks[0].trackID
    let mutedParams = try #require(mix.inputParameters.first { $0.trackID == mutedID })
    var volume: Float = -1
    #expect(mutedParams.getVolumeRamp(for: .zero, startVolume: &volume,
                                      endVolume: nil, timeRange: nil))
    #expect(volume == 0.0)
}

@Test("Gain is carried into the mix")
func gainIsCarriedIntoTheMix() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 1)
    var edl = EditDecisionList()
    edl.trackStates = [TrackState(track: "audio0", muted: false, gain: 0.25)]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    let params = try #require(mix.inputParameters.first)
    var volume: Float = -1
    #expect(params.getVolumeRamp(for: .zero, startVolume: &volume,
                                 endVolume: nil, timeRange: nil))
    // Discriminating against an implementation that honours `muted` but
    // ignores `gain` — it would report 1.0 here and pass the muted test.
    #expect(abs(volume - 0.25) < 0.001)
}

@Test("A recording with no audio produces no mix at all")
func noAudioMeansNoMix() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 0)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    // An empty AVAudioMix attached to a player item is not the same as no
    // mix; nil states plainly that there is nothing to apply.
    #expect(built.audioMix == nil)
}

@Test("Muting a track changes the exported file, not just the preview")
func exportAppliesTheMix() async throws {
    // §9's actual claim. An implementation that puts the mix on the player
    // item only — the obvious shortcut — passes every test above and fails
    // this one, because the exported audio would be unchanged.
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 1)
    var muted = EditDecisionList()
    muted.trackStates = [TrackState(track: "audio0", muted: true, gain: 1.0)]

    let loudOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("loud-\(UUID().uuidString).mp4")
    let quietOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("quiet-\(UUID().uuidString).mp4")
    defer {
        try? FileManager.default.removeItem(at: loudOut)
        try? FileManager.default.removeItem(at: quietOut)
    }

    _ = try await MovieExporter.export(bundle: bundle, edl: EditDecisionList(),
                                       scale: 1.0, to: loudOut)
    _ = try await MovieExporter.export(bundle: bundle, edl: muted,
                                       scale: 1.0, to: quietOut)

    // Silence encodes smaller than signal. Relative, not an absolute
    // threshold — the encoder is not deterministic under load (M3d).
    let loud = try #require(FileManager.default
        .attributesOfItem(atPath: loudOut.path)[.size] as? Int)
    let quiet = try #require(FileManager.default
        .attributesOfItem(atPath: quietOut.path)[.size] as? Int)
    #expect(quiet < loud,
            "muting a track must change the exported bytes, not only the preview")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CompositionBuilder`
Expected: FAIL — `BuiltComposition` has no `audioMix` member.

- [ ] **Step 3: Implement**

In `CompositionBuilder`, after the audio tracks are inserted:

```swift
    /// Builds the mix expressing the EDL's per-track mute and gain.
    ///
    /// Returns nil when there is nothing to express — no audio tracks, or
    /// every track unmuted at unity gain. A nil mix and an empty mix are not
    /// the same thing to a caller: nil says "nothing to apply".
    ///
    /// `trackStates` are matched to composition audio tracks BY INDEX, in the
    /// order the source declared them. A `TrackState` naming an index the
    /// recording does not have is ignored — it can only come from an EDL
    /// written against a different bundle, and refusing the whole export for
    /// it would strand a recording behind a stale sidecar.
    private static func audioMix(for tracks: [AVMutableCompositionTrack],
                                 states: [TrackState]) -> AVAudioMix? {
        guard !tracks.isEmpty else { return nil }
        let needsMix = states.contains { $0.muted || $0.gain != 1.0 }
        guard needsMix else { return nil }

        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let state = index < states.count ? states[index] : nil
            let volume = state.map { $0.muted ? 0.0 : Float($0.gain) } ?? 1.0
            parameters.setVolume(volume, at: .zero)
            return parameters
        }
        return mix
    }
```

Add `public let audioMix: AVAudioMix?` to `BuiltComposition`, populate it in `build`, and extend the `@unchecked Sendable` doc comment to name it. In `MovieExporter.exportMovie`, set `session.audioMix = built.audioMix`.

- [ ] **Step 4: Run to verify it passes**

`rm -rf .build` first — `BuiltComposition`'s layout changed. Then a full unfiltered run; expect 353.

- [ ] **Step 5: Verify the tests discriminate**

Return `nil` from `audioMix(for:states:)` unconditionally and confirm the first, second and fourth tests fail. Then honour `muted` but ignore `gain` and confirm only `gainIsCarriedIntoTheMix` fails. Then set the mix on the player item instead of the export session and confirm `exportAppliesTheMix` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittExport Tests/SnittExportTests
git commit -m "feat(export): carry the EDL's audio mix on BuiltComposition, so preview and export agree"
```

---

### Task 2: Marker jump points

**Files:**
- Create: `Sources/SnittDocument/MarkerJumpPoints.swift`
- Test: `Tests/SnittDocumentTests/MarkerJumpPointsTests.swift`

**Interfaces:**
- Consumes: `LoggedEvent { timeSeconds: Double, kind: EventKind, label: String? }`, `TimeRange`.
- Produces: `public struct JumpPoint: Equatable, Sendable { public let timeSeconds: Double; public let label: String }` and `public enum MarkerJumpPoints { public static func compute(events: [LoggedEvent], keptRanges: [TimeRange]) -> [JumpPoint] }`.

**Why it is pure and in `SnittDocument`.** It is arithmetic over timestamps, and it is the one part of the preview that can be tested exhaustively without a window, a player, or a run loop. Keeping it out of the controller is what makes the controller thin enough to trust by inspection.

**This is the same mapping `MarkerMapping` does for export**, and that is deliberate: a marker's position in the preview must equal its position in the exported file, or a chapter list and a scrub bar disagree about the same recording. Read `Sources/SnittExport/MarkerMapping.swift` first. If the logic is identical, **say so in your report** — `SnittExport` depends on `SnittDocument`, so the export-side mapper could consume this instead of duplicating it, and a reviewer should decide whether to unify rather than have two copies drift.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Markers shift by the cuts that precede them")
func markersShiftByPrecedingCuts() {
    let events = [
        LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "before"),
        LoggedEvent(timeSeconds: 8.0, kind: .marker, label: "after"),
    ]
    // 0-2 kept, 2-5 cut, 5-10 kept.
    let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 10)]

    let points = MarkerJumpPoints.compute(events: events, keptRanges: kept)

    #expect(points.count == 2)
    #expect(points[0].timeSeconds == 1.0)
    // 8.0 sits 3s into the second kept range, which begins at preview time
    // 2.0. A fixture with no cut before the marker would make this the
    // identity function and prove nothing.
    #expect(abs(points[1].timeSeconds - 5.0) < 0.001)
}

@Test("A marker inside a cut is dropped, not clamped")
func markerInsideACutIsDropped() {
    let events = [LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "gone")]
    let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 10)]
    // Clamping would invent a jump point at a moment the viewer never sees,
    // and several markers in one cut would collapse onto the same instant.
    #expect(MarkerJumpPoints.compute(events: events, keptRanges: kept).isEmpty)
}

@Test("Non-marker events are not jump points")
func onlyMarkersBecomeJumpPoints() {
    let events = [
        LoggedEvent(timeSeconds: 1.0, kind: .click, label: nil),
        LoggedEvent(timeSeconds: 1.5, kind: .marker, label: "kept"),
    ]
    let kept = [TimeRange(start: 0, end: 10)]
    let points = MarkerJumpPoints.compute(events: events, keptRanges: kept)
    // A scrub bar dotted with every click is unusable, and §4.12 scopes jump
    // points to markers.
    #expect(points.count == 1)
    #expect(points[0].label == "kept")
}

@Test("An unlabelled marker still gets a usable name")
func unlabelledMarkersAreNamed() {
    let events = [LoggedEvent(timeSeconds: 1.0, kind: .marker, label: nil)]
    let points = MarkerJumpPoints.compute(
        events: events, keptRanges: [TimeRange(start: 0, end: 10)])
    // `label` is optional on LoggedEvent. A jump point with an empty name is
    // an unclickable blank in the UI.
    #expect(points.count == 1)
    #expect(!points[0].label.isEmpty)
}

@Test("Jump points come back in ascending time order")
func jumpPointsAreSorted() {
    let events = [
        LoggedEvent(timeSeconds: 8.0, kind: .marker, label: "second"),
        LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "first"),
    ]
    let points = MarkerJumpPoints.compute(
        events: events, keptRanges: [TimeRange(start: 0, end: 10)])
    // events.json is written sorted, so this is load-bearing only for other
    // callers — which is exactly why it needs its own test rather than
    // relying on the file's ordering.
    #expect(points.map(\.label) == ["first", "second"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MarkerJumpPoints`
Expected: FAIL — `cannot find 'MarkerJumpPoints' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A marker's position in the PREVIEW's timeline, which is the trimmed
/// timeline — not its position in the original recording.
public struct JumpPoint: Equatable, Sendable {
    public let timeSeconds: Double
    public let label: String

    public init(timeSeconds: Double, label: String) {
        self.timeSeconds = timeSeconds
        self.label = label
    }
}

/// Maps markers from recording time into preview time.
///
/// The preview plays the composition, whose timeline has the cuts removed, so
/// a marker at 8s in a recording with a 3s cut before it belongs at 5s here.
/// This must agree with `MarkerMapping` on the export side: a chapter list and
/// a scrub bar that disagree about the same recording are worse than either
/// alone.
public enum MarkerJumpPoints {
    public static func compute(events: [LoggedEvent],
                               keptRanges: [TimeRange]) -> [JumpPoint] {
        guard !keptRanges.isEmpty else { return [] }
        var points: [JumpPoint] = []
        for event in events where event.kind == .marker {
            var cursor = 0.0
            for (index, range) in keptRanges.enumerated() {
                let isLast = index == keptRanges.count - 1
                let inside = isLast
                    ? (event.timeSeconds >= range.start && event.timeSeconds <= range.end)
                    : (event.timeSeconds >= range.start && event.timeSeconds < range.end)
                if inside {
                    let label = (event.label?.isEmpty == false)
                        ? event.label! : "Marker"
                    points.append(JumpPoint(
                        timeSeconds: cursor + (event.timeSeconds - range.start),
                        label: label))
                    break
                }
                cursor += range.end - range.start
            }
            // Falling through means the marker sat inside a cut: dropped.
        }
        return points.sorted { $0.timeSeconds < $1.timeSeconds }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 358.

- [ ] **Step 5: Verify the tests discriminate**

Return `event.timeSeconds` unmapped and confirm `markersShiftByPrecedingCuts` fails. Clamp instead of dropping and confirm `markerInsideACutIsDropped` fails. Drop the `kind == .marker` filter and confirm `onlyMarkersBecomeJumpPoints` fails. Remove `.sorted()` and confirm `jumpPointsAreSorted` fails. Restore each.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittDocument/MarkerJumpPoints.swift Tests/SnittDocumentTests/MarkerJumpPointsTests.swift
git commit -m "feat(preview): map markers into preview time as jump points"
```

---

### Task 3: The preview controller

**Files:**
- Create: `Sources/SnittApp/PreviewController.swift`
- Test: `Tests/SnittAppTests/PreviewControllerTests.swift`

**Interfaces:**
- Consumes: `BuiltComposition` (`composition`, `videoComposition`, `audioMix`, `duration`, `keptRanges`), `JumpPoint`.
- Produces:
```swift
@MainActor public final class PreviewController {
    public init(built: BuiltComposition, jumpPoints: [JumpPoint])
    public var player: AVPlayer { get }
    public var jumpPoints: [JumpPoint] { get }
    public var durationSeconds: Double { get }
    public func play()
    public func pause()
    public func seek(toSeconds: Double) async
    public func jump(to point: JumpPoint) async
}
```

**`@MainActor` is not a preference.** Spike S6 measured it: `AVPlayerItem.init(asset:)` is main-actor isolated under Swift 6, and `AVAudioMix` is non-Sendable. The class must be `@MainActor` or it will not compile at zero warnings.

**Attach, do not rebuild.** The controller takes a `BuiltComposition` and attaches it. It must never call `CompositionBuilder.build` itself, never construct its own `AVVideoComposition`, and never build its own audio mix — that is §9's guarantee, and a controller that "just needs a small tweak for playback" is exactly how preview and export drift apart.

**Seeking must be exact.** `AVPlayer.seek(to:)` defaults to keyframe tolerance, so a jump to a marker can land seconds away. Pass `toleranceBefore: .zero, toleranceAfter: .zero`. A test for this needs the player to actually seek, so assert on `currentTime()` after an awaited seek.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test("The controller attaches the composition it was given, not one it built")
func attachesTheGivenComposition() async throws {
    let bundle = try await makeTestBundle(seconds: 3)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 0.5)

    let controller = PreviewController(built: built, jumpPoints: [])
    let item = try #require(controller.player.currentItem)

    // Identity, not equality. A controller that rebuilds its own composition
    // produces an equivalent-looking item and passes any assertion about
    // duration or size — this is the one that catches it.
    #expect(item.asset === built.composition)
    #expect(item.videoComposition === built.videoComposition)
}

@MainActor
@Test("The player item becomes ready to play")
func itemBecomesReady() async throws {
    let bundle = try await makeTestBundle(seconds: 3)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])
    let item = try #require(controller.player.currentItem)

    var waited = 0.0
    while item.status == AVPlayerItem.Status.unknown && waited < 8.0 {
        try await Task.sleep(nanoseconds: 50_000_000); waited += 0.05
    }
    // Spike S6 measured ~0.1s. A composition the player rejects fails here
    // rather than silently showing a black frame.
    #expect(item.status == AVPlayerItem.Status.readyToPlay)
    #expect(item.error == nil)
}

@MainActor
@Test("Seeking lands exactly, not at the nearest keyframe")
func seekIsExact() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])

    await controller.seek(toSeconds: 2.5)

    // AVPlayer.seek(to:) without explicit tolerances snaps to a keyframe,
    // which on a 4-second clip can be a whole second away. This is the
    // discriminating assertion: it fails against the default-tolerance call.
    let landed = CMTimeGetSeconds(controller.player.currentTime())
    #expect(abs(landed - 2.5) < 0.05)
}

@MainActor
@Test("Jumping to a marker seeks to its preview time")
func jumpSeeksToMarkerTime() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let point = JumpPoint(timeSeconds: 1.75, label: "here")
    let controller = PreviewController(built: built, jumpPoints: [point])

    await controller.jump(to: point)

    #expect(abs(CMTimeGetSeconds(controller.player.currentTime()) - 1.75) < 0.05)
}
```

`makeTestBundle` currently lives file-private in the export tests. `SnittAppTests` has its own `SyntheticMovie.swift` — use that, and add a local `makeTestBundle` beside these tests rather than reaching across targets.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PreviewController`
Expected: FAIL — `cannot find 'PreviewController' in scope`.

- [ ] **Step 3: Implement**

```swift
import AVFoundation
import Foundation
import SnittDocument
import SnittExport

/// Owns playback for the editor's preview.
///
/// `@MainActor` by necessity, not preference: `AVPlayerItem.init(asset:)` is
/// main-actor isolated under Swift 6 and `AVAudioMix` is non-Sendable
/// (spike S6).
///
/// This type ATTACHES a `BuiltComposition`. It never builds one. §9 makes the
/// shared builder load-bearing — "the most common serious bug class in video
/// editors is an export that does not match the preview" — and a preview that
/// constructs its own composition, video composition or audio mix is how that
/// guarantee is lost, one small tweak at a time.
@MainActor
public final class PreviewController {
    public let jumpPoints: [JumpPoint]
    public let durationSeconds: Double
    private let item: AVPlayerItem
    public let player: AVPlayer

    public init(built: BuiltComposition, jumpPoints: [JumpPoint]) {
        self.jumpPoints = jumpPoints
        self.durationSeconds = built.duration
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        self.item = item
        self.player = AVPlayer(playerItem: item)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// Exact seeking. `seek(to:)` without tolerances snaps to the nearest
    /// keyframe, which puts a marker jump seconds from the marker.
    public func seek(toSeconds seconds: Double) async {
        let clamped = max(0, min(seconds, durationSeconds))
        await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func jump(to point: JumpPoint) async {
        await seek(toSeconds: point.timeSeconds)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 362.

- [ ] **Step 5: Verify the tests discriminate**

Rebuild the composition inside `init` instead of attaching, and confirm `attachesTheGivenComposition` fails on identity. Drop the tolerance arguments from `seek` and confirm `seekIsExact` fails. Stop assigning `videoComposition` and confirm the identity test fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp/PreviewController.swift Tests/SnittAppTests/PreviewControllerTests.swift
git commit -m "feat(preview): attach the built composition to a player, with exact seeking"
```

---

### Task 4: The player view and the editor window

**Files:**
- Create: `Sources/SnittApp/PlayerLayerView.swift`
- Create: `Sources/SnittApp/EditorWindowController.swift`
- Test: `Tests/SnittAppTests/EditorWindowControllerTests.swift`

**Interfaces:**
- Consumes: `PreviewController`.
- Produces: `PlayerLayerView: NSViewRepresentable`, and
```swift
@MainActor public final class EditorWindowController {
    public init(controller: PreviewController, title: String)
    public var window: NSWindow { get }
    public func show()
    public func close()
    public static var openWindowCount: Int { get }
}
```

**Why AppKit here.** §4.7: "SwiftUI's gesture and layout model fights frame-accurate scrubbing and drag-to-trim, and the preview requires an `AVPlayerLayer` regardless. Mixed is the correct architecture here, not a compromise." So the shell is SwiftUI in an `NSHostingView`, and the video surface is an `AVPlayerLayer` reached through `NSViewRepresentable`.

**The activation-policy trap.** `Sources/SnittApp/main.swift:242` sets `app.setActivationPolicy(.accessory)` — Snitt is a menu-bar app with no Dock icon. An `.accessory` app's windows **cannot become key in the normal way**, so an editor window will appear without focus, ignore keystrokes, and sit behind other apps. Switch to `.regular` when the first editor opens and back to `.accessory` when the last one closes, and call `NSApp.activate()` when showing. This is why `openWindowCount` is on the interface: the policy must follow the *count*, not a single window's lifetime, or opening two editors and closing one demotes the app while a window is still up.

**This is runtime behaviour, not pixel behaviour** — it is testable. Test the policy transitions and the count, not the appearance.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test("Opening an editor promotes the app so its window can take focus")
func openingPromotesActivationPolicy() async throws {
    NSApp.setActivationPolicy(.accessory)
    let controller = try await makePreviewController(seconds: 2)
    let editor = EditorWindowController(controller: controller, title: "demo")

    editor.show()

    // An .accessory app's windows cannot become key: the editor would open
    // unfocused, behind other apps, and ignore the keyboard. This is the
    // assertion that fails against an implementation that just orders the
    // window front.
    #expect(NSApp.activationPolicy() == .regular)
    editor.close()
}

@MainActor
@Test("Closing the last editor returns the app to the menu bar")
func closingLastEditorDemotes() async throws {
    NSApp.setActivationPolicy(.accessory)
    let editor = EditorWindowController(
        controller: try await makePreviewController(seconds: 2), title: "demo")
    editor.show()
    editor.close()
    // Leaving the app .regular would strand a Dock icon for a menu-bar app
    // with no windows.
    #expect(NSApp.activationPolicy() == .accessory)
}

@MainActor
@Test("Closing one of two editors keeps the app promoted")
func closingOneOfTwoKeepsPromotion() async throws {
    NSApp.setActivationPolicy(.accessory)
    let first = EditorWindowController(
        controller: try await makePreviewController(seconds: 2), title: "a")
    let second = EditorWindowController(
        controller: try await makePreviewController(seconds: 2), title: "b")
    first.show(); second.show()

    first.close()

    // Discriminating against a policy tied to a single window's lifetime
    // rather than to the open count — that implementation passes both tests
    // above and demotes the app while a window is still on screen.
    #expect(NSApp.activationPolicy() == .regular)
    #expect(EditorWindowController.openWindowCount == 1)
    second.close()
    #expect(NSApp.activationPolicy() == .accessory)
}

@MainActor
@Test("Pausing on close stops playback rather than leaving audio running")
func closingPausesPlayback() async throws {
    let controller = try await makePreviewController(seconds: 3)
    let editor = EditorWindowController(controller: controller, title: "demo")
    editor.show()
    controller.play()

    editor.close()

    // A closed window whose player keeps playing leaves audio coming from a
    // window the user cannot see.
    #expect(controller.player.rate == 0)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter EditorWindow`
Expected: FAIL — `cannot find 'EditorWindowController' in scope`.

- [ ] **Step 3: Implement**

`PlayerLayerView.swift`:

```swift
import AVFoundation
import AppKit
import SwiftUI

/// The video surface. An `AVPlayerLayer` is required regardless of UI
/// framework (§4.7), so it is reached through AppKit rather than approximated
/// in SwiftUI.
public struct PlayerLayerView: NSViewRepresentable {
    public let player: AVPlayer

    public init(player: AVPlayer) { self.player = player }

    public func makeNSView(context: Context) -> PlayerLayerBackedView {
        let view = PlayerLayerBackedView()
        view.playerLayer.player = player
        return view
    }

    public func updateNSView(_ nsView: PlayerLayerBackedView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

public final class PlayerLayerBackedView: NSView {
    let playerLayer = AVPlayerLayer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
```

`EditorWindowController.swift` hosts a SwiftUI view containing `PlayerLayerView`, play/pause, and a jump-point list, in an `NSWindow`. Track the open count in a static, drive the activation policy from it, call `NSApp.activate()` in `show()`, and pause the controller in `close()`.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 366.

- [ ] **Step 5: Verify the tests discriminate**

Tie the policy to a stored `isOpen` boolean rather than the count and confirm `closingOneOfTwoKeepsPromotion` fails. Remove the `pause()` from `close()` and confirm `closingPausesPlayback` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests
git commit -m "feat(preview): an editor window hosting the player layer"
```

---

### Task 5: Stopping a recording opens the editor

**Files:**
- Modify: `Sources/SnittApp/RecordingCoordinator.swift`
- Test: `Tests/SnittAppTests/RecordingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `EditorWindowController`, `PreviewController`, `CompositionBuilder.build`, `MarkerJumpPoints.compute`, `EventLog.read`.
- Produces: no new public API — a behaviour change on the existing stop path.

**Why.** §9: "Stopping opens the editor with a default EDL spanning the full range." That is the sentence this task implements.

**Two things it must not do.**

1. **An agent-initiated recording must not open a window.** §4.8 scopes automation to record-only, and §5.3 exists because agent recordings happen without a human present. An editor window appearing on someone's screen because a background agent finished a capture is exactly the surprise the consent rules were written to prevent. The coordinator already knows the initiator — read it and branch.
2. **A failed build must not take down the app.** A bundle whose `capture.mov` is unreadable should surface an error, not crash the stop path or leave the recording unfinalised. The recording is already on disk and safe by then; the editor is a convenience.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test("Stopping a human recording opens an editor")
func humanStopOpensEditor() async throws {
    let before = EditorWindowController.openWindowCount
    let coordinator = makeCoordinator()
    let bundle = try await coordinator.stopForTesting(initiator: .human)
    _ = bundle
    #expect(EditorWindowController.openWindowCount == before + 1)
}

@MainActor
@Test("Stopping an agent recording does NOT open a window")
func agentStopOpensNothing() async throws {
    // §5.3: agent recordings happen with no human present. A window
    // appearing on someone's screen because a background agent finished is
    // the surprise the consent rules exist to prevent.
    let before = EditorWindowController.openWindowCount
    let coordinator = makeCoordinator()
    _ = try await coordinator.stopForTesting(initiator: .agent)
    #expect(EditorWindowController.openWindowCount == before)
}

@MainActor
@Test("A bundle the builder cannot open still finalises the recording")
func unbuildableBundleStillStops() async throws {
    // The recording is on disk and safe before the editor is even
    // considered. Losing it because a preview could not be built would
    // trade the valuable thing for the convenient one.
    let coordinator = makeCoordinator(corruptCapture: true)
    let bundle = try await coordinator.stopForTesting(initiator: .human)
    #expect(FileManager.default.fileExists(atPath: bundle.url.path))
    #expect(EditorWindowController.openWindowCount == 0)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RecordingCoordinator`
Expected: FAIL — stopping does not open an editor.

- [ ] **Step 3: Implement**

On the human stop path, after the bundle is finalised: read the EDL (defaulting to full range), build the composition, compute jump points from `EventLog`, construct a `PreviewController` and an `EditorWindowController`, and show it. Wrap the build in a `do/catch` that logs and returns normally — the stop must succeed regardless.

- [ ] **Step 4: Run to verify it passes**

`rm -rf .build`, then a full unfiltered run at least 3 times; expect 369.

- [ ] **Step 5: Verify the tests discriminate**

Remove the initiator check and confirm `agentStopOpensNothing` fails. Let the build error propagate and confirm `unbuildableBundleStillStops` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests
git commit -m "feat(preview): open the editor when a human stops a recording"
```

---

## Self-review

**Spec coverage.** §9's "stopping opens the editor with a default EDL spanning the full range" — Task 5. §9's shared builder, now including audio — Task 1, with `exportAppliesTheMix` as the test that catches a preview-only mix. §4.7's mixed AppKit/SwiftUI split — Task 4. §4.12 markers as jump points — Tasks 2 and 3. §4.4's edit scope (trim, cut, track mute) — the mute half lands in Task 1; **cut and trim editing is M4b**, which is why this plan is named M4a.

**Deliberately excluded, and why:** drawing the timeline, drag-to-trim, and frame-accurate scrubbing. They are the interactive half of §13's M4 and want their own plan — they are where §4.7's "SwiftUI fights frame-accurate scrubbing" claim actually gets tested, and folding them in here would produce a plan too large to review in one pass. M4a ends with something watchable; M4b makes it editable.

**Known gaps a reviewer should weigh rather than assume:**

- **`MarkerJumpPoints.compute` and `MarkerMapping.map` are probably the same function.** Task 2 asks the implementer to say so explicitly rather than quietly duplicating. `SnittExport` depends on `SnittDocument`, so unification is possible in that direction only. A reviewer should decide; two copies of a time-mapping rule *will* drift, and when they do a chapter list and a scrub bar will disagree about one recording.
- **`TrackState.track` is a string matched by index.** Task 1 documents the convention and ignores unmatched states. If the real recording path ever writes track names that do not correspond positionally, this is wrong in a way no test here would catch — flag it if you know the naming.
- **The activation-policy tests mutate global `NSApp` state.** They set the policy, assert, and restore. Under parallel execution another test could observe an intermediate value. If the suite shows new flakiness around Task 4, serialise that suite before assuming the feature is wrong.
- **No test asserts that anything is visible.** Every assertion here is about state — identity, status, policy, counts, time. That is deliberate: pixels are not testable in this harness, and a test that "renders" without asserting is worse than none. The visual check belongs in the manual DoD.

**Type consistency.** `BuiltComposition.audioMix: AVAudioMix?` in Tasks 1, 3. `JumpPoint { timeSeconds, label }` in Tasks 2, 3, 4. `PreviewController(built:jumpPoints:)` in Tasks 3, 4, 5. `EditorWindowController(controller:title:)` and `openWindowCount` in Tasks 4, 5. `MarkerJumpPoints.compute(events:keptRanges:)` in Tasks 2, 5.

## Manual verification (Definition of Done)

Automated tests cover state, not appearance. These need a person:

1. Record something short with a marker (⌥⌘M), stop, and confirm the editor opens **focused and in front**.
2. Play it. Confirm video and audio, and that the window is not black.
3. Click a jump point; confirm the playhead lands on the marked moment.
4. Mute a track in the EDL, export, and confirm the exported file is silent for that track — the preview and the export must agree.
5. Close the editor; confirm the Dock icon disappears and audio stops.
6. Start an agent recording over the CLI and stop it; confirm **no window appears**.
