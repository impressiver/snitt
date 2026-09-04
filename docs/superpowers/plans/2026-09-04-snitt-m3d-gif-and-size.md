# M3d — `--format gif` and `--max-size` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the two export options §8 promises and M3c deliberately refused — animated GIF output, and a byte-size target the exporter actually tries to hit and honestly reports on.

**Architecture:** GIF export drives off the *same* `BuiltComposition` mp4 export uses, via `AVAssetImageGenerator.videoComposition` — that is how §9's "export matches preview" invariant extends to a second format instead of forking into a second pipeline. Size targeting uses `AVAssetExportSession.fileLengthLimit` as its first move for mp4 and an fps/scale ladder for GIF, and when a target cannot be met it says so in the manifest rather than quietly shipping an oversized file.

**Tech Stack:** Swift 6, AVFoundation (`AVAssetExportSession`, `AVAssetImageGenerator`), ImageIO (`CGImageDestination`), UniformTypeIdentifiers, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §8 (Automation API, the CLI grammar and manifest contract), §9 (data flow, the one-builder guarantee), §11 (error handling), §4.9 (thin client).

## Global Constraints

- Swift 6, strict concurrency, **zero warnings from `Sources/`** under `swift build -Xswiftc -strict-concurrency=complete`. Run this from a clean build; a cached build has hidden warnings on this project before.
- macOS 15 minimum (§4.6).
- `SnittExport` depends on `SnittDocument` only — **never** `SnittCapture`.
- `SnittAutomation` depends on `SnittDocument` only — **never** `SnittExport`. `snitt-cli` and `snitt-mcp` must not link AVFoundation, ScreenCaptureKit, or CoreMedia (§4.9). Verify with `otool -L`, not only the import-scanning test.
- **Baseline: 302 tests passing** at `18a2a1d` from a full unfiltered `swift test`. Always report counts from a full unfiltered run — never from per-file filters. This suite deadlocked for most of M3c behind per-file filters that all passed.
- **Never block a thread from an async context** — no `DispatchSemaphore.wait()`, no `group.wait()`, no `RunLoop.run()` awaiting an async result.
- Every test names a plausible wrong implementation and is verified to fail against it: break the code, run it, watch it fail, restore.

## Spike results — verified, do not re-derive

These were measured on this machine before the plan was written. Treat them as facts.

1. **`AVAssetExportSession.fileLengthLimit` exists and is settable** (`Int64`). mp4 size targeting has a native primitive; blind re-encode iteration is not the first move.
2. **`AVAssetImageGenerator.videoComposition` works.** This is what lets GIF reuse `BuiltComposition`. A GIF encoder that builds its own composition breaks §9.
3. **`CGImageDestination` writes animated GIF** with `kCGImagePropertyGIFUnclampedDelayTime` per frame and `kCGImagePropertyGIFLoopCount: 0` for infinite loop. Measured: 3 frames → 297 bytes.
4. **`AVAssetImageGenerator.images(for:)` AsyncSequence exists at macOS 15** and delivers **per-frame `.failure` results rather than throwing**. An encoder that ignores them writes a GIF with silently missing frames — §11 is explicit that emitting corrupt output is the worst possible outcome.
5. **LANDMINE: `setVideoComposition:` throws an uncatchable ObjC `NSException`** if `renderSize` is not positive (`"video composition must have a positive renderSize"`). Swift cannot catch this. **Guard before assigning; do not try to catch it.**

## The three refusal seams

M3c refused gif in three places, all deliberately. All three must open, and a task that opens fewer leaves the CLI accepting what the app rejects:

- `Sources/SnittAutomation/CommandLineParser.swift:222` — `guard format == "mp4"`
- `Sources/SnittAutomation/MCPBridge.swift:343` — `guard format == "mp4"`
- `Sources/SnittApp/AutomationHost.swift:228` — `guard format == "mp4"`

## File structure

| File | Responsibility |
|---|---|
| `Sources/SnittAutomation/ByteSize.swift` (new) | Parse `10MB` / `1.5MB` / `500KB` / bare bytes into `Int`. Pure, strict, no AVFoundation. |
| `Sources/SnittDocument/ExportManifest.swift` (modify) | Add `maxSizeBytes` and `maxSizeMet`. |
| `Sources/SnittExport/GIFExporter.swift` (new) | Turn a `BuiltComposition` into an animated GIF. |
| `Sources/SnittExport/SizeLadder.swift` (new) | The bounded (fps, scale) attempt ladder for GIF size targeting. Pure, testable without encoding. |
| `Sources/SnittExport/MovieExporter.swift` (modify) | mp4 `fileLengthLimit` + verification; route `format` to the right encoder; assemble the manifest. |
| `Sources/SnittAutomation/Protocol.swift` (modify) | `export` gains `maxSizeBytes: Int?`. |
| `Sources/SnittApp/AutomationHost.swift` (modify) | Accept gif, thread `maxSizeBytes`. |
| `Sources/SnittAutomation/CommandLineParser.swift` (modify) | `--max-size`, accept gif. |
| `Sources/SnittAutomation/MCPBridge.swift` (modify) | `maxSize` argument, accept gif. |
| `Sources/snitt-cli/main.swift` (modify) | Pass the new field through. |

---

### Task 1: Byte-size parsing

**Files:**
- Create: `Sources/SnittAutomation/ByteSize.swift`
- Test: `Tests/SnittAutomationTests/ByteSizeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum ByteSize { public static func parse(_ text: String) -> Int? }` — returns nil for anything malformed. Later tasks turn that nil into a named error; this function never guesses.

