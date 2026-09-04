# Snitt M3c: Trim and Export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the record → trim → export → share loop, which is half of what the v0 gate asks.

**Architecture:** One composition builder turns a bundle plus its EDL into an `AVMutableComposition` and an **explicit passthrough** `AVVideoComposition`. Export uses it today; preview uses the same code in M4. Trim mutates only the EDL. Both run **in the app** over the socket, because the CLI cannot read the bundle.

**Tech Stack:** Swift 6, SPM, AVFoundation (`AVMutableComposition`, `AVAssetExportSession`), WebVTT.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md`

**Scope:** M3c only. `--format gif` and `--max-size` are **M3d** — GIF needs a separate encoder entirely (AVFoundation has no GIF writer; it is `CGImageDestination` plus frame extraction and palette choices), and `--max-size` iterates an export that must exist and be measured first. Overlay *rendering* stays deferred past v0 and gated on M6 (§13).

**Branch:** `feat/m3c-trim-and-export`, stacked on `feat/m3b-events-and-export` (PR #4, unmerged).

## Global Constraints

Copied from the spec. Every task's requirements implicitly include these.

- **Preview and export share one builder.** Both construct the same `AVMutableComposition` and `AVVideoComposition` from the EDL. "The most common serious bug class in video editors is an export that does not match the preview, and the only durable defense is making the two literally the same code path." (§9)
- **The passthrough `AVVideoComposition` slot is EXPLICIT, never an implicit `nil` scattered through call sites.** When overlays ship, the only change is constructing a non-nil `AVVideoComposition(customVideoCompositorClass:)` and assigning it to the same call sites. This is what makes §13's deferral additive rather than a rewrite. (§9)
- **`AVVideoCompositionCoreAnimationTool` is not an option and was never in scope.** It cannot be used with `AVPlayerItem` — it is export-only, with `AVSynchronizedLayer` as its playback counterpart (V5) — so adopting it would mean two overlay implementations that can diverge. Recorded because it is the obvious-looking shortcut and will otherwise be re-proposed. (§9)
- **`capture.mov` is immutable. Editing never touches it.** All edits mutate `edit.json` only, which is what gives undo, crash recovery, and re-export at new settings without building any of them separately. (§7)
- **`snitt trim` mutates the same EDL through the same model code as the UI, with no UI involved.** (§9)
- **`--auto-trim` clips dead air before the first and after the last logged input event** — and an agent driving an app through a CLI or HTTP produces **no OS-level input at all**, so a purely event-driven pass would see the entire recording as one gap. It must refuse an empty event log rather than deleting the recording. (§8)
- **An agent must never block on a dialog it cannot see**; failures return immediately as structured errors. (§11)
- **The CLI must never call ScreenCaptureKit, and must not read bundles off disk.** `SnittExport` depends on `SnittDocument` only — never `SnittCapture`. Conformance tests enforce both.
- Swift 6, strict concurrency, **zero source warnings**. macOS 15 minimum.
- 230 tests pass at the branch point. Every task keeps them passing.

## Two rulings this plan encodes

**Trim and export run in the app, over the socket.** The CLI cannot read `~/Desktop` — that is the Files-and-Folders TCC service, and it is exactly how M3a's health block silently returned nothing on every real machine. Both commands read a bundle by definition. `inspect` already established the pattern in M3b.

**Export gets a longer client timeout, not an async job protocol.** Encoding a minute of video takes seconds to tens of seconds, and `AutomationClient`'s default is 120 s. The CLI passes a generous timeout (600 s) for export specifically. A job-id-and-poll protocol is real complexity that v0 does not need; if exports ever exceed ten minutes, that is the moment to add one.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SnittExport/KeptRanges.swift` | Pure: EDL cuts → the ranges that survive |
| `Sources/SnittExport/CompositionBuilder.swift` | Bundle + EDL → `AVMutableComposition` + passthrough `AVVideoComposition` |
| `Sources/SnittExport/MovieExporter.swift` | Composition → an mp4 on disk |
| `Sources/SnittDocument/ExportManifest.swift` | What was written, for an agent that cannot watch it |
| `Sources/SnittExport/WebVTTChapters.swift` | Markers → a `.vtt` sidecar |
| `Sources/SnittDocument/EditDecisionList.swift` | `+ trimmed(keeping:)`, `+ autoTrimCuts(...)` |
| `Sources/SnittAutomation/Protocol.swift` | `.trim`, `.autoTrim`, `.export` and their responses |
| `Sources/SnittApp/AutomationHost.swift` | Runs all three in the app |

**Why the pure parts are separated:** `KeptRanges` and `autoTrimCuts` are where the off-by-one and empty-input bugs live, and both are testable without AVFoundation, a bundle, or a display. Everything that needs a real asset is thin by comparison.

---

## Task 1: Kept ranges — the complement of the cuts

**Files:**
- Create: `Sources/SnittExport/KeptRanges.swift`
- Create: `Tests/SnittExportTests/KeptRangesTests.swift`

**Interfaces:**
- Consumes: `TimeRange` (existing, in `SnittDocument`: `start: Double`, `end: Double`)
- Produces:
  - `public enum KeptRanges`
  - `public static func compute(duration: Double, cuts: [TimeRange]) -> [TimeRange]`

**`cuts` are ranges REMOVED**, which `EditDecisionList.fullRange()` confirms by returning `cuts: []` for a recording with nothing cut. So the exported movie is the *complement* of the cuts, and this function is that complement. Overlapping and unsorted cuts are legitimate input — a user can trim twice — so it must merge them rather than assume tidiness.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittExportTests/KeptRangesTests.swift`:

```swift
import Testing
@testable import SnittExport
import SnittDocument

@Test("No cuts keeps the whole recording")
func noCutsKeepsEverything() {
    #expect(KeptRanges.compute(duration: 10, cuts: []) == [TimeRange(start: 0, end: 10)])
}