**Why strict:** M3c hit silent input coercion three times — `scale: "0.5"` becoming `1.0`, `chapters: "true"` becoming `false`, `start: true` dropping a bound. Every time, the fix was the same: distinguish absent from present-but-invalid. `--max-size 10Mb` (or `10 MB`, or `ten megabytes`) must not become "no limit" and export a 400 MB file reporting success.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import SnittAutomation

@Test("Plain byte counts parse")
func plainBytes() {
    #expect(ByteSize.parse("1024") == 1024)
    #expect(ByteSize.parse("0") == 0)
}

@Test("Unit suffixes parse case-insensitively")
func unitSuffixes() {
    #expect(ByteSize.parse("10MB") == 10_000_000)
    #expect(ByteSize.parse("10mb") == 10_000_000)
    #expect(ByteSize.parse("500KB") == 500_000)
    #expect(ByteSize.parse("2GB") == 2_000_000_000)
}

@Test("Fractional sizes parse")
func fractionalSizes() {
    #expect(ByteSize.parse("1.5MB") == 1_500_000)
    #expect(ByteSize.parse("0.5KB") == 500)
}

@Test("Whitespace between number and unit is accepted")
func whitespaceAccepted() {
    #expect(ByteSize.parse("10 MB") == 10_000_000)
    #expect(ByteSize.parse("  10MB  ") == 10_000_000)
}

// The discriminating tests. A parser that falls back to a default, or that
// uses Double("...") without validating, passes everything above and fails
// every one of these.
@Test("Malformed input is refused, never defaulted")
func malformedRefused() {
    #expect(ByteSize.parse("") == nil)
    #expect(ByteSize.parse("MB") == nil)
    #expect(ByteSize.parse("ten megabytes") == nil)
    #expect(ByteSize.parse("10XB") == nil)
    #expect(ByteSize.parse("10MB extra") == nil)
    #expect(ByteSize.parse("1.2.3MB") == nil)
}