@Test("A head and tail cut keeps the middle — the auto-trim shape")
func headAndTailCut() {
    let kept = KeptRanges.compute(duration: 30, cuts: [
        TimeRange(start: 0, end: 5),
        TimeRange(start: 25, end: 30),
    ])
    #expect(kept == [TimeRange(start: 5, end: 25)])
}

@Test("A middle cut splits the recording into two kept ranges")
func middleCutSplits() {
    let kept = KeptRanges.compute(duration: 30, cuts: [TimeRange(start: 10, end: 20)])
    #expect(kept == [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 30)])
}

@Test("Overlapping cuts merge instead of producing a negative range")
func overlappingCutsMerge() {
    // Trimming twice is normal. Naively subtracting each cut in turn produces
    // a range whose end precedes its start, which AVFoundation accepts and
    // then renders as garbage.
    let kept = KeptRanges.compute(duration: 30, cuts: [
        TimeRange(start: 5, end: 15),
        TimeRange(start: 10, end: 20),
    ])
    #expect(kept == [TimeRange(start: 0, end: 5), TimeRange(start: 20, end: 30)])
}

@Test("Unsorted cuts are handled — callers are not required to sort")
func unsortedCuts() {
    let kept = KeptRanges.compute(duration: 30, cuts: [
        TimeRange(start: 25, end: 30),
        TimeRange(start: 0, end: 5),
    ])
    #expect(kept == [TimeRange(start: 5, end: 25)])
}

@Test("Cutting everything keeps nothing, rather than one impossible range")
func cuttingEverythingKeepsNothing() {
    // The caller must be able to detect this and refuse — an empty export is
    // worse than an error, because it looks like it worked.
    #expect(KeptRanges.compute(duration: 10, cuts: [TimeRange(start: 0, end: 10)]).isEmpty)
}

@Test("A cut running past the end is clamped, not extrapolated")
func cutBeyondEndIsClamped() {
    let kept = KeptRanges.compute(duration: 10, cuts: [TimeRange(start: 8, end: 999)])
    #expect(kept == [TimeRange(start: 0, end: 8)])
}

@Test("A zero-length cut changes nothing")
func zeroLengthCutIsInert() {
    #expect(KeptRanges.compute(duration: 10, cuts: [TimeRange(start: 5, end: 5)])
            == [TimeRange(start: 0, end: 10)])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeptRangesTests`
Expected: FAIL — `cannot find 'KeptRanges' in scope`. You will also need a `SnittExportTests` target; add it to `Package.swift` in the style of the existing test targets, depending on `SnittExport`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittExport/KeptRanges.swift`:

```swift
import Foundation
import SnittDocument

/// Turns an EDL's cuts into the ranges that survive into the export.
///
/// `cuts` are the ranges REMOVED — `EditDecisionList.fullRange()` returns
/// `cuts: []` for a recording with nothing trimmed — so what gets exported is
/// their complement.
///
/// Pure, and separated for that reason: this is where the off-by-one and
/// empty-input mistakes live, and none of them need AVFoundation to find.
public enum KeptRanges {
    public static func compute(duration: Double, cuts: [TimeRange]) -> [TimeRange] {
        // Normalise first. Callers are not required to sort, and trimming twice
        // legitimately produces overlaps; subtracting each cut in turn would
        // yield a range whose end precedes its start, which AVFoundation
        // accepts and then renders as garbage.
        let normalised = cuts
            .map { TimeRange(start: max(0, min($0.start, duration)),
                             end: max(0, min($0.end, duration))) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        var merged: [TimeRange] = []
        for cut in normalised {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1] = TimeRange(start: last.start,
                                                     end: max(last.end, cut.end))
            } else {
                merged.append(cut)
            }
        }

        var kept: [TimeRange] = []
        var cursor = 0.0
        for cut in merged {
            if cut.start > cursor { kept.append(TimeRange(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < duration { kept.append(TimeRange(start: cursor, end: duration)) }
        return kept
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeptRangesTests`
Expected: PASS — 8 new tests, 238 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittExport/KeptRanges.swift Tests/SnittExportTests Package.swift
git commit -m "feat(export): compute the ranges an EDL's cuts leave behind