@Test("Negative, infinite and NaN sizes are refused")
func nonFiniteRefused() {
    // Double("nan") and Double("inf") both SUCCEED in Swift — a parser that
    // forwards Double's result without a finiteness check accepts these and
    // produces a garbage Int conversion, which traps at runtime.
    #expect(ByteSize.parse("-10MB") == nil)
    #expect(ByteSize.parse("nan") == nil)
    #expect(ByteSize.parse("infMB") == nil)
    #expect(ByteSize.parse("1e400MB") == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ByteSize`
Expected: FAIL — `cannot find 'ByteSize' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Parses a human-written size like `10MB` into a byte count.
///
/// Returns `nil` for anything it does not fully understand. It never guesses
/// and never falls back to a default: a `--max-size` that silently became
/// "no limit" would export an oversized file and report success, which is
/// the confidently-wrong failure §8 exists to prevent. Callers turn `nil`
/// into an error naming the offending value.
///
/// Units are decimal (MB = 1,000,000), matching how file-size limits are
/// quoted by the services agents actually hit — GitHub's 10 MB attachment
/// limit is decimal, not 10 MiB.
public enum ByteSize {
    private static let units: [(suffix: String, multiplier: Double)] = [
        // Longest first: "kb" must not match before "k" is ruled out, and
        // "b" must be tried last or it swallows the "B" of "MB".
        ("gb", 1_000_000_000),
        ("mb", 1_000_000),
        ("kb", 1_000),
        ("g", 1_000_000_000),
        ("m", 1_000_000),
        ("k", 1_000),
        ("b", 1),
    ]

    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        var number = trimmed
        var multiplier = 1.0
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            number = String(trimmed.dropLast(unit.suffix.count))
            multiplier = unit.multiplier
            break
        }
        number = number.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else { return nil }

        // Reject anything that is not digits and at most one dot BEFORE
        // handing it to Double. Double("nan"), Double("inf") and
        // Double("1e400") all succeed, and the last is infinite.
        guard number.allSatisfy({ $0.isNumber || $0 == "." }),
              number.filter({ $0 == "." }).count <= 1,
              let value = Double(number),
              value.isFinite,
              value >= 0
        else { return nil }

        let bytes = value * multiplier
        // NOT `bytes <= Double(Int.max)`: Double(Int.max) is not exactly
        // representable and rounds UP to 2^63, so that bound admits a value
        // one greater than Int.max and the conversion below then traps on
        // the literal value of Int.max. Ask whether the conversion is exact
        // instead. `rounded(.down)` keeps `parse("1.1b") == 1`.
        guard let result = Int(exactly: bytes.rounded(.down)) else { return nil }
        return result
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ByteSize` — then a full unfiltered `swift test`.
Expected: PASS, total 302 + 6 = 308.

- [ ] **Step 5: Verify the tests discriminate**

Replace the validation guard with `let value = Double(number) ?? 0` and confirm `malformedRefused` and `nonFiniteRefused` fail. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittAutomation/ByteSize.swift Tests/SnittAutomationTests/ByteSizeTests.swift
git commit -m "feat(export): parse --max-size values strictly, refusing malformed input"
```

---

### Task 2: Manifest reports the size target and whether it was met

**Files:**
- Modify: `Sources/SnittDocument/ExportManifest.swift`
- Test: `Tests/SnittDocumentTests/ExportManifestTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ExportManifest` gains `public var maxSizeBytes: Int?` and `public var maxSizeMet: Bool?`, both defaulted to `nil` in `init` so every existing call site keeps compiling.

**Why:** §8 states the manifest "adds byte size, whether `--max-size` was met, and the chapter list". Byte size and chapters shipped in M3c; this is the missing third.

Both are optional and mean three distinct things — `nil` for "no target was requested", `true` for "requested and met", `false` for "requested and missed". Collapsing the last two would let an agent attach an oversized file to a pull request believing it was under the host's limit.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SnittDocument

@Test("A manifest with no size target round-trips with nil fields")
func noTargetRoundTrips() throws {
    let manifest = ExportManifest(outputPath: "/tmp/a.mp4", format: "mp4", byteSize: 100,
                                  durationSeconds: 1, width: 2, height: 2, scale: 1)
    let decoded = try JSONDecoder().decode(
        ExportManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.maxSizeBytes == nil)
    #expect(decoded.maxSizeMet == nil)
}

@Test("A missed size target survives encoding as false, not as absent")
func missedTargetRoundTrips() throws {
    // The discriminating case. An implementation that encodes maxSizeMet
    // only when true — or that uses `Bool` with a false default instead of
    // `Bool?` — makes "missed the target" indistinguishable from "no target
    // requested", and an agent attaches an oversized file believing it fits.
    let manifest = ExportManifest(outputPath: "/tmp/a.mp4", format: "mp4", byteSize: 999,
                                  durationSeconds: 1, width: 2, height: 2, scale: 1,
                                  maxSizeBytes: 500, maxSizeMet: false)
    let decoded = try JSONDecoder().decode(
        ExportManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.maxSizeBytes == 500)
    #expect(decoded.maxSizeMet == false)
    #expect(decoded.byteSize == 999)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ExportManifest`
Expected: FAIL — no `maxSizeBytes:` argument in `init`.

- [ ] **Step 3: Implement**

Add to the property list, after `scale`:

```swift
    /// The byte target the caller asked for, or nil if none was requested.
    public var maxSizeBytes: Int?
    /// Whether that target was met. Three states, deliberately: nil means no
    /// target was requested, true means it was met, false means the exporter
    /// tried every setting in its ladder and the file is still over budget.
    /// `byteSize` says how far over.
    public var maxSizeMet: Bool?
```

Add to `init`, after `scale: Double`, before `chaptersPath`:

```swift
                maxSizeBytes: Int? = nil,
                maxSizeMet: Bool? = nil,
```

and the two assignments in the body.

- [ ] **Step 4: Run to verify it passes**

Run: full unfiltered `swift test`. Expected: 310.

- [ ] **Step 5: Verify the test discriminates**

Change `maxSizeMet` to a non-optional `Bool` defaulting to `false` and confirm `noTargetRoundTrips` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittDocument/ExportManifest.swift Tests/SnittDocumentTests/ExportManifestTests.swift
git commit -m "feat(export): manifest reports the size target and whether it was met"
```

---

### Task 3: mp4 size targeting

**Files:**
- Modify: `Sources/SnittExport/MovieExporter.swift`
- Test: `Tests/SnittExportTests/MovieExporterTests.swift`

**Interfaces:**
- Consumes: `BuiltComposition` (`composition`, `videoComposition`, `duration`, `keptRanges`), `CompositionBuilder.build(bundle:edl:scale:)`, `ExportManifest(… maxSizeBytes:maxSizeMet: …)`.
- Produces:
  - `MovieExporter.exportMovie(_ built: BuiltComposition, to url: URL, maxSizeBytes: Int?) async throws`
  - `MovieExporter.export(bundle:edl:scale:to:chaptersURL:maxSizeBytes:)` — the existing entry point gains a `maxSizeBytes: Int? = nil` parameter and returns a manifest whose `maxSizeBytes`/`maxSizeMet` are populated.

**Why `fileLengthLimit` first:** it is the encoder's own primitive — one encode, the session picks bitrate to fit. §8 says `--max-size` "iterates encoder settings"; the ladder below is that iteration, but a native single-pass attempt comes first because re-encoding a long recording three times to discover what one API call would have done is a bad trade.

**The honesty requirement:** if the ladder is exhausted and the file is still over budget, **keep the file and report `maxSizeMet: false`** with the real `byteSize`. Do not throw, and do not delete it — a slightly-oversized demo the agent knows about is more useful than a failed export, and §8's whole purpose is that the agent is not misinformed. Do not report success.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A generous size target is met and reported as met")
func generousTargetMet() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("gen-\(UUID().uuidString).mp4")
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        maxSizeBytes: 50_000_000)
    #expect(manifest.maxSizeBytes == 50_000_000)
    #expect(manifest.maxSizeMet == true)
    #expect(manifest.byteSize <= 50_000_000)
}

@Test("An impossible size target still writes a file and reports the miss")
func impossibleTargetReportsMiss() async throws {
    // 200 bytes cannot hold an mp4 header, let alone frames. The
    // discriminating case: an implementation that throws on an unmet target,
    // or that reports maxSizeMet true because the export session did not
    // error, fails here. So does one that deletes the file.
    let bundle = try await makeTestBundle(seconds: 2)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("imp-\(UUID().uuidString).mp4")
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        maxSizeBytes: 200)
    #expect(manifest.maxSizeMet == false)
    #expect(manifest.maxSizeBytes == 200)
    #expect(manifest.byteSize > 200)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@Test("No size target leaves both manifest fields nil")
func noTargetLeavesFieldsNil() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("non-\(UUID().uuidString).mp4")
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out)
    #expect(manifest.maxSizeBytes == nil)
    #expect(manifest.maxSizeMet == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MovieExporter`
Expected: FAIL — no `maxSizeBytes:` argument.

- [ ] **Step 3: Implement**

Replace `exportMovie` and extend `export`:

```swift
    /// Scale multipliers tried in order when the encoder's own
    /// `fileLengthLimit` cannot hit the target. Bounded deliberately: each
    /// rung is a full re-encode, and an unbounded search on a long recording
    /// would run for minutes with no way for the caller to see progress.
    static let sizeLadder: [Double] = [1.0, 0.75, 0.5, 0.35]

    public static func exportMovie(_ built: BuiltComposition,
                                   to url: URL,
                                   maxSizeBytes: Int? = nil) async throws {
        try? FileManager.default.removeItem(at: url)

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.noExportSession }

        session.videoComposition = built.videoComposition
        if let maxSizeBytes {
            // The encoder's own primitive: one pass, the session picks a
            // bitrate that fits. Only if this misses do we re-encode.
            session.fileLengthLimit = Int64(maxSizeBytes)
        }

        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            throw ExportError.sessionFailed(String(describing: error))
        }
    }
```

In `export(bundle:edl:scale:to:chaptersURL:maxSizeBytes:)`, replace the single build-and-write with the ladder:

```swift
        var built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
        var effectiveScale = scale
        var byteSize = 0

        if let maxSizeBytes {
            var met = false
            for rung in sizeLadder {
                effectiveScale = scale * rung
                built = try await CompositionBuilder.build(
                    bundle: bundle, edl: edl, scale: effectiveScale)
                try await exportMovie(built, to: outputURL, maxSizeBytes: maxSizeBytes)
                byteSize = try fileByteSize(at: outputURL)
                if byteSize <= maxSizeBytes { met = true; break }
            }
            // If no rung fit, the file on disk is the smallest attempt. Keep
            // it and say so — see the manifest construction below.
            sizeMet = met
        } else {
            try await exportMovie(built, to: outputURL, maxSizeBytes: nil)
            byteSize = try fileByteSize(at: outputURL)
        }
```

with a small helper beside it:

```swift
    private static func fileByteSize(at url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
```

and the manifest gaining `maxSizeBytes: maxSizeBytes, maxSizeMet: maxSizeBytes == nil ? nil : sizeMet`, plus `scale: effectiveScale` — **the manifest must report the scale actually used, not the one requested**, or an agent told "scale 1.0" gets a file at 0.35 and cannot explain the dimensions.

Declare `var sizeMet = false` before the branch.

- [ ] **Step 4: Run to verify it passes**

Run: full unfiltered `swift test`. Expected: 313.

- [ ] **Step 5: Verify the tests discriminate**

Make the unmet case `throw ExportError.sessionFailed("too big")` and confirm `impossibleTargetReportsMiss` fails. Then make `maxSizeMet` always `true` and confirm it fails again. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittExport/MovieExporter.swift Tests/SnittExportTests/MovieExporterTests.swift
git commit -m "feat(export): target a byte budget for mp4 and report honestly when it is missed"
```

---

### Task 4: The GIF encoder

**Files:**
- Create: `Sources/SnittExport/GIFExporter.swift`
- Test: `Tests/SnittExportTests/GIFExporterTests.swift`

**Interfaces:**
- Consumes: `BuiltComposition`.
- Produces:
  - `public enum GIFError: Error, Equatable { case degenerateRenderSize, frameGenerationFailed(String), destinationUnavailable, finalizeFailed }`
  - `public enum GIFExporter { public static func write(_ built: BuiltComposition, to url: URL, framesPerSecond: Double) async throws }`

**Why it reuses `BuiltComposition`:** §9 — "the most common serious bug class in video editors is an export that does not match the preview, and the only durable defense is making the two literally the same code path." A GIF encoder that builds its own composition would re-derive cuts, scale and transform, and would drift from mp4 export and from M4's preview. `AVAssetImageGenerator` accepts a `videoComposition`, so it can read the exact composition mp4 export writes.

**Three traps, all measured:**

1. **`generator.videoComposition = …` throws an uncatchable ObjC `NSException` if `renderSize` is not positive.** Swift's `do/catch` cannot catch it — the process dies. Guard first and throw `GIFError.degenerateRenderSize`.
2. **`images(for:)` reports failures per frame instead of throwing.** Ignoring a `.failure` case silently writes a GIF missing those frames. §11: "Emitting a black or corrupt video is the worst possible outcome." Throw on the first failure.
3. **A GIF has no audio track.** That is inherent to the format, not a bug, but it must be stated in the CLI help and MCP tool description (Task 6) rather than discovered.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import AVFoundation
import ImageIO
import Foundation
@testable import SnittExport
@testable import SnittDocument

@Test("A GIF is written with one frame per requested interval")
func gifHasExpectedFrameCount() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("g-\(UUID().uuidString).gif")

    try await GIFExporter.write(built, to: out, framesPerSecond: 5)

    let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
    // 2 seconds at 5fps = 10 frames. A generator that emits one frame, or
    // that ignores framesPerSecond, fails here.
    #expect(CGImageSourceGetCount(source) == 10)
    #expect(CGImageSourceGetType(source) as String? == "com.compuserve.gif")
}

@Test("The GIF loops forever and carries a per-frame delay")
func gifLoopsAndHasDelay() async throws {
    let bundle = try await makeTestBundle(seconds: 1)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("l-\(UUID().uuidString).gif")

    try await GIFExporter.write(built, to: out, framesPerSecond: 10)

    let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
    let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    // loopCount 0 means infinite. An encoder that omits the properties
    // dictionary writes a GIF that plays once — the discriminating case.
    #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 0)

    let frame = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let frameGIF = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let delay = frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    #expect(delay != nil)
    #expect(abs((delay ?? 0) - 0.1) < 0.001)
}

@Test("Scale shrinks the GIF's pixel dimensions")
func gifHonoursScale() async throws {
    let bundle = try await makeTestBundle(seconds: 1, size: CGSize(width: 320, height: 240))
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 0.5)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("s-\(UUID().uuidString).gif")

    try await GIFExporter.write(built, to: out, framesPerSecond: 5)

    let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    // Ties the GIF's real pixels to the composition's renderSize. An encoder
    // that generates frames without assigning videoComposition produces
    // 320x240 here and passes every other test in this file.
    #expect(props?[kCGImagePropertyPixelWidth] as? Int == 160)
    #expect(props?[kCGImagePropertyPixelHeight] as? Int == 120)
}

@Test("A degenerate render size is refused rather than crashing the process")
func degenerateRenderSizeRefused() async throws {
    let bundle = try await makeTestBundle(seconds: 1)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let broken = BuiltComposition(
        composition: built.composition,
        videoComposition: AVMutableVideoComposition(),   // renderSize .zero
        duration: built.duration,
        keptRanges: built.keptRanges)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("d-\(UUID().uuidString).gif")

    // Assigning a zero-renderSize videoComposition to AVAssetImageGenerator
    // raises an ObjC NSException that Swift CANNOT catch — the test process
    // dies rather than failing. This test passing at all is the evidence
    // that the guard runs before the assignment.
    await #expect(throws: GIFError.degenerateRenderSize) {
        try await GIFExporter.write(broken, to: out, framesPerSecond: 5)
    }
}
```

**Two facts about the existing test helpers, verified — do not assume otherwise:**

- `makeTestBundle` is declared `private` in `MovieExporterTests.swift`, so it is file-scoped and **not visible from `GIFExporterTests.swift`**. Either drop `private` and move it to a shared file in the same test target, or give `GIFExporterTests` its own. Do not duplicate `writeSyntheticMovie` — that helper is already shared and deliberately so.
- `makeTestBundle` currently takes `seconds:` and `audioTrackCount:`. Add `size: CGSize = CGSize(width: 320, height: 240)` and thread it into `writeSyntheticMovie(to:seconds:size:fps:audioTrackCount:)`, which already accepts a `size`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GIFExporter`
Expected: FAIL — `cannot find 'GIFExporter' in scope`.

- [ ] **Step 3: Implement**

```swift
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SnittDocument
import UniformTypeIdentifiers

public enum GIFError: Error, Equatable {
    /// `AVAssetImageGenerator.videoComposition` raises an uncatchable ObjC
    /// exception when `renderSize` is not positive. This is thrown instead,
    /// before the assignment.
    case degenerateRenderSize
    case frameGenerationFailed(String)
    case destinationUnavailable
    case finalizeFailed
}

/// Writes a `BuiltComposition` as an animated GIF.
///
/// Reads the SAME composition mp4 export writes (§9). `AVAssetImageGenerator`
/// accepts a `videoComposition`, so the cuts, scale and transform applied here
/// are the ones `CompositionBuilder` decided — not a second derivation that
/// can drift from what the preview shows.
///
/// A GIF carries no audio. That is the format, not an omission, but callers
/// must say so rather than let a user discover a silent demo.
public enum GIFExporter {
    public static func write(_ built: BuiltComposition,
                             to url: URL,
                             framesPerSecond: Double) async throws {
        let renderSize = built.videoComposition.renderSize
        // MUST precede the assignment below. Not a defensive nicety: the
        // ObjC exception this avoids cannot be caught from Swift, so the
        // alternative to this guard is a dead process.
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw GIFError.degenerateRenderSize
        }
        guard framesPerSecond > 0, built.duration > 0 else {
            throw GIFError.degenerateRenderSize
        }

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = renderSize

        let interval = 1.0 / framesPerSecond
        var times: [CMTime] = []
        var t = 0.0
        while t < built.duration {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += interval
        }
        guard !times.isEmpty else { throw GIFError.degenerateRenderSize }

        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else { throw GIFError.destinationUnavailable }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: interval
            ]
        ] as CFDictionary

        for await result in generator.images(for: times) {
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: _):
                CGImageDestinationAddImage(destination, image, frameProperties)
            case .failure(requestedTime: let time, error: let error):
                // Per-frame failures are DELIVERED, not thrown. Skipping them
                // writes a GIF that is quietly missing frames — §11 is
                // explicit that corrupt output is the worst outcome.
                throw GIFError.frameGenerationFailed(
                    "frame at \(CMTimeGetSeconds(time))s: \(error.localizedDescription)")
            @unknown default:
                throw GIFError.frameGenerationFailed("unknown result case")
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFError.finalizeFailed
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: full unfiltered `swift test`. Expected: 317.