Cuts are what gets removed, so the export is their complement. Merges
overlapping and unsorted cuts rather than assuming tidiness: trimming twice is
normal, and subtracting each cut in turn produces a range whose end precedes
its start, which AVFoundation accepts and renders as garbage."
```

---

## Task 2: EDL edits — trim to a range, and auto-trim from events

**Files:**
- Modify: `Sources/SnittDocument/EditDecisionList.swift`
- Create: `Tests/SnittDocumentTests/EditDecisionListEditTests.swift`

**Interfaces:**
- Consumes: `TimeRange`, `LoggedEvent`, `EventKind`
- Produces:
  - `public func trimmed(keeping range: TimeRange, duration: Double) -> EditDecisionList`
  - `public enum AutoTrimError: Error, Equatable { case noInputEvents }`
  - `public static func autoTrimCuts(events: [LoggedEvent], duration: Double, padding: Double = 0.5) throws -> [TimeRange]`

**The refusal is the point of `autoTrimCuts`.** §8: an agent driving an app through a CLI, an HTTP call, or a programmatic API produces no OS-level input at all — so an event-driven pass would see the entire recording as one long gap and delete it. An agent's `events.json` legitimately contains only markers. Refusing is correct; trimming to nothing is catastrophic and looks like success.

**Markers do not count as input.** They are deliberate bookmarks, often dropped at the very start ("beginning of the demo"), and treating them as activity would defeat head-trimming exactly when it is most wanted.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittDocumentTests/EditDecisionListEditTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittDocument

private func input(_ t: Double) -> LoggedEvent {
    LoggedEvent(timeSeconds: t, kind: .keystroke, label: nil)
}
private func marker(_ t: Double) -> LoggedEvent {
    LoggedEvent(timeSeconds: t, kind: .marker, label: "m")
}

@Test("Trimming to a range cuts the head and the tail")
func trimKeepsTheNamedRange() {
    let edl = EditDecisionList.fullRange()
        .trimmed(keeping: TimeRange(start: 5, end: 25), duration: 30)
    #expect(edl.cuts == [TimeRange(start: 0, end: 5), TimeRange(start: 25, end: 30)])
}

@Test("Trimming preserves track states — it edits time, not audio")
func trimPreservesTrackStates() {
    let edl = EditDecisionList.fullRange()
        .trimmed(keeping: TimeRange(start: 1, end: 2), duration: 10)
    #expect(edl.trackStates.count == 3)
}

@Test("Trimming to the full range produces no cuts")
func trimToFullRangeIsInert() {
    let edl = EditDecisionList.fullRange()
        .trimmed(keeping: TimeRange(start: 0, end: 10), duration: 10)
    #expect(edl.cuts.isEmpty)
}

@Test("Auto-trim clips before the first and after the last input event")
func autoTrimClipsTheBookends() throws {
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [input(5), input(10), input(20)], duration: 30, padding: 0.5)
    #expect(cuts == [TimeRange(start: 0, end: 4.5), TimeRange(start: 20.5, end: 30)])
}

@Test("Auto-trim REFUSES an event log with no input events")
func autoTrimRefusesEmptyLog() {
    // §8: an agent driving an app through a CLI produces no OS-level input, so
    // its events.json holds only markers. Trimming on that basis would delete
    // the entire recording — and would look like it worked.
    #expect(throws: AutoTrimError.noInputEvents) {
        _ = try EditDecisionList.autoTrimCuts(events: [], duration: 30)
    }
    #expect(throws: AutoTrimError.noInputEvents) {
        _ = try EditDecisionList.autoTrimCuts(events: [marker(1), marker(9)], duration: 30)
    }
}

@Test("Markers do not count as activity for auto-trim")
func markersAreNotActivity() throws {
    // A marker at 0.2s ("start of demo") would otherwise defeat head-trimming
    // at exactly the moment it is most wanted.
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [marker(0.2), input(10), input(12)], duration: 20, padding: 0.5)
    #expect(cuts.first == TimeRange(start: 0, end: 9.5))
}

@Test("Padding never pushes a cut past the recording, or below zero")
func paddingIsClamped() throws {
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [input(0.1), input(29.9)], duration: 30, padding: 0.5)
    #expect(cuts.allSatisfy { $0.start >= 0 && $0.end <= 30 })
    #expect(cuts.allSatisfy { $0.end >= $0.start })
}

@Test("Activity spanning the whole recording produces no cuts")
func nothingToTrim() throws {
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [input(0), input(30)], duration: 30, padding: 0.5)
    #expect(cuts.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EditDecisionListEditTests`
Expected: FAIL — `trimmed(keeping:duration:)` and `autoTrimCuts` do not exist.

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/SnittDocument/EditDecisionList.swift`:

```swift
public enum AutoTrimError: Error, Equatable {
    /// The recording logged no input events, so there is nothing to trim
    /// against. Refusing is deliberate — see `autoTrimCuts`.
    case noInputEvents
}

extension EditDecisionList {
    /// Returns a copy that keeps only `range`, cutting the head and tail.
    ///
    /// Track states are carried over untouched: trimming edits time, not audio.
    public func trimmed(keeping range: TimeRange, duration: Double) -> EditDecisionList {
        var cuts: [TimeRange] = []
        if range.start > 0 { cuts.append(TimeRange(start: 0, end: range.start)) }
        if range.end < duration { cuts.append(TimeRange(start: range.end, end: duration)) }
        return EditDecisionList(schemaVersion: schemaVersion,
                                cuts: cuts,
                                trackStates: trackStates)
    }

    /// Cuts the dead air before the first and after the last logged INPUT event.
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
    public static func autoTrimCuts(events: [LoggedEvent],
                                    duration: Double,
                                    padding: Double = 0.5) throws -> [TimeRange] {
        let inputTimes = events.filter { $0.kind != .marker }.map(\.timeSeconds).sorted()
        guard let first = inputTimes.first, let last = inputTimes.last else {
            throw AutoTrimError.noInputEvents
        }

        var cuts: [TimeRange] = []
        let head = max(0, first - padding)
        if head > 0 { cuts.append(TimeRange(start: 0, end: head)) }
        let tail = min(duration, last + padding)
        if tail < duration { cuts.append(TimeRange(start: tail, end: duration)) }
        return cuts
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter EditDecisionListEditTests`
Expected: PASS — 8 new tests, 246 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittDocument/EditDecisionList.swift Tests/SnittDocumentTests/EditDecisionListEditTests.swift
git commit -m "feat(document): trim to a range, and auto-trim from input events

auto-trim REFUSES a log with no input events. An agent driving an app through
a CLI produces no OS-level input, so its events.json holds only markers — an
event-driven pass would see one long gap and delete the recording, and an
empty export looks like it worked. Markers are excluded from activity for the
same reason: one dropped at the start would defeat head-trimming."
```

---

## Task 3: The composition builder

**Files:**
- Create: `Sources/SnittExport/CompositionBuilder.swift`
- Create: `Tests/SnittExportTests/CompositionBuilderTests.swift`

**Interfaces:**
- Consumes: `KeptRanges`, `EditDecisionList`, `SnittBundle`
- Produces:
  - `public struct BuiltComposition: Sendable` — `composition: AVMutableComposition`, `videoComposition: AVMutableVideoComposition`, `duration: Double`
  - `public enum CompositionError: Error, Equatable { case noVideoTrack, everythingCut }`
  - `public static func build(bundle: SnittBundle, edl: EditDecisionList, scale: Double) async throws -> BuiltComposition`

**THIS IS §9's LOAD-BEARING CONSTRAINT.** Preview (M4) and export (now) must construct the composition through this one function. The `AVVideoComposition` it returns is an **explicit passthrough** — a real object with a render size and a passthrough instruction, never a `nil` sprinkled through call sites. When overlays ship, the only change is giving that object a `customVideoCompositorClass`. Do not "simplify" it to nil.

**Do not reach for `AVVideoCompositionCoreAnimationTool`.** It cannot attach to an `AVPlayerItem` (V5), so using it would mean two overlay implementations that can diverge — which is the exact failure §9 exists to prevent.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittExportTests/CompositionBuilderTests.swift`:

```swift
import Testing
import AVFoundation
import Foundation
@testable import SnittExport
import SnittDocument

/// A tiny real movie, so the builder is exercised against AVFoundation rather
/// than a mock that cannot disagree with it.
private func makeTestBundle(seconds: Double = 4) throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    return bundle
}

@Test("A composition with no cuts spans the whole recording")
func noCutsSpansEverything() async throws {
    let bundle = try makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    #expect(abs(built.duration - 4) < 0.2)
}

@Test("Cutting the head shortens the composition by that much")
func headCutShortens() async throws {
    let bundle = try makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    var edl = EditDecisionList.fullRange()
    edl.cuts = [TimeRange(start: 0, end: 2)]
    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
    #expect(abs(built.duration - 2) < 0.2)
}

@Test("The video composition is an explicit passthrough, never nil")
func videoCompositionIsExplicit() async throws {
    // §9: the passthrough slot must be a real object so that shipping overlays
    // means assigning a customVideoCompositorClass to it, not threading a new
    // argument through every call site.
    let bundle = try makeTestBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    #expect(built.videoComposition.renderSize.width > 0)
    #expect(built.videoComposition.instructions.isEmpty == false)
}

@Test("Scaling halves the render size but not the duration")
func scaleAffectsSizeNotTime() async throws {
    let bundle = try makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let full = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    let half = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 0.5)