- [ ] **Step 5: Verify the tests discriminate**

Delete the `generator.videoComposition = …` line and confirm `gifHonoursScale` fails with 320×120-or-320×240 dimensions. Change the `.failure` case to `continue` and confirm nothing catches it — note in the report that no shipped test covers that path and say whether you added one. Remove the `renderSize` guard and confirm `degenerateRenderSizeRefused` **crashes the test process rather than failing** — that is the evidence the guard is load-bearing. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittExport/GIFExporter.swift Tests/SnittExportTests/GIFExporterTests.swift
git commit -m "feat(export): write animated GIFs from the same composition mp4 export uses"
```

---

### Task 5: GIF size targeting

**Files:**
- Create: `Sources/SnittExport/SizeLadder.swift`
- Modify: `Sources/SnittExport/MovieExporter.swift`
- Test: `Tests/SnittExportTests/SizeLadderTests.swift`, `Tests/SnittExportTests/MovieExporterTests.swift`

**Interfaces:**
- Consumes: `GIFExporter.write(_:to:framesPerSecond:)`, `CompositionBuilder.build(bundle:edl:scale:)`.
- Produces: `public struct SizeLadder { public struct Rung: Equatable, Sendable { public let framesPerSecond: Double; public let scaleMultiplier: Double }; public static func rungs(baseFPS: Double) -> [Rung] }`, and `MovieExporter.export` routing `format == "gif"` through it.

**Why a separate type:** the ladder is the one piece of size targeting that can be tested without encoding anything. Encoding tests are slow and coarse; the ordering rule — never increase quality as you descend, and always change *something* on each rung — is a property worth pinning cheaply. Keeping it pure also stops the retry loop from growing an accidental unbounded search.

`fileLengthLimit` has no GIF equivalent — ImageIO offers no size budget — so GIF targeting is genuinely the "iterate encoder settings" §8 describes: drop frame rate first (a GIF's size is roughly linear in frame count and viewers tolerate 10fps), then resolution.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import SnittExport

@Test("The ladder descends monotonically and never repeats a rung")
func ladderDescends() {
    let rungs = SizeLadder.rungs(baseFPS: 15)
    #expect(rungs.count >= 4)
    #expect(rungs.first?.framesPerSecond == 15)
    #expect(rungs.first?.scaleMultiplier == 1.0)
    for (a, b) in zip(rungs, rungs.dropFirst()) {
        // Each rung must be no better than the last on both axes, and
        // strictly worse on at least one. A ladder with a repeated rung
        // burns a full re-encode producing a byte-identical file.
        #expect(b.framesPerSecond <= a.framesPerSecond)
        #expect(b.scaleMultiplier <= a.scaleMultiplier)
        #expect(b != a)
    }
}

@Test("The ladder is bounded")
func ladderBounded() {
    // Each rung is a full re-encode. An unbounded ladder on a long recording
    // runs for minutes with no progress visible to the caller.
    #expect(SizeLadder.rungs(baseFPS: 15).count <= 6)
}

@Test("A low base frame rate does not produce rungs above it")
func ladderRespectsBase() {
    // Asking for 5fps and getting a 15fps first rung would make the GIF
    // larger than the caller asked for before targeting even begins.
    #expect(SizeLadder.rungs(baseFPS: 5).allSatisfy { $0.framesPerSecond <= 5 })
}
```

and in `MovieExporterTests`:

```swift
@Test("An impossible GIF size target still writes a file and reports the miss")
func gifImpossibleTargetReportsMiss() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-\(UUID().uuidString).gif")
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        format: "gif", maxSizeBytes: 100)
    #expect(manifest.format == "gif")
    #expect(manifest.maxSizeMet == false)
    #expect(manifest.byteSize > 100)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@Test("A generous GIF size target is met on the first rung at full quality")
func gifGenerousTargetMetAtFullQuality() async throws {
    let bundle = try await makeTestBundle(seconds: 1)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("gg-\(UUID().uuidString).gif")
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        format: "gif", maxSizeBytes: 50_000_000)
    #expect(manifest.maxSizeMet == true)
    // Discriminating: an implementation that always walks the whole ladder,
    // or that starts partway down it, degrades a file that already fit.
    #expect(manifest.scale == 1.0)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SizeLadder`
Expected: FAIL — `cannot find 'SizeLadder' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The bounded sequence of quality settings GIF size targeting walks.
///
/// ImageIO has no `fileLengthLimit` equivalent, so hitting a byte target for
/// a GIF means encoding, measuring, and trying again with less. Frame rate
/// drops first: a GIF's size is roughly linear in frame count, and 10fps
/// reads as fine where half resolution is immediately visible.
///
/// Bounded on purpose. Each rung is a full re-encode.
public struct SizeLadder {
    public struct Rung: Equatable, Sendable {
        public let framesPerSecond: Double
        public let scaleMultiplier: Double
    }

    public static func rungs(baseFPS: Double) -> [Rung] {
        let fpsSteps = [15.0, 10.0, 8.0, 5.0].filter { $0 <= baseFPS }
        let ladderFPS = fpsSteps.isEmpty ? [baseFPS] : fpsSteps
        var rungs: [Rung] = ladderFPS.map { Rung(framesPerSecond: $0, scaleMultiplier: 1.0) }
        // Only once frame rate is exhausted does resolution drop, and both
        // rungs keep the lowest frame rate so each is strictly worse.
        let slowest = ladderFPS.last ?? baseFPS
        rungs.append(Rung(framesPerSecond: slowest, scaleMultiplier: 0.6))
        rungs.append(Rung(framesPerSecond: slowest, scaleMultiplier: 0.4))
        return rungs
    }
}
```