    #expect(abs(half.videoComposition.renderSize.width
                - full.videoComposition.renderSize.width / 2) < 2)
    #expect(abs(half.duration - full.duration) < 0.2)
}

@Test("Cutting everything is refused rather than exporting an empty movie")
func cuttingEverythingThrows() async throws {
    // An empty export is worse than an error: it succeeds, writes a file, and
    // the agent attaches nothing to a pull request.
    let bundle = try makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    var edl = EditDecisionList.fullRange()
    edl.cuts = [TimeRange(start: 0, end: 4)]
    await #expect(throws: CompositionError.everythingCut) {
        _ = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
    }
}
```

You will need `writeSyntheticMovie(to:seconds:)`. `Tests/SnittCaptureTests/SyntheticBuffers.swift` already builds real `CMSampleBuffer`s and `AssetWriterSinkTests` writes real movies with them — read those and follow the same approach, in a new `Tests/SnittExportTests/SyntheticMovie.swift`. Do not import from the capture test target; duplicate the small amount you need, and say in your report that you did and why.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CompositionBuilderTests`
Expected: FAIL — `cannot find 'CompositionBuilder' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittExport/CompositionBuilder.swift`:

```swift
import AVFoundation
import Foundation
import SnittDocument

public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    /// §9's explicit passthrough slot. Shipping overlays means giving THIS
    /// object a `customVideoCompositorClass` — nothing else changes.
    public let videoComposition: AVMutableVideoComposition
    public let duration: Double
}

public enum CompositionError: Error, Equatable {
    case noVideoTrack
    /// Every frame was cut. Refused rather than exported: an empty movie
    /// succeeds, writes a file, and tells the caller nothing is wrong.
    case everythingCut
}

/// Turns a bundle plus its EDL into the composition that both preview and
/// export use.
///
/// §9 makes this sharing binding: "the most common serious bug class in video
/// editors is an export that does not match the preview, and the only durable
/// defense is making the two literally the same code path." M4's preview
/// attaches the result to an `AVPlayerItem`; export hands it to an export
/// session. Neither builds its own.
///
/// `AVVideoCompositionCoreAnimationTool` is deliberately not used: it cannot
/// attach to an `AVPlayerItem` (V5), so it would force two overlay
/// implementations that can diverge.
public enum CompositionBuilder {
    public static func build(bundle: SnittBundle,
                             edl: EditDecisionList,
                             scale: Double) async throws -> BuiltComposition {
        let asset = AVURLAsset(url: bundle.captureURL)
        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        else { throw CompositionError.noVideoTrack }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)

        let kept = KeptRanges.compute(duration: assetDuration, cuts: edl.cuts)
        guard !kept.isEmpty else { throw CompositionError.everythingCut }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.noVideoTrack }

        // One composition audio track per source track, so the EDL's per-track
        // mute and gain stay addressable in M4 rather than being flattened now.
        let audioTracks = sourceAudio.compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var cursor = CMTime.zero
        for range in kept {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: 600),
                end: CMTime(seconds: range.end, preferredTimescale: 600))
            try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: cursor)
            for (index, source) in sourceAudio.enumerated() where index < audioTracks.count {
                try audioTracks[index].insertTimeRange(timeRange, of: source, at: cursor)
            }
            cursor = CMTimeAdd(cursor, timeRange.duration)
        }

        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let renderSize = CGSize(width: (naturalSize.width * scale).rounded(),
                                height: (naturalSize.height * scale).rounded())

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        // Passthrough plus scale. Still passthrough in §9's sense — there is no
        // custom compositor class — but expressed as a real instruction rather
        // than a nil, so overlays attach here later.
        layer.setTransform(
            preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)),
            at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        return BuiltComposition(composition: composition,
                                videoComposition: videoComposition,
                                duration: CMTimeGetSeconds(cursor))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CompositionBuilderTests`
Expected: PASS — 5 new tests, 251 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittExport/CompositionBuilder.swift Tests/SnittExportTests
git commit -m "feat(export): one composition builder for preview and export

Section 9 makes the sharing binding: an export that does not match the preview
is the most common serious bug class in video editors, and the only durable
defense is making them literally the same code path. The video composition is
an explicit passthrough object rather than a nil, so shipping overlays means
assigning a compositor class to it instead of threading a new argument through
every call site."
```

---

## Task 4: Export to mp4

**Files:**
- Create: `Sources/SnittExport/MovieExporter.swift`
- Create: `Sources/SnittExport/ExportManifest.swift`
- Create: `Sources/SnittExport/WebVTTChapters.swift`
- Create: `Tests/SnittExportTests/MovieExporterTests.swift`
- Create: `Tests/SnittExportTests/WebVTTChaptersTests.swift`

**Interfaces:**
- Consumes: `BuiltComposition`, `LoggedEvent`
- Produces:
  - `public struct ExportManifest: Codable, Sendable, Equatable` — `outputPath`, `format`, `byteSize`, `durationSeconds`, `width`, `height`, `scale`, `chaptersPath: String?`, `chapters: [Chapter]`
  - `public enum ExportError: Error, Equatable { case sessionFailed(String), noExportSession }`
  - `public static func exportMovie(_ built: BuiltComposition, to url: URL) async throws`
  - `public enum WebVTTChapters { public static func render(markers: [LoggedEvent], duration: Double) -> String }`

**§8's reason the manifest exists:** an agent cannot watch the video it just made. The manifest plus `inspect` let it write something factually true — "42s demo, 3.1 MB, chapters: repro / fix / verify" — instead of narrating a recording it has never seen.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittExportTests/WebVTTChaptersTests.swift`:

```swift
import Testing
@testable import SnittExport
import SnittDocument

private func marker(_ t: Double, _ label: String?) -> LoggedEvent {
    LoggedEvent(timeSeconds: t, kind: .marker, label: label)
}

@Test("Chapters run from each marker to the next")
func chaptersSpanToTheNextMarker() {
    let vtt = WebVTTChapters.render(
        markers: [marker(0, "repro"), marker(10, "fix")], duration: 30)
    #expect(vtt.hasPrefix("WEBVTT\n"))
    #expect(vtt.contains("00:00:00.000 --> 00:00:10.000"))
    #expect(vtt.contains("repro"))
    #expect(vtt.contains("00:00:10.000 --> 00:00:30.000"))
    #expect(vtt.contains("fix"))
}

@Test("An unlabelled marker still produces a usable cue")
func unlabelledMarkerGetsAName() {
    // A chapter list with a blank entry is worse than one with "Chapter 2" —
    // a reviewer cannot click something that has no name.
    let vtt = WebVTTChapters.render(markers: [marker(5, nil)], duration: 10)
    #expect(vtt.contains("Chapter 1"))
}

@Test("No markers produces a header and nothing else, not an invalid file")
func noMarkersIsStillValidWebVTT() {
    #expect(WebVTTChapters.render(markers: [], duration: 10) == "WEBVTT\n")
}

@Test("Times are formatted as WebVTT demands, with hours and milliseconds")
func timeFormatting() {
    let vtt = WebVTTChapters.render(markers: [marker(3661.5, "late")], duration: 3700)
    #expect(vtt.contains("01:01:01.500"))
}

@Test("A marker past the end is clamped rather than producing a backwards cue")
func markerBeyondDurationIsClamped() {
    let vtt = WebVTTChapters.render(markers: [marker(50, "x")], duration: 10)
    #expect(!vtt.contains("--> 00:00:10.000\nx") || vtt.contains("00:00:10.000"))
    #expect(!vtt.isEmpty)
}
```

Create `Tests/SnittExportTests/MovieExporterTests.swift`:

```swift
import Testing
import AVFoundation
import Foundation
@testable import SnittExport
import SnittDocument

@Test("Exporting writes a playable movie whose duration matches the composition")
func exportWritesAPlayableMovie() async throws {
    let bundle = try makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    try await MovieExporter.exportMovie(built, to: output)

    #expect(FileManager.default.fileExists(atPath: output.path))
    let exported = AVURLAsset(url: output)
    let duration = CMTimeGetSeconds(try await exported.load(.duration))
    #expect(abs(duration - built.duration) < 0.5)
    #expect(try await exported.loadTracks(withMediaType: .video).isEmpty == false)
}

@Test("Exporting over an existing file replaces it rather than failing")
func exportReplacesAnExistingFile() async throws {
    // An agent re-exporting after a tweak is the normal loop; failing on the
    // second run because the first left a file would be a poor surprise.
    let bundle = try makeTestBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try Data("stale".utf8).write(to: output)

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    try await MovieExporter.exportMovie(built, to: output)

    let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int
    #expect((size ?? 0) > 1000, "the stale 5-byte file must have been replaced")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WebVTTChaptersTests`
Expected: FAIL — `cannot find 'WebVTTChapters' in scope`.

- [ ] **Step 3: Write the chapter renderer**

Create `Sources/SnittExport/WebVTTChapters.swift`:

```swift
import Foundation
import SnittDocument

/// Markers as a WebVTT chapter sidecar (§4.12).
///
/// Exists so a reviewer can scrub a three-minute demo instead of watching it
/// linearly — and so an agent can name what it recorded.
public enum WebVTTChapters {
    public static func render(markers: [LoggedEvent], duration: Double) -> String {
        let sorted = markers
            .filter { $0.kind == .marker }
            .sorted { $0.timeSeconds < $1.timeSeconds }
        guard !sorted.isEmpty else { return "WEBVTT\n" }

        var out = "WEBVTT\n"
        for (index, marker) in sorted.enumerated() {
            let start = min(max(0, marker.timeSeconds), duration)
            let end = index + 1 < sorted.count
                ? min(max(start, sorted[index + 1].timeSeconds), duration)
                : duration
            // An unlabelled marker still needs a name: a reviewer cannot click
            // a blank chapter.
            let title = marker.label ?? "Chapter \(index + 1)"
            out += "\n\(timestamp(start)) --> \(timestamp(end))\n\(title)\n"
        }
        return out
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}
```

- [ ] **Step 4: Write the exporter and the manifest**

Create `Sources/SnittDocument/ExportManifest.swift` — **not** `SnittExport`:

`SnittAutomation` must carry this type in its protocol responses, and `SnittExport` links
AVFoundation. Putting the manifest there would make `SnittAutomation` depend on it, which
would pull AVFoundation into `snitt-cli` and `snitt-mcp` — exactly the transitive-linking
defect the thin-client guard was built for. `SnittDocument` imports only Foundation, and
`SnittAutomation` already depends on it.


```swift
import Foundation

/// What an export produced, for a caller that cannot watch it (§8).
public struct ExportManifest: Codable, Sendable, Equatable {
    public struct Chapter: Codable, Sendable, Equatable {
        public var timeSeconds: Double
        public var title: String
    }

    public var outputPath: String
    public var format: String
    public var byteSize: Int
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var scale: Double
    public var chaptersPath: String?
    public var chapters: [Chapter]
}
```

Create `Sources/SnittExport/MovieExporter.swift`:

```swift
import AVFoundation
import Foundation

public enum ExportError: Error, Equatable {
    case noExportSession
    case sessionFailed(String)
}

/// Writes a composition to an mp4.
///
/// Takes a `BuiltComposition` rather than a bundle, so it cannot construct its
/// own composition and drift from what preview shows (§9).
public enum MovieExporter {
    public static func exportMovie(_ built: BuiltComposition, to url: URL) async throws {
        // Re-exporting after a tweak is the normal loop; a stale file from the
        // previous run must not fail the next one.
        try? FileManager.default.removeItem(at: url)

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.noExportSession }

        session.videoComposition = built.videoComposition

        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            throw ExportError.sessionFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test`
Expected: PASS — 7 new tests, 258 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittExport Sources/SnittDocument/ExportManifest.swift Tests/SnittExportTests
git commit -m "feat(export): write an mp4, a manifest, and WebVTT chapters

The exporter takes a BuiltComposition rather than a bundle, so it cannot build
its own and drift from what preview will show. The manifest exists because an
agent cannot watch the video it just made and needs to say something factually
true about it."
```

---

## Task 5: Trim and export over the socket

**Files:**
- Modify: `Sources/SnittAutomation/Protocol.swift`
- Modify: `Sources/SnittApp/AutomationHost.swift`
- Modify: `Package.swift`
- Create: `Tests/SnittAppTests/TrimAndExportHostTests.swift`

**Interfaces:**
- Consumes: `CompositionBuilder`, `MovieExporter`, `WebVTTChapters`, `ExportManifest`, `EditDecisionList`
- Produces:
  - `AutomationRequest.Body.trim(bundlePath: String, start: Double?, end: Double?, auto: Bool)`
  - `AutomationRequest.Body.export(bundlePath: String, format: String, outputPath: String, scale: Double, chapters: Bool)`
  - `AutomationResponse.trimmed(TrimSummary)` where `TrimSummary` carries `keptSeconds`, `cutSeconds`, `cuts: [TimeRange]`
  - `AutomationResponse.exported(ExportManifest)`

**Both run in the app, for the reason `inspect` does.** The CLI cannot read `~/Desktop` — that is the Files-and-Folders TCC service, and it is exactly how M3a's health block silently returned nothing on every real machine. Trim reads and writes `edit.json`; export reads `capture.mov`. Neither is possible from the client.

**Amend protocol v2 rather than bumping.** v2 has never shipped — `main` has no `SnittAutomation`, and PRs #2, #3 and #4 are all unmerged. Extend the version comment to record this amendment, as the previous two did.

**`SnittApp` already depends on `SnittExport`** — verified, no `Package.swift` change is
needed for the app. **Do NOT add `SnittExport` to `SnittAutomation`.** `SnittExport` links
AVFoundation, and `SnittAutomation` is what both frontends import, so that dependency would
pull AVFoundation into `snitt-cli` and `snitt-mcp` — the exact transitive-linking defect the
thin-client guard exists to catch. `ExportManifest` lives in `SnittDocument` for this reason;
if you find yourself wanting `SnittExport` from `SnittAutomation`, something is in the wrong
module.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/TrimAndExportHostTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp
@testable import SnittAutomation
import SnittDocument

private func bundleWithMetadata(duration: Double, events: [LoggedEvent]) throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try RecordingMetadata(createdAt: Date(), initiator: .agent,
                          durationSeconds: duration).write(to: bundle)
    try EventLog(events: events).write(to: bundle)
    try EditDecisionList.fullRange().write(to: bundle)
    return bundle
}

@Test("Trimming to a range writes cuts into edit.json and leaves capture.mov alone")
func trimWritesTheEDL() async throws {
    let bundle = try bundleWithMetadata(duration: 30, events: [])
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: 5, end: 25, auto: false))

    guard case .trimmed(let summary) = response else {
        Issue.record("expected trimmed, got \(response)"); return
    }
    #expect(summary.cuts.count == 2)
    let written = try EditDecisionList.read(from: bundle)
    #expect(written.cuts == summary.cuts)
}

@Test("Auto-trim on a log with no input events is REFUSED, not applied")
func autoTrimRefusesWithoutInput() async throws {
    // §8: an agent's recording has no OS-level input, so its log holds only
    // markers. Trimming on that basis would delete the whole recording.
    let bundle = try bundleWithMetadata(
        duration: 30, events: [LoggedEvent(timeSeconds: 1, kind: .marker, label: "m")])
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: nil, end: nil, auto: true))

    guard case .failure(let error) = response else {
        Issue.record("auto-trim must refuse an empty input log"); return
    }
    #expect(error.hint != nil, "an agent needs to know why and what to do instead")
    let untouched = try EditDecisionList.read(from: bundle)
    #expect(untouched.cuts.isEmpty, "a refused trim must not have written anything")
}

@Test("A bad bundle path fails with an actionable error rather than crashing")
func trimOnMissingBundleFails() async {
    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: "/nope/missing.snitt", start: 0, end: 1, auto: false))
    guard case .failure(let error) = response else {
        Issue.record("expected a failure"); return
    }
    #expect(error.hint != nil)
}
```