In `MovieExporter`, add `public static let defaultGIFFrameRate = 15.0`, give `export` a `format: String = "mp4"` parameter, and branch: `format == "gif"` walks `SizeLadder.rungs(baseFPS: defaultGIFFrameRate)` rebuilding the composition at `scale * rung.scaleMultiplier` and calling `GIFExporter.write(…, framesPerSecond: rung.framesPerSecond)`, stopping at the first rung under budget; with no target it writes one GIF at the base rate and full scale. The manifest reports `format`, the effective `scale`, real `byteSize`, and `maxSizeMet`.

- [ ] **Step 4: Run to verify it passes**

Run: full unfiltered `swift test`. Expected: 322.

- [ ] **Step 5: Verify the tests discriminate**

Make `rungs` return a repeated rung and confirm `ladderDescends` fails. Make the GIF path always walk to the last rung and confirm `gifGenerousTargetMetAtFullQuality` fails on `scale`. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittExport/SizeLadder.swift Sources/SnittExport/MovieExporter.swift Tests/SnittExportTests/
git commit -m "feat(export): walk a bounded quality ladder to hit a GIF size budget"
```

---

### Task 6: Open the three refusal seams and wire both frontends

**Files:**
- Modify: `Sources/SnittAutomation/Protocol.swift` (the `export` request case)
- Modify: `Sources/SnittApp/AutomationHost.swift:228` (the third refusal seam)
- Modify: `Sources/SnittAutomation/CommandLineParser.swift:222` (first seam, plus `--max-size`)
- Modify: `Sources/SnittAutomation/MCPBridge.swift:343` (second seam, plus `maxSize`)
- Modify: `Sources/snitt-cli/main.swift` (pass the new field through)
- Test: `Tests/SnittAutomationTests/CommandLineParserTests.swift`, `Tests/SnittAutomationTests/MCPBridgeTests.swift`, `Tests/SnittAppTests/TrimAndExportHostTests.swift`

**Interfaces:**
- Consumes: `ByteSize.parse(_:)`, `MovieExporter.export(bundle:edl:scale:to:chaptersURL:format:maxSizeBytes:)`.
- Produces: `AutomationRequest.Body.export` gains `maxSizeBytes: Int?`.

**All three seams must open together.** They were closed together in M3c with matching wording. Opening two of three leaves the CLI cheerfully accepting `--format gif` and the app rejecting it with "Snitt currently exports mp4 only" — the worst of both, because the error arrives after the round trip and names a restriction the client does not believe in.

**Protocol version:** `Protocol.swift` is v2 and has never shipped, so amend in place — do not bump. Follow the rule stated in the file itself, and read it before editing rather than trusting this line.

**MCP argument parsing:** `maxSize` arrives as a JSON **string** (`"10MB"`), unlike `scale`, which is a number. Use the existing string-argument discipline, and reject a *present but unparseable* value by name rather than defaulting to no limit. `MCPBridgeTests` fixtures decode from real JSON text via `JSONSerialization.jsonObject` — keep that. Swift dictionary literals do not reproduce the bugs this suite exists to catch.

- [ ] **Step 1: Write the failing tests**

```swift
// CommandLineParserTests
@Test("export accepts gif")
func exportAcceptsGif() {
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "gif", "--out", "/tmp/o.gif"])
    guard case .success(.export(_, let format, _, _, _, _)) = result else {
        Issue.record("expected success, got \(result)"); return
    }
    #expect(format == "gif")
}

@Test("--max-size is parsed into bytes")
func maxSizeParsed() {
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "mp4", "--out", "/tmp/o.mp4",
         "--max-size", "10MB"])
    guard case .success(.export(_, _, _, _, _, let maxSize)) = result else {
        Issue.record("expected success, got \(result)"); return
    }
    // Asserts the VALUE reached the command, not merely that parsing
    // succeeded. A parser that accepts the flag and drops it passes a
    // success-only assertion.
    #expect(maxSize == 10_000_000)
}

@Test("A malformed --max-size is refused, not ignored")
func malformedMaxSizeRefused() {
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "mp4", "--out", "/tmp/o.mp4",
         "--max-size", "ten megabytes"])
    guard case .failure(let failure) = result else {
        Issue.record("expected failure, got \(result)"); return
    }
    #expect(failure.message.contains("--max-size"))
}

@Test("An unknown format is still refused")
func unknownFormatRefused() {
    // Opening the gif seam must not open it to everything.
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "webm", "--out", "/tmp/o.webm"])
    guard case .failure = result else {
        Issue.record("expected failure for webm"); return
    }
}
```

```swift
// MCPBridgeTests — fixtures decoded from real JSON text, as this file already does
@Test("snitt_export accepts gif and a string maxSize")
func mcpAcceptsGifAndMaxSize() {
    let args = jsonArguments("""
    {"bundlePath":"/tmp/b.snitt","format":"gif","outputPath":"/tmp/o.gif","maxSize":"5MB"}
    """)
    guard case .success(let request) = MCPBridge.request(forTool: "snitt_export", arguments: args),
          case .export(_, let format, _, _, _, let maxSize) = request.body else {
        Issue.record("expected a successful export request"); return
    }
    #expect(format == "gif")
    #expect(maxSize == 5_000_000)
}

@Test("A malformed maxSize fails the call by name rather than exporting unbounded")
func mcpMalformedMaxSizeFails() {
    let args = jsonArguments("""
    {"bundlePath":"/tmp/b.snitt","format":"mp4","outputPath":"/tmp/o.mp4","maxSize":"lots"}
    """)
    guard case .failure(let error) = MCPBridge.request(forTool: "snitt_export", arguments: args) else {
        Issue.record("expected failure"); return
    }
    #expect(error.message.contains("maxSize"))
}