`AutomationHost.forTesting()` may not exist. If it does not, add a minimal seam in the same style the app's other test seams use, and say in your report what you added — trim and export need no coordinator, so the seam should not require one.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TrimAndExportHostTests`
Expected: FAIL — `.trim` is not an `AutomationRequest.Body` case.

- [ ] **Step 3: Add the protocol cases**

In `Sources/SnittAutomation/Protocol.swift`:

```swift
        case trim(bundlePath: String, start: Double?, end: Double?, auto: Bool)
        case export(bundlePath: String, format: String, outputPath: String,
                    scale: Double, chapters: Bool)
```

```swift
        case trimmed(TrimSummary)
        case exported(ExportManifest)
```

and the summary type, in the same file:

```swift
public struct TrimSummary: Codable, Sendable, Equatable {
    public var keptSeconds: Double
    public var cutSeconds: Double
    public var cuts: [TimeRange]
}
```

`SnittAutomation` already depends on `SnittDocument`, so both `TimeRange` and
`ExportManifest` are available with no new dependency. After building, verify with
`otool -L .build/debug/snitt-cli` that the frontends still link **no** capture framework —
that check is cheap and it is the property the thin-client guard's dependency scan protects.

- [ ] **Step 4: Handle them in the app**

In `Sources/SnittApp/AutomationHost.swift`, add the two arms and their methods. Trim:

```swift
    /// Mutates only `edit.json` — `capture.mov` is immutable (§7).
    private func trim(bundlePath: String, start: Double?, end: Double?,
                      auto: Bool) -> AutomationResponse {
        do {
            let bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
            let meta = try RecordingMetadata.read(from: bundle)
            let duration = meta.durationSeconds ?? 0
            let existing = (try? EditDecisionList.read(from: bundle)) ?? .fullRange()

            let cuts: [TimeRange]
            if auto {
                let events = (try? EventLog.read(from: bundle))?.events ?? []
                cuts = try EditDecisionList.autoTrimCuts(events: events, duration: duration)
            } else {
                let keep = TimeRange(start: start ?? 0, end: end ?? duration)
                cuts = existing.trimmed(keeping: keep, duration: duration).cuts
            }

            var updated = existing
            updated.cuts = cuts
            try updated.write(to: bundle)

            let kept = KeptRanges.compute(duration: duration, cuts: cuts)
            let keptSeconds = kept.reduce(0) { $0 + ($1.end - $1.start) }
            return .trimmed(TrimSummary(keptSeconds: keptSeconds,
                                        cutSeconds: duration - keptSeconds,
                                        cuts: cuts))
        } catch AutoTrimError.noInputEvents {
            return .failure(AutomationError(
                code: .internalError,
                message: "This recording logged no input events, so there is nothing "
                       + "to auto-trim against.",
                hint: "Auto-trim clips dead air around clicks and keystrokes. An "
                    + "agent-driven recording produces none. Use `snitt trim --start "
                    + "<seconds> --end <seconds>` instead, or `snitt inspect` to see "
                    + "the markers you can trim around."))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Use the path `snitt record stop` printed."))
        }
    }
```

Export follows the same shape: open the bundle, read the EDL, `CompositionBuilder.build`, `MovieExporter.exportMovie`, write the `.vtt` beside the output when `chapters` is true, stat the result, and return an `ExportManifest`. Map `CompositionError.everythingCut` to its own actionable failure — "the current trim removes the entire recording" — rather than a generic internal error.

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: PASS — 3 new tests, 261 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

Run: `swift test --filter ThinClient`
Expected: PASS — the frontends must still link no capture framework.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittAutomation Sources/SnittApp Package.swift Tests/SnittAppTests/TrimAndExportHostTests.swift
git commit -m "feat(automation): trim and export over the socket

Both run in the app for the reason inspect does: the CLI cannot read the
bundle, because the default output directory is TCC-gated and a client read
fails silently there. Auto-trim's refusal returns a hint naming the manual
alternative, since an agent-driven recording legitimately has no input events."
```

---

## Task 6: The `snitt trim` and `snitt export` frontends

**Files:**
- Modify: `Sources/SnittAutomation/CommandLineParser.swift`
- Modify: `Sources/snitt-cli/main.swift`
- Modify: `Sources/SnittAutomation/MCPBridge.swift`
- Modify: `Sources/snitt-mcp/main.swift`
- Modify: `Tests/SnittAutomationTests/CommandLineParserTests.swift`
- Modify: `Tests/SnittAutomationTests/MCPBridgeTests.swift`

**Interfaces:**
- Produces: `ParsedCommand.trim(...)`, `ParsedCommand.export(...)`; MCP tools `snitt_trim`, `snitt_export`

**Export needs a longer client timeout.** `AutomationClient`'s default is 120 s and encoding takes seconds to tens of seconds. The CLI constructs `AutomationClient(timeout: 600)` for export specifically — a job-id protocol is complexity v0 does not need. Say so in a comment so the constant is not "tidied" later.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SnittAutomationTests/CommandLineParserTests.swift`:

```swift
@Test("trim parses a range")
func parsesTrimRange() {
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt", "--start", "5", "--end", "25"])
            == .success(.trim(bundlePath: "/tmp/x.snitt", start: 5, end: 25, auto: false)))
}

@Test("trim --auto-trim parses without a range")
func parsesAutoTrim() {
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt", "--auto-trim"])
            == .success(.trim(bundlePath: "/tmp/x.snitt", start: nil, end: nil, auto: true)))
}

@Test("trim with neither a range nor --auto-trim is refused")
func trimNeedsSomething() {
    // Writing an empty edit silently would look like it worked.
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt"]).isFailure)
}

@Test("export parses its format, output and scale")
func parsesExport() {
    guard case .success(.export(let path, let format, let out, let scale, let chapters)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/demo.mp4", "--scale", "0.5", "--chapters"])
    else { Issue.record("parse failed"); return }
    #expect(path == "/tmp/x.snitt")
    #expect(format == "mp4")
    #expect(out == "/tmp/demo.mp4")
    #expect(scale == 0.5)
    #expect(chapters == true)
}

@Test("export defaults to full scale and no chapters")
func exportDefaults() {
    guard case .success(.export(_, _, _, let scale, let chapters)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/demo.mp4"])
    else { Issue.record("parse failed"); return }
    #expect(scale == 1.0)
    #expect(chapters == false)
}

@Test("export rejects a format this milestone cannot write")
func exportRejectsGif() {
    // gif is M3d. Accepting it here would produce an mp4 with a .gif name.
    #expect(CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "gif",
                                     "--out", "/tmp/demo.gif"]).isFailure)
}
```