@Test("An absent maxSize means no limit, not a zero limit")
func mcpAbsentMaxSizeIsNoLimit() {
    let args = jsonArguments("""
    {"bundlePath":"/tmp/b.snitt","format":"mp4","outputPath":"/tmp/o.mp4"}
    """)
    guard case .success(let request) = MCPBridge.request(forTool: "snitt_export", arguments: args),
          case .export(_, _, _, _, _, let maxSize) = request.body else {
        Issue.record("expected success"); return
    }
    // A `?? 0` default would make every export target zero bytes and walk
    // the whole ladder before reporting a miss.
    #expect(maxSize == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "CommandLineParser|MCPBridge"`
Expected: FAIL — the `export` case has five associated values, not six.

- [ ] **Step 3: Implement**

1. `Protocol.swift`: `case export(bundlePath: String, format: String, outputPath: String, scale: Double, chapters: Bool, maxSizeBytes: Int?)`.
2. `CommandLineParser.swift`: add `--max-size` parsing via `ByteSize.parse`, failing with `ParseFailure("--max-size needs a size like 10MB, got \"\(raw)\"")`; change the format guard to `guard format == "mp4" || format == "gif"` with the message naming both.
3. `MCPBridge.swift`: same format guard; read `maxSize` as a string, `ByteSize.parse` it, fail by name if present-and-unparseable; add both to the tool's input schema, and state in the `snitt_export` description that **gif has no audio track**.
4. `AutomationHost.swift`: change the guard to accept both, and pass `format` and `maxSizeBytes` into `MovieExporter.export`.
5. `snitt-cli/main.swift`: thread `maxSizeBytes` into the request body. `resolvePath` already handles the paths.
6. Update `snitt export`'s help text: `--format mp4|gif`, `--max-size 10MB`, and a line that gif carries no audio.

- [ ] **Step 4: Run to verify it passes**

Run: full unfiltered `swift test`. Expected: 329.

- [ ] **Step 5: Verify the seams and the thin client**

```bash
swift build -Xswiftc -strict-concurrency=complete   # from a clean build
otool -L .build/debug/snitt-cli | grep -ciE "AVFoundation|ScreenCaptureKit|CoreMedia"   # expect 0
otool -L .build/debug/snitt-mcp | grep -ciE "AVFoundation|ScreenCaptureKit|CoreMedia"   # expect 0
```

Then drive the real MCP binary over stdio with `"format":"gif"` and `"maxSize":"5MB"`, and with `"maxSize":"lots"`, and paste both observed results into the report. M3c shipped two frontend bugs that unit tests could not see and only the running binary revealed; a green suite is not sufficient evidence for this file.

- [ ] **Step 6: Commit**

```bash
git add Sources/ Tests/
git commit -m "feat(export): accept --format gif and --max-size across both frontends"
```

---

## Self-review

**Spec coverage.** §8's export grammar — `--format mp4|gif` (Tasks 4, 5, 6), `--max-size 10MB` (Tasks 1, 3, 5, 6), `--scale` and `--chapters` (already shipped in M3c). §8's manifest contract — byte size (shipped), chapter list (shipped), "whether `--max-size` was met" (Task 2). §9's one-builder guarantee — Task 4 reuses `BuiltComposition` rather than forking a second pipeline, and `gifHonoursScale` is the test that would catch a fork. §11's "corrupt output is the worst possible outcome" — Task 4's per-frame failure check. §4.9 — Task 6 verifies with `otool`, not only the import scan.

Deliberately **not** covered: batch multi-format export (mp4 + gif in one pass) is a §3 non-goal, deferred post-gate because its interaction with per-format `--max-size` needs its own design pass. Nothing here should make it harder later — `MovieExporter.export` taking a `format` string leaves room for a caller that loops.

**Known gaps a reviewer should weigh rather than assume:**

- **`fileLengthLimit`'s behaviour when the limit is impossible is not pinned by the spike.** It may produce a best-effort file, or fail the session. Task 3's `impossibleTargetReportsMiss` asserts the *contract* — a file exists and the miss is reported — so whichever AVFoundation does, the implementer must make it true. If the session throws, the ladder must catch that and keep the smallest successful attempt.
- **GIF encoding cost at realistic sizes is unmeasured.** The tests use 1–2 second synthetic movies. A 60-second 4K recording at 15fps is 900 full-size frames through `AVAssetImageGenerator`, and the ladder can re-encode that four times. If Task 5's tests take more than a few seconds, say so in the report — a slow suite is how the M3c deadlock stayed hidden.
- **Task 5's `gifGenerousTargetMetAtFullQuality` assumes a 1-second synthetic GIF lands under 50 MB.** Near-certain, but if the fixture ever grows, that assertion becomes vacuous rather than failing loudly.

**Type consistency.** `ByteSize.parse` → `Int?` everywhere. `maxSizeBytes: Int?` in the manifest, the protocol case, and both frontends. `GIFExporter.write(_:to:framesPerSecond:)` matches its call in Task 5. `SizeLadder.Rung` fields (`framesPerSecond`, `scaleMultiplier`) match their uses. `MovieExporter.export` reaches its final shape in Task 5 (`format:` added) and Task 6 passes both new arguments — Task 3 adds `maxSizeBytes:` and Task 5 adds `format:`, so Task 3's tests call it without `format:` and rely on its `= "mp4"` default arriving in Task 5. **Task 3 must therefore give `format` no default until Task 5 exists, or add the defaulted parameter itself.** Simplest: Task 3 adds `maxSizeBytes: Int? = nil` only; Task 5 adds `format: String = "mp4"`.