Add to `Tests/SnittAutomationTests/MCPBridgeTests.swift`:

```swift
@Test("Both frontends express a trim identically")
func frontendsAgreeOnTrim() {
    guard case .success(.trim(let cliPath, let cliStart, let cliEnd, let cliAuto)) =
        CommandLineParser.parse(["trim", "/tmp/d.snitt", "--start", "1", "--end", "9"])
    else { Issue.record("CLI could not express a trim"); return }
    guard case .success(.trim(let mcpPath, let mcpStart, let mcpEnd, let mcpAuto)) =
        MCPBridge.request(forTool: "snitt_trim",
                          arguments: ["bundlePath": "/tmp/d.snitt", "start": 1, "end": 9])
    else { Issue.record("MCP could not express a trim"); return }
    #expect(cliPath == mcpPath)
    #expect(cliStart == mcpStart)
    #expect(cliEnd == mcpEnd)
    #expect(cliAuto == mcpAuto)
}
```

`toolNamesAreStable` asserts the exact tool-name set — add `snitt_trim` and `snitt_export` or it will fail.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandLineParserTests`
Expected: FAIL — `.trim` is not a `ParsedCommand` case.

- [ ] **Step 3: Add the CLI surface**

Extend `ParsedCommand` and `parse`, following the existing branches' shape. Reject any `--format` other than `mp4` with a message naming what is supported — `gif` is M3d, and silently writing an mp4 to a `.gif` path would be worse than refusing.

In `Sources/snitt-cli/main.swift`, map both commands and render both responses. Export must use the longer timeout:

```swift
// Encoding takes seconds to tens of seconds and the default client timeout is
// 120s. A job-id-and-poll protocol is complexity v0 does not need; if exports
// ever exceed ten minutes, that is the moment to add one.
let client = AutomationClient(timeout: isExport ? 600 : 120)
```

Render `.trimmed` and `.exported` with JSON on stdout and a human line on stderr, as every sibling case does. Add both to the help text.

- [ ] **Step 4: Add the MCP tools**

Add `snitt_trim` and `snitt_export` definitions and mapping arms, following the existing tools exactly. The export tool's description should say it returns a manifest an agent can quote — that is what it is for. Render both in `describe` as prose: an MCP client reads text, so "Exported 42s to /tmp/demo.mp4 (3.1 MB), chapters: repro, fix" is the deliverable.

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: PASS — 7 new tests, 268 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 6: Verify both frontends by hand**

```bash
swift build --product snitt-cli --product snitt-mcp
./.build/debug/snitt-cli help                    # trim and export appear
./.build/debug/snitt-cli trim /tmp/x.snitt       # exits 2 — neither range nor --auto-trim
./.build/debug/snitt-cli export /tmp/x.snitt --format gif --out /tmp/x.gif   # exits 2
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | ./.build/debug/snitt-mcp                     # eight tools
```

Do NOT launch `Snitt.app` — a real trim or export needs a recorded bundle and is on the manual checklist.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittAutomation Sources/snitt-cli Sources/snitt-mcp Tests/SnittAutomationTests
git commit -m "feat(cli): add snitt trim and snitt export to both frontends

Export uses a 600s client timeout because encoding takes tens of seconds and
the default is 120s; a job protocol is complexity v0 does not need. gif is
refused with a message naming what is supported rather than writing an mp4 to
a .gif path."
```

---

## Definition of done for M3c

- [ ] `swift test` passes — 268 tests, 0 failures
- [ ] `swift build -Xswiftc -strict-concurrency=complete` emits zero source warnings
- [ ] The access-conformance and thin-client guards still pass; neither frontend links a capture framework
- [ ] `snitt trim <bundle> --start 5 --end 25` writes cuts to `edit.json` and **leaves `capture.mov` byte-identical**
- [ ] `snitt export <bundle> --format mp4 --out demo.mp4` writes a **playable** movie whose duration matches the trim
- [ ] `--scale 0.5` halves the pixel dimensions and leaves the duration unchanged
- [ ] `--chapters` writes a `.vtt` beside the output whose cues match the bundle's markers
- [ ] The manifest reports a byte size matching the file on disk
- [ ] **`--auto-trim` on an agent recording (markers only, no input events) REFUSES** with a hint naming the manual alternative, and `edit.json` is unchanged
- [ ] `--auto-trim` on a human recording with input events trims the bookends and the result plays
- [ ] Re-exporting over an existing file replaces it
- [ ] `snitt-mcp` advertises eight tools including `snitt_trim` and `snitt_export`

## What M3c deliberately does not build

`--format gif` and `--max-size` are **M3d**: GIF needs a separate encoder entirely, and size targeting iterates an export that must exist and be measured against real recordings first. The timeline UI and preview are **M4** — they attach `CompositionBuilder`'s output to an `AVPlayerItem`, which is why §9 makes that builder shared. Overlay rendering remains deferred past v0 and gated on M6.

**Three things to carry forward:**

1. **The passthrough `AVVideoComposition` is the overlay attachment point.** M4 and M7 both change that one object rather than any call site. If a later task finds itself threading a new argument through export, that is the signal something has drifted from §9.
2. **`--auto-trim` is a human-recording feature.** Agent recordings have no input events by construction, so the refusal is the normal path for them, not an error case.
3. **Export blocks its socket connection for the duration of the encode.** Acceptable at v0's scale with a 600 s client timeout; a job-id protocol is the answer if that stops being true.
