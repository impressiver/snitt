# Snitt M0–M1: Spikes and Capture-to-Disk — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the two gating spikes, then build a capture pipeline that records screen, microphone, and system audio into a well-formed `.snitt` bundle.

**Architecture:** A single `SCStream` delivers all three inputs against one clock (macOS 15 native mic capture) into one `AVAssetWriter` with three inputs. Capture is separated from writing by a `SampleBufferSink` protocol seam, so the pipeline is testable with synthetic sample buffers and no real screen. The `.snitt` bundle is a package directory whose `capture.mov` is written once and never mutated.

**Tech Stack:** Swift 6, Swift Package Manager, ScreenCaptureKit, AVFoundation, CoreMedia, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md`

**Scope:** Milestones M0 and M1 only (spec §13). The automation surface, CLI, MCP server, consent model, hotkey, and health checks are M2 and get their own plan.

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include these.

- **Minimum OS is macOS 15 (Sequoia).** `Package.swift` declares `.macOS(.v15)`. (§4.6)
- **One `SCStream` delivers video, system audio, and microphone.** There is no separate `AVCaptureDevice` mic path and no hand-synchronization. (§9)
- **`capture.mov` is immutable.** Editing mutates only `edit.json`. Nothing in this plan writes to `capture.mov` after finalization. (§7)
- **Never burn overlays into `capture.mov`.** Explicit anti-goal; it destroys the immutable-capture invariant and returns GPU work to the capture path. (§3)
- **Writing is incremental.** A crash mid-recording must leave a playable file, never nothing. (§9)
- **No `ShareDestination` protocol. No `BuildCapabilities` flag set.** These were deliberately cut; do not reintroduce them. (§4.1, §4.3)
- **Capture sits behind a protocol seam** so tests inject synthetic sample buffers rather than requiring a real screen. (§15)
- **Permissions are requested progressively**, at first use of the feature that needs them — never upfront. (§4.10)
- **`Package.resolved` is committed.** Snitt ships as an app; dependency versions are pinned.
- Spike output is a **written recommendation**. Spike code is throwaway and must be labeled as such.

---

## File Structure

**Created by this plan:**

| File | Responsibility |
|---|---|
| `Package.swift` | SPM manifest; `.macOS(.v15)`; declares `SnittDocument`, `SnittCapture`, test targets |
| `Scripts/make-app.sh` | Assembles a signed `Snitt.app` so capture runs under a correct TCC identity |
| `Sources/SnittDocument/SnittBundle.swift` | Create/open a `.snitt` package; own its file layout |
| `Sources/SnittDocument/RecordingMetadata.swift` | `meta.json` model — provenance, health, git context |
| `Sources/SnittDocument/EventLog.swift` | `events.json` model — input events and markers |
| `Sources/SnittDocument/EditDecisionList.swift` | `edit.json` model — cuts and per-track state |
| `Sources/SnittCapture/TrackKind.swift` | The three track identities; maps from `SCStreamOutputType` |
| `Sources/SnittCapture/SampleBufferSink.swift` | The protocol seam between capture and writing |
| `Sources/SnittCapture/AssetWriterSink.swift` | `AVAssetWriter` with three inputs; incremental, crash-safe finalize |
| `Sources/SnittCapture/CaptureTarget.swift` | Display/window/application enumeration |
| `Sources/SnittCapture/CaptureSession.swift` | `SCStream` lifecycle; routes sample buffers to the sink |
| `Tests/SnittDocumentTests/*.swift` | Bundle and model tests |
| `Tests/SnittCaptureTests/*.swift` | Routing, sink, and synthetic-buffer pipeline tests |
| `docs/superpowers/spikes/S1-keystroke-monitoring.md` | S1 findings and recommendation |
| `docs/superpowers/spikes/S3-ipc-triggered-capture.md` | S3 findings and recommendation |

**Why this decomposition:** `SnittDocument` has no dependency on `SnittCapture` — the bundle format is meaningful without a recorder, and later milestones (`snitt inspect`, headless trim) consume it without touching capture code. Inside `SnittCapture`, the sink seam is the single most important boundary: it is what makes the pipeline testable and what keeps `AVAssetWriter` details out of `SCStream` lifecycle code.

---

## Task 1: Package scaffold and app wrapper

**Files:**
- Create: `Package.swift`
- Create: `Sources/SnittDocument/SnittBundle.swift` (placeholder to make the target compile)
- Create: `Tests/SnittDocumentTests/PackageSmokeTests.swift`
- Create: `Scripts/make-app.sh`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: a buildable SPM package with targets `SnittDocument` and `SnittCapture`; `Scripts/make-app.sh` producing `build/Snitt.app`

**Why the app wrapper exists, and why it is in the first task:** §4.9 establishes that macOS TCC attributes screen-recording permission to the *responsible process*. A bare SPM executable run from a terminal attributes the grant to the terminal, not to Snitt — so capture built in later tasks cannot be manually verified without a real `.app` bundle with a stable bundle identifier. Building it now avoids discovering this at Task 10.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittDocumentTests/PackageSmokeTests.swift`:

```swift
import Testing
@testable import SnittDocument

@Test("SnittDocument target builds and exposes its version")
func documentTargetIsLinkable() {
    #expect(SnittDocument.version == "0.1.0")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter documentTargetIsLinkable`
Expected: FAIL — `no such module 'SnittDocument'` (no `Package.swift` yet).

- [ ] **Step 3: Write minimal implementation**

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snitt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SnittDocument", targets: ["SnittDocument"]),
        .library(name: "SnittCapture", targets: ["SnittCapture"]),
    ],
    targets: [
        .target(name: "SnittDocument"),
        .target(name: "SnittCapture", dependencies: ["SnittDocument"]),
        .testTarget(name: "SnittDocumentTests", dependencies: ["SnittDocument"]),
        .testTarget(name: "SnittCaptureTests", dependencies: ["SnittCapture"]),
    ]
)
```

Create `Sources/SnittDocument/SnittBundle.swift`:

```swift
import Foundation

public enum SnittDocument {
    public static let version = "0.1.0"
}
```

Create `Tests/SnittCaptureTests/Placeholder.swift` so the target compiles:

```swift
import Testing
@testable import SnittCapture

@Test("SnittCapture target is linkable")
func captureTargetIsLinkable() {
    #expect(true)
}
```

Create `Sources/SnittCapture/TrackKind.swift` as a stub so the target has a source file:

```swift
import Foundation

// Populated in Task 6.
enum CaptureTargetPlaceholder {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS — both smoke tests green.

- [ ] **Step 5: Write the app-wrapper script**

Create `Scripts/make-app.sh`:

```bash
#!/bin/bash
# Assembles build/Snitt.app so capture runs under a stable TCC identity.
# Without this, screen-recording permission is attributed to the terminal
# that launched the binary, not to Snitt (see spec 4.9).
set -euo pipefail

APP="build/Snitt.app"
BUNDLE_ID="com.impressiver.snitt"

swift build -c debug --product snitt-probe 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Snitt</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Snitt</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Snitt records your microphone when you enable it for a recording.</string>
</dict>
</plist>
PLIST

if [ -f ".build/debug/snitt-probe" ]; then
  cp ".build/debug/snitt-probe" "$APP/Contents/MacOS/Snitt"
fi

codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "NOTE: ad-hoc signing changes identity on each rebuild, so macOS may"
echo "re-prompt for Screen Recording. Developer ID signing lands at M5."
```

Make it executable: `chmod +x Scripts/make-app.sh`

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests Scripts
git commit -m "feat: SPM scaffold targeting macOS 15 with app wrapper script

The app wrapper exists because TCC attributes screen-recording permission
to the responsible process; a bare SPM binary attributes it to the calling
terminal. See spec 4.9."
```

---

## Task 2: Spike S1 — keystroke monitoring API

**Files:**
- Create: `Spikes/S1KeystrokeProbe/main.swift` (throwaway)
- Create: `docs/superpowers/spikes/S1-keystroke-monitoring.md`
- Modify: `Package.swift` (add throwaway executable target)

**Interfaces:**
- Consumes: nothing
- Produces: a written recommendation consumed by M3's permission onboarding and §4.3's App Store conditionals. **No production code.**

**This is a spike.** The output is the findings document. The probe code is throwaway and must be labeled so; it is not a foundation for M3.

**The question (spec §14):** Can global keystroke capture use `NSEvent.addGlobalMonitorForEvents`, or does it require `CGEventTap` with an Input Monitoring grant?

- [ ] **Step 1: Write the probe**

Create `Spikes/S1KeystrokeProbe/main.swift`:

```swift
// THROWAWAY SPIKE CODE — spec section 14, S1. Do not build on this.
// Question: does global keystroke capture need Input Monitoring?
import AppKit

print("S1 probe. Type in ANOTHER app for 15 seconds.")
print("Input Monitoring currently granted: \(CGPreflightListenEventAccess())")

var nsEventKeyCount = 0
var nsEventMouseCount = 0
var tapKeyCount = 0

NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { _ in
    nsEventKeyCount += 1
}
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
    nsEventMouseCount += 1
}

let mask = (1 << CGEventType.keyDown.rawValue)
if let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(mask),
    callback: { _, _, event, _ in
        tapKeyCount += 1
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) {
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("CGEventTap created successfully.")
} else {
    print("CGEventTap creation FAILED (likely needs Input Monitoring).")
}

Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
    print("--- RESULTS ---")
    print("NSEvent global keyDown events:  \(nsEventKeyCount)")
    print("NSEvent global mouseDown events: \(nsEventMouseCount)")
    print("CGEventTap keyDown events:       \(tapKeyCount)")
    print("Input Monitoring granted:        \(CGPreflightListenEventAccess())")
    exit(0)
}

RunLoop.main.run()
```

Add to `Package.swift` targets:

```swift
.executableTarget(name: "S1KeystrokeProbe", path: "Spikes/S1KeystrokeProbe"),
```

- [ ] **Step 2: Run the probe WITHOUT Input Monitoring granted**

Run: `swift run S1KeystrokeProbe`, then type in another app for 15 seconds.

Record the four result numbers. The critical question is whether `NSEvent` keyDown counts are non-zero while Input Monitoring is denied.

- [ ] **Step 3: Grant Input Monitoring, then run again**

Grant Input Monitoring to your terminal in System Settings → Privacy & Security → Input Monitoring. Re-run and record the same four numbers.

- [ ] **Step 4: Write the findings document**

Create `docs/superpowers/spikes/S1-keystroke-monitoring.md` with this structure, filling in the observed numbers:

```markdown
# S1 — Keystroke monitoring API

**Question (spec §14):** Can global keystroke capture use
`NSEvent.addGlobalMonitorForEvents`, or does it require `CGEventTap` with an
Input Monitoring grant?

**Date:** <date>  ·  **macOS version:** <version>  ·  **Status:** Resolved

## Observations

| Condition | NSEvent keyDown | NSEvent mouseDown | CGEventTap keyDown |
|---|---|---|---|
| Input Monitoring DENIED | | | |
| Input Monitoring GRANTED | | | |

## Recommendation

<One of: "NSEvent suffices for keystrokes" / "Input Monitoring is required
for keystrokes; mouse events work without it" / other.>

## Consequences

- **Permission onboarding (§4.10):** <what M3 must request, and when>
- **App Store variant (§4.3):** <is the overlay feature viable under MAS?>
- **Conditional call sites (§4.3):** <how many sites need the conditional>
- **`--auto-trim` (§8, D23):** <does event coverage support it>
```

- [ ] **Step 5: Commit**

```bash
git add Spikes/S1KeystrokeProbe docs/superpowers/spikes/S1-keystroke-monitoring.md Package.swift
git commit -m "spike(S1): resolve keystroke monitoring permission requirements

Throwaway probe plus findings. Determines M3 permission onboarding and
App Store feasibility of overlay capture. See spec section 14."
```

---

## Task 3: Spike S3 — IPC-triggered capture

**Files:**
- Create: `Spikes/S3IPCCaptureProbe/main.swift` (throwaway)
- Create: `docs/superpowers/spikes/S3-ipc-triggered-capture.md`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `Scripts/make-app.sh` from Task 1
- Produces: a written recommendation that validates or invalidates the thin-client architecture (§4.9) that M2's CLI and MCP server depend on. **No production code.**

**The question (spec §14):** Does ScreenCaptureKit capture correctly when initiated over IPC from a background, non-foreground app? What happens when the screen is locked, when no user is logged in, and when the app was launched by the CLI rather than by the user?

**Why this gates M2:** if background-initiated capture fails or silently produces black frames, the entire CLI/MCP design in §4.8–§4.9 needs rethinking before it is built.

- [ ] **Step 1: Write the probe**

Create `Spikes/S3IPCCaptureProbe/main.swift`:

```swift
// THROWAWAY SPIKE CODE — spec section 14, S3. Do not build on this.
// Question: does SCStream capture correctly when triggered from a
// background (non-foreground) process?
import Foundation
import ScreenCaptureKit
import AVFoundation

@main
struct Probe {
    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "foreground"
        print("S3 probe running in mode: \(mode)")
        print("Process is frontmost: \(NSRunningApplication.current.isActive)")

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                print("RESULT: no displays available"); exit(2)
            }
            print("Displays visible: \(content.displays.count)")
            print("Windows visible:  \(content.windows.count)")

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.capturesAudio = true
            config.captureMicrophone = false

            let collector = FrameCollector()
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(collector, type: .screen,
                                       sampleHandlerQueue: .global())
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(5))
            try await stream.stopCapture()

            print("--- RESULTS ---")
            print("Frames received:    \(collector.frameCount)")
            print("Non-black frames:   \(collector.nonBlackFrameCount)")
        } catch {
            print("RESULT: capture FAILED with: \(error)")
            exit(1)
        }
    }
}

final class FrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private(set) var frameCount = 0
    private(set) var nonBlackFrameCount = 0

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        frameCount += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var sum = 0
            for row in Swift.stride(from: 0, to: height, by: 32) {
                sum += Int(bytes[row * stride])
            }
            if sum > 0 { nonBlackFrameCount += 1 }
        }
    }
}
```

Add to `Package.swift`:

```swift
.executableTarget(name: "S3IPCCaptureProbe", path: "Spikes/S3IPCCaptureProbe"),
```

- [ ] **Step 2: Run in the foreground as a baseline**

Run: `swift run S3IPCCaptureProbe foreground`
Record frames received and non-black frames. This is the control.

- [ ] **Step 3: Run detached, with no foreground activation**

Run: `nohup swift run S3IPCCaptureProbe background > /tmp/s3-bg.log 2>&1 &`
Wait 20 seconds, then `cat /tmp/s3-bg.log`.

The result that matters: does a background process receive **non-black** frames? A process can receive frames that are entirely black when it lacks a real grant — frame count alone does not prove success, which is exactly why the probe counts non-black frames separately.

- [ ] **Step 4: Test the locked-screen case**

Start the background run, then immediately lock the screen (`Ctrl+Cmd+Q`). Wait 20 seconds, unlock, and read the log. Record what happened: frames continued, frames went black, capture errored, or the process was suspended.

- [ ] **Step 5: Write the findings document**

Create `docs/superpowers/spikes/S3-ipc-triggered-capture.md`:

```markdown
# S3 — IPC-triggered capture

**Question (spec §14):** Does ScreenCaptureKit capture correctly when
initiated from a background, non-foreground app? What happens when the screen
is locked or no user is logged in?

**Date:** <date>  ·  **macOS version:** <version>  ·  **Status:** Resolved

## Observations

| Condition | Frames received | Non-black frames | Notes |
|---|---|---|---|
| Foreground (control) | | | |
| Background, detached | | | |
| Screen locked | | | |

## Recommendation

<Does the thin-client architecture in §4.9 hold? If background capture
produces black frames or fails, say so plainly and state what M2 must do
instead.>

## Consequences

- **Thin-client architecture (§4.9):** <validated / needs revision>
- **Agent error handling (§11):** <what a locked screen must return to an agent>
- **Capture health checks (§12.1):** <does this confirm black-frame detection
  is necessary — and does the probe's non-black heuristic work?>
```

- [ ] **Step 6: Commit**

```bash
git add Spikes/S3IPCCaptureProbe docs/superpowers/spikes/S3-ipc-triggered-capture.md Package.swift
git commit -m "spike(S3): validate IPC-triggered background capture

Throwaway probe plus findings. Gates the M2 thin-client CLI/MCP
architecture in spec section 4.9."
```

---

## Task 4: The `.snitt` bundle

**Files:**
- Modify: `Sources/SnittDocument/SnittBundle.swift`
- Create: `Tests/SnittDocumentTests/SnittBundleTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `struct SnittBundle` with `init(creatingAt url: URL) throws`, `init(opening url: URL) throws`
  - Properties `url`, `captureURL`, `eventsURL`, `editURL`, `metaURL`, `posterURL` — all `URL`
  - `static let fileExtension = "snitt"`
  - `enum SnittBundleError: Error { case notADirectory, missingCapture, alreadyExists }`

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittDocumentTests/SnittBundleTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittDocument

private func makeTempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
}

@Test("Creating a bundle makes a directory with the expected layout")
func createsBundleLayout() throws {
    let url = makeTempURL()
    let bundle = try SnittBundle(creatingAt: url)
    defer { try? FileManager.default.removeItem(at: url) }

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
    #expect(isDir.boolValue)

    #expect(bundle.captureURL.lastPathComponent == "capture.mov")
    #expect(bundle.eventsURL.lastPathComponent == "events.json")
    #expect(bundle.editURL.lastPathComponent == "edit.json")
    #expect(bundle.metaURL.lastPathComponent == "meta.json")
}

@Test("Creating a bundle where one already exists throws")
func refusesToOverwrite() throws {
    let url = makeTempURL()
    _ = try SnittBundle(creatingAt: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: SnittBundleError.alreadyExists) {
        _ = try SnittBundle(creatingAt: url)
    }
}

@Test("Opening a path that is not a directory throws")
func rejectsNonDirectory() throws {
    let url = makeTempURL()
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: SnittBundleError.notADirectory) {
        _ = try SnittBundle(opening: url)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SnittBundleTests`
Expected: FAIL — `cannot find 'SnittBundle' in scope`.

- [ ] **Step 3: Write minimal implementation**

Replace `Sources/SnittDocument/SnittBundle.swift`:

```swift
import Foundation

public enum SnittDocument {
    public static let version = "0.1.0"
}

public enum SnittBundleError: Error, Equatable {
    case notADirectory
    case missingCapture
    case alreadyExists
}

/// A `.snitt` recording package.
///
/// The bundle is a directory. `capture.mov` is written once during recording
/// and never mutated afterwards; `edit.json` is the only file editing touches.
/// See spec section 7.
public struct SnittBundle: Sendable {
    public static let fileExtension = "snitt"

    public let url: URL

    public var captureURL: URL { url.appendingPathComponent("capture.mov") }
    public var eventsURL: URL { url.appendingPathComponent("events.json") }
    public var editURL: URL { url.appendingPathComponent("edit.json") }
    public var metaURL: URL { url.appendingPathComponent("meta.json") }
    public var posterURL: URL { url.appendingPathComponent("poster.png") }

    /// Creates a new bundle directory. Throws if anything already exists there.
    public init(creatingAt url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SnittBundleError.alreadyExists
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        self.url = url
    }

    /// Opens an existing bundle directory.
    public init(opening url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw SnittBundleError.notADirectory
        }
        self.url = url
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SnittBundleTests`
Expected: PASS — three tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittDocument/SnittBundle.swift Tests/SnittDocumentTests/SnittBundleTests.swift
git commit -m "feat(document): add .snitt bundle package format

Directory-based package per spec section 7. capture.mov is immutable;
edit.json is the only file editing mutates."
```

---

## Task 5: Bundle models — metadata, event log, EDL

**Files:**
- Create: `Sources/SnittDocument/RecordingMetadata.swift`
- Create: `Sources/SnittDocument/EventLog.swift`
- Create: `Sources/SnittDocument/EditDecisionList.swift`
- Create: `Tests/SnittDocumentTests/ModelRoundTripTests.swift`

**Interfaces:**
- Consumes: `SnittBundle` from Task 4
- Produces:
  - `struct RecordingMetadata: Codable` — fields `schemaVersion: Int`, `createdAt: Date`, `initiator: Initiator`, `durationSeconds: Double?`, `git: GitContext?`, `health: CaptureHealth?`
  - `enum Initiator: String, Codable { case human, agent }`
  - `struct GitContext: Codable` — `branch: String?`, `commit: String?`
  - `struct CaptureHealth: Codable` — `meanFrameVariance: Double?`, `micRMS: Double?`, `systemAudioRMS: Double?`
  - `struct EventLog: Codable` — `schemaVersion: Int`, `events: [LoggedEvent]`
  - `struct LoggedEvent: Codable` — `timeSeconds: Double`, `kind: EventKind`, `label: String?`
  - `enum EventKind: String, Codable { case click, keystroke, marker }`
  - `struct EditDecisionList: Codable` — `schemaVersion: Int`, `cuts: [TimeRange]`, `trackStates: [TrackState]`
  - `struct TimeRange: Codable, Equatable` — `start: Double`, `end: Double`
  - `struct TrackState: Codable` — `track: String`, `muted: Bool`, `gain: Double`
  - On each of the three: `func write(to bundle: SnittBundle) throws` and `static func read(from bundle: SnittBundle) throws -> Self`

**Note on `CaptureHealth` and `GitContext`:** these are populated in M2 (§12.1, §7). They are defined now, as optionals, so the `meta.json` schema does not need a breaking change when M2 lands.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittDocumentTests/ModelRoundTripTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittDocument

private func makeBundle() throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    return try SnittBundle(creatingAt: url)
}

@Test("RecordingMetadata round-trips through the bundle")
func metadataRoundTrips() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let written = RecordingMetadata(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        initiator: .agent,
        durationSeconds: 42.5,
        git: GitContext(branch: "feature/x", commit: "a1b2c3d"),
        health: nil
    )
    try written.write(to: bundle)
    let read = try RecordingMetadata.read(from: bundle)

    #expect(read.initiator == .agent)
    #expect(read.durationSeconds == 42.5)
    #expect(read.git?.branch == "feature/x")
    #expect(read.schemaVersion == 1)
}

@Test("EventLog round-trips and preserves ordering")
func eventLogRoundTrips() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let written = EventLog(events: [
        LoggedEvent(timeSeconds: 0.5, kind: .click, label: nil),
        LoggedEvent(timeSeconds: 1.5, kind: .marker, label: "the fix"),
        LoggedEvent(timeSeconds: 2.5, kind: .keystroke, label: nil),
    ])
    try written.write(to: bundle)
    let read = try EventLog.read(from: bundle)

    #expect(read.events.count == 3)
    #expect(read.events[1].kind == .marker)
    #expect(read.events[1].label == "the fix")
    #expect(read.events.map(\.timeSeconds) == [0.5, 1.5, 2.5])
}

@Test("A new EDL defaults to no cuts and unmuted tracks")
func editListDefaults() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let written = EditDecisionList.fullRange()
    try written.write(to: bundle)
    let read = try EditDecisionList.read(from: bundle)

    #expect(read.cuts.isEmpty)
    #expect(read.trackStates.count == 3)
    #expect(read.trackStates.allSatisfy { !$0.muted })
    #expect(read.trackStates.allSatisfy { $0.gain == 1.0 })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelRoundTripTests`
Expected: FAIL — `cannot find 'RecordingMetadata' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittDocument/RecordingMetadata.swift`:

```swift
import Foundation

public enum Initiator: String, Codable, Sendable {
    case human
    case agent
}

/// Git provenance for a recording made inside a repository (spec section 7).
public struct GitContext: Codable, Sendable {
    public var branch: String?
    public var commit: String?

    public init(branch: String? = nil, commit: String? = nil) {
        self.branch = branch
        self.commit = commit
    }
}

/// Capture health metrics (spec section 12.1). Populated in M2; defined now
/// so the meta.json schema does not change when M2 lands.
public struct CaptureHealth: Codable, Sendable {
    public var meanFrameVariance: Double?
    public var micRMS: Double?
    public var systemAudioRMS: Double?

    public init(meanFrameVariance: Double? = nil,
                micRMS: Double? = nil,
                systemAudioRMS: Double? = nil) {
        self.meanFrameVariance = meanFrameVariance
        self.micRMS = micRMS
        self.systemAudioRMS = systemAudioRMS
    }
}

public struct RecordingMetadata: Codable, Sendable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var initiator: Initiator
    public var durationSeconds: Double?
    public var git: GitContext?
    public var health: CaptureHealth?

    public init(schemaVersion: Int = 1,
                createdAt: Date,
                initiator: Initiator,
                durationSeconds: Double? = nil,
                git: GitContext? = nil,
                health: CaptureHealth? = nil) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.initiator = initiator
        self.durationSeconds = durationSeconds
        self.git = git
        self.health = health
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.metaURL)
    }

    public static func read(from bundle: SnittBundle) throws -> RecordingMetadata {
        try JSONCoding.decoder.decode(
            RecordingMetadata.self, from: Data(contentsOf: bundle.metaURL)
        )
    }
}

/// Shared JSON configuration. ISO-8601 dates and sorted keys keep bundle
/// files diffable and stable across writes.
enum JSONCoding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
```

Create `Sources/SnittDocument/EventLog.swift`:

```swift
import Foundation

public enum EventKind: String, Codable, Sendable {
    case click
    case keystroke
    case marker
}

/// One timestamped entry in the sidecar log. Times are seconds from the start
/// of the recording. Events are data, never drawn into the video (spec 4.5).
public struct LoggedEvent: Codable, Sendable {
    public var timeSeconds: Double
    public var kind: EventKind
    public var label: String?

    public init(timeSeconds: Double, kind: EventKind, label: String? = nil) {
        self.timeSeconds = timeSeconds
        self.kind = kind
        self.label = label
    }
}

public struct EventLog: Codable, Sendable {
    public var schemaVersion: Int
    public var events: [LoggedEvent]

    public init(schemaVersion: Int = 1, events: [LoggedEvent] = []) {
        self.schemaVersion = schemaVersion
        self.events = events
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.eventsURL)
    }

    public static func read(from bundle: SnittBundle) throws -> EventLog {
        try JSONCoding.decoder.decode(
            EventLog.self, from: Data(contentsOf: bundle.eventsURL)
        )
    }
}
```

Create `Sources/SnittDocument/EditDecisionList.swift`:

```swift
import Foundation

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelRoundTripTests`
Expected: PASS — three tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittDocument Tests/SnittDocumentTests/ModelRoundTripTests.swift
git commit -m "feat(document): add metadata, event log, and EDL models

Health and git context are defined now as optionals so the meta.json
schema does not break when M2 populates them."
```

---

## Task 6: Track identity and the sink seam

**Files:**
- Modify: `Sources/SnittCapture/TrackKind.swift` (replace the Task 1 stub)
- Create: `Sources/SnittCapture/SampleBufferSink.swift`
- Create: `Tests/SnittCaptureTests/TrackKindTests.swift`
- Delete: `Tests/SnittCaptureTests/Placeholder.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enum TrackKind: String, CaseIterable, Sendable { case video, systemAudio, microphone }`
  - `init?(_ outputType: SCStreamOutputType)`
  - `protocol SampleBufferSink: AnyObject, Sendable` with:
    - `func begin(at startTime: CMTime) throws`
    - `func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws`
    - `func finish() async throws -> URL`
  - `enum SinkError: Error { case notStarted, alreadyFinished, writerFailed(String) }`

**This is the seam §15 requires.** `CaptureSession` (Task 9) depends only on this protocol, so tests drive the whole pipeline with synthetic buffers and no screen.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/TrackKindTests.swift`:

```swift
import Testing
import ScreenCaptureKit
@testable import SnittCapture

@Test("Every SCStreamOutputType maps to the expected track")
func mapsOutputTypes() {
    #expect(TrackKind(.screen) == .video)
    #expect(TrackKind(.audio) == .systemAudio)
    #expect(TrackKind(.microphone) == .microphone)
}

@Test("All three tracks are enumerable")
func allTracksEnumerable() {
    #expect(TrackKind.allCases.count == 3)
    #expect(Set(TrackKind.allCases.map(\.rawValue))
            == ["video", "systemAudio", "microphone"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TrackKindTests`
Expected: FAIL — `cannot find 'TrackKind' in scope`.

- [ ] **Step 3: Write minimal implementation**

Replace `Sources/SnittCapture/TrackKind.swift`:

```swift
import Foundation
import ScreenCaptureKit

/// The three tracks a Snitt recording carries. Audio is kept in two discrete
/// tracks so either can be muted independently later (spec section 4.2).
public enum TrackKind: String, CaseIterable, Sendable {
    case video
    case systemAudio
    case microphone

    /// Maps a ScreenCaptureKit output type onto a track.
    ///
    /// All three arrive on one `SCStream` against one clock, which is why
    /// macOS 15 is the minimum (spec section 4.6).
    public init?(_ outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:     self = .video
        case .audio:      self = .systemAudio
        case .microphone: self = .microphone
        @unknown default: return nil
        }
    }
}
```

Create `Sources/SnittCapture/SampleBufferSink.swift`:

```swift
import Foundation
import CoreMedia

public enum SinkError: Error, Equatable {
    case notStarted
    case alreadyFinished
    case writerFailed(String)
}

/// The seam between capture and writing.
///
/// `CaptureSession` depends only on this protocol, so tests can drive the
/// full pipeline with synthetic sample buffers and no real screen
/// (spec section 15).
public protocol SampleBufferSink: AnyObject, Sendable {
    /// Starts a writing session at the first buffer's presentation time.
    func begin(at startTime: CMTime) throws

    /// Appends one buffer to one track. Must tolerate being called
    /// concurrently from ScreenCaptureKit's delivery queues.
    func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws

    /// Finalizes and returns the written file's location.
    func finish() async throws -> URL
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TrackKindTests`
Expected: PASS — two tests green.

- [ ] **Step 5: Remove the placeholder and commit**

```bash
rm Tests/SnittCaptureTests/Placeholder.swift
git add -A Sources/SnittCapture Tests/SnittCaptureTests
git commit -m "feat(capture): add TrackKind and the SampleBufferSink seam

The sink protocol is what makes the capture pipeline testable without a
real screen, per spec section 15."
```

---

## Task 7: AVAssetWriter sink

**Files:**
- Create: `Sources/SnittCapture/AssetWriterSink.swift`
- Create: `Tests/SnittCaptureTests/AssetWriterSinkTests.swift`
- Create: `Tests/SnittCaptureTests/SyntheticBuffers.swift`

**Interfaces:**
- Consumes: `TrackKind`, `SampleBufferSink`, `SinkError` from Task 6
- Produces:
  - `final class AssetWriterSink: SampleBufferSink`
  - `init(outputURL: URL, videoSize: CGSize) throws`
  - Test helpers in `SyntheticBuffers.swift`: `makeVideoBuffer(at:size:) -> CMSampleBuffer`, `makeAudioBuffer(at:) -> CMSampleBuffer`

**Crash-safety requirement (§9):** the writer is configured so a crash leaves a playable file. `AVAssetWriter.movieFragmentInterval` is what provides this — without it, an unfinalized `.mov` has no moov atom and is unreadable.

- [ ] **Step 1: Write the synthetic buffer helpers**

Create `Tests/SnittCaptureTests/SyntheticBuffers.swift`:

```swift
import Foundation
import CoreMedia
import CoreVideo

/// Builds a solid-grey video sample buffer. Used to drive the capture
/// pipeline in tests without a real screen.
func makeVideoBuffer(at seconds: Double, size: CGSize) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault,
                        Int(size.width), Int(size.height),
                        kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    let buffer = pixelBuffer!

    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 128,
               CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescriptionOut: &formatDescription
    )

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription!,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer!
}

/// Builds a silent PCM audio sample buffer of one 1024-frame packet.
func makeAudioBuffer(at seconds: Double) -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
    )

    var formatDescription: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )

    let frameCount = 1024
    var blockBuffer: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: frameCount * 4,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: frameCount * 4,
        flags: 0, blockBufferOut: &blockBuffer
    )
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer!,
                               offsetIntoDestination: 0,
                               dataLength: frameCount * 4)

    var sampleBuffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer!,
        formatDescription: formatDescription!,
        sampleCount: frameCount,
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer!
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/SnittCaptureTests/AssetWriterSinkTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import SnittCapture

private func tempMovieURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")
}

@Test("Writes a movie containing one video and two audio tracks")
func writesThreeTracks() async throws {
    let url = tempMovieURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let size = CGSize(width: 320, height: 240)
    let sink = try AssetWriterSink(outputURL: url, videoSize: size)
    try sink.begin(at: .zero)

    for frame in 0..<30 {
        let t = Double(frame) / 30.0
        try sink.append(makeVideoBuffer(at: t, size: size), to: .video)
        try sink.append(makeAudioBuffer(at: t), to: .systemAudio)
        try sink.append(makeAudioBuffer(at: t), to: .microphone)
    }

    let written = try await sink.finish()
    let asset = AVURLAsset(url: written)

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(videoTracks.count == 1)
    #expect(audioTracks.count == 2)

    let duration = try await asset.load(.duration)
    #expect(duration.seconds > 0)
}

@Test("Appending before begin throws notStarted")
func rejectsAppendBeforeBegin() throws {
    let url = tempMovieURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let size = CGSize(width: 320, height: 240)
    let sink = try AssetWriterSink(outputURL: url, videoSize: size)

    #expect(throws: SinkError.notStarted) {
        try sink.append(makeVideoBuffer(at: 0, size: size), to: .video)
    }
}

@Test("An unfinalized file is still playable, because fragments are written")
func unfinalizedFileIsPlayable() async throws {
    let url = tempMovieURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let size = CGSize(width: 320, height: 240)
    let sink = try AssetWriterSink(outputURL: url, videoSize: size)
    try sink.begin(at: .zero)

    // Write two seconds without ever calling finish(), simulating a crash.
    for frame in 0..<120 {
        try sink.append(makeVideoBuffer(at: Double(frame) / 60.0, size: size),
                        to: .video)
    }
    try await Task.sleep(for: .milliseconds(500))

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size_ = attributes[.size] as! Int
    #expect(size_ > 0, "a crash must leave bytes on disk, not an empty file")
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter AssetWriterSinkTests`
Expected: FAIL — `cannot find 'AssetWriterSink' in scope`.

- [ ] **Step 4: Write minimal implementation**

Create `Sources/SnittCapture/AssetWriterSink.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia

/// Writes sample buffers into a QuickTime movie with three tracks.
///
/// Movie fragments are flushed periodically so that a crash mid-recording
/// leaves a playable file rather than an unreadable one (spec section 9).
public final class AssetWriterSink: SampleBufferSink, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let inputs: [TrackKind: AVAssetWriterInput]
    private let lock = NSLock()
    private var started = false
    private var finished = false

    public init(outputURL: URL, videoSize: CGSize) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // Flush a fragment every second. Without this, an unfinalized movie
        // has no moov atom and cannot be played at all.
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
            ]
        )
        videoInput.expectsMediaDataInRealTime = true

        func makeAudioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            input.expectsMediaDataInRealTime = true
            return input
        }

        let systemInput = makeAudioInput()
        let micInput = makeAudioInput()

        for input in [videoInput, systemInput, micInput] {
            guard writer.canAdd(input) else {
                throw SinkError.writerFailed("cannot add input \(input.mediaType)")
            }
            writer.add(input)
        }

        inputs = [
            .video: videoInput,
            .systemAudio: systemInput,
            .microphone: micInput,
        ]
    }

    public func begin(at startTime: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        guard writer.startWriting() else {
            throw SinkError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: startTime)
        started = true
    }

    public func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws {
        lock.lock(); defer { lock.unlock() }
        guard started else { throw SinkError.notStarted }
        guard !finished else { throw SinkError.alreadyFinished }
        guard let input = inputs[track] else { return }

        // Dropping when not ready is correct: back-pressure from the encoder
        // must never block ScreenCaptureKit's delivery queue.
        guard input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    public func finish() async throws -> URL {
        lock.lock()
        guard started, !finished else {
            lock.unlock()
            throw finished ? SinkError.alreadyFinished : SinkError.notStarted
        }
        finished = true
        for input in inputs.values { input.markAsFinished() }
        lock.unlock()

        await writer.finishWriting()

        if writer.status == .failed {
            throw SinkError.writerFailed(
                writer.error?.localizedDescription ?? "unknown writer failure"
            )
        }
        return writer.outputURL
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter AssetWriterSinkTests`
Expected: PASS — three tests green. The three-track test is the important one: it proves mic and system audio land in separate tracks, which §4.2 requires.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittCapture/AssetWriterSink.swift Tests/SnittCaptureTests
git commit -m "feat(capture): add AVAssetWriter sink with three discrete tracks

Movie fragments are flushed every second so a crash leaves a playable
file, per spec section 9. Mic and system audio stay separate so either
can be muted later."
```

---

## Task 8: Capture target enumeration

**Files:**
- Create: `Sources/SnittCapture/CaptureTarget.swift`
- Create: `Tests/SnittCaptureTests/CaptureTargetTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enum CaptureTarget: Sendable { case display(SCDisplay), window(SCWindow) }`
  - `struct CaptureTargetDescriptor: Codable, Sendable` — `id: UInt32`, `kind: String`, `title: String?`, `applicationName: String?`, `width: Int`, `height: Int`
  - `static func available() async throws -> [CaptureTarget]`
  - `func contentFilter() -> SCContentFilter`
  - `var descriptor: CaptureTargetDescriptor { get }`

**Why descriptors are separate from targets:** `SCDisplay` and `SCWindow` are not `Codable` and cannot cross an IPC boundary. M2's `snitt targets list` returns descriptors as JSON. Defining that split now keeps M2 from having to restructure this type.

**Permission note (§4.10):** `SCShareableContent` triggers the Screen Recording prompt. This is correct — enumeration happens when the user first tries to record, not at launch.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/CaptureTargetTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittCapture

@Test("Descriptors encode to stable JSON for the CLI contract")
func descriptorEncodesStably() throws {
    let descriptor = CaptureTargetDescriptor(
        id: 42, kind: "window", title: "Safari",
        applicationName: "Safari", width: 1440, height: 900
    )
    let data = try JSONEncoder().encode(descriptor)
    let decoded = try JSONDecoder().decode(CaptureTargetDescriptor.self, from: data)

    #expect(decoded.id == 42)
    #expect(decoded.kind == "window")
    #expect(decoded.title == "Safari")
    #expect(decoded.width == 1440)
}

@Test("Descriptor kind is constrained to display or window")
func descriptorKindIsConstrained() {
    #expect(CaptureTargetDescriptor.Kind.display.rawValue == "display")
    #expect(CaptureTargetDescriptor.Kind.window.rawValue == "window")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureTargetTests`
Expected: FAIL — `cannot find 'CaptureTargetDescriptor' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/CaptureTarget.swift`:

```swift
import Foundation
import ScreenCaptureKit

/// A serializable description of something Snitt can record.
///
/// `SCDisplay` and `SCWindow` are not Codable and cannot cross an IPC
/// boundary, so the CLI contract (M2) is expressed in these instead.
public struct CaptureTargetDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case display
        case window
    }

    public var id: UInt32
    public var kind: String
    public var title: String?
    public var applicationName: String?
    public var width: Int
    public var height: Int

    public init(id: UInt32, kind: String, title: String?,
                applicationName: String?, width: Int, height: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.width = width
        self.height = height
    }
}

public enum CaptureTarget: Sendable {
    case display(SCDisplay)
    case window(SCWindow)

    public var descriptor: CaptureTargetDescriptor {
        switch self {
        case .display(let display):
            return CaptureTargetDescriptor(
                id: display.displayID,
                kind: CaptureTargetDescriptor.Kind.display.rawValue,
                title: "Display \(display.displayID)",
                applicationName: nil,
                width: display.width,
                height: display.height
            )
        case .window(let window):
            return CaptureTargetDescriptor(
                id: window.windowID,
                kind: CaptureTargetDescriptor.Kind.window.rawValue,
                title: window.title,
                applicationName: window.owningApplication?.applicationName,
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            )
        }
    }

    public func contentFilter() -> SCContentFilter {
        switch self {
        case .display(let display):
            return SCContentFilter(display: display, excludingWindows: [])
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Enumerates what can be recorded.
    ///
    /// This call triggers the Screen Recording permission prompt, which is
    /// why it happens at first record rather than at launch (spec 4.10).
    public static func available() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return content.displays.map { .display($0) }
             + content.windows.map { .window($0) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureTargetTests`
Expected: PASS — two tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittCapture/CaptureTarget.swift Tests/SnittCaptureTests/CaptureTargetTests.swift
git commit -m "feat(capture): add capture target enumeration and descriptors

Descriptors are Codable so the M2 CLI contract can return them as JSON;
SCDisplay and SCWindow cannot cross an IPC boundary."
```

---

## Task 9: Capture session

**Files:**
- Create: `Sources/SnittCapture/CaptureSession.swift`
- Create: `Tests/SnittCaptureTests/CaptureSessionTests.swift`

**Interfaces:**
- Consumes: `TrackKind`, `SampleBufferSink`, `SinkError` (Task 6); `CaptureTarget` (Task 8)
- Produces:
  - `final class CaptureSession: NSObject, SCStreamOutput`
  - `init(target: CaptureTarget, sink: SampleBufferSink, options: CaptureOptions)`
  - `struct CaptureOptions: Sendable` — `captureMicrophone: Bool`, `captureSystemAudio: Bool`, `maxDuration: Duration?`
  - `func start() async throws`
  - `func stop() async throws` — stops the stream only; the caller owns the sink
  - `func handle(_ buffer: CMSampleBuffer, of type: SCStreamOutputType)` — internal, exposed for tests
  - `enum CaptureError: Error { case alreadyRunning, notRunning }`

**The routing logic is tested directly.** `handle(_:of:)` is what receives every sample buffer; testing it against a spy sink exercises the pipeline with no `SCStream` and no screen — the payoff of the Task 6 seam.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/CaptureSessionTests.swift`:

```swift
import Testing
import Foundation
import CoreMedia
import ScreenCaptureKit
@testable import SnittCapture

/// Records what the session routed, so the pipeline can be tested with no screen.
final class SpySink: SampleBufferSink, @unchecked Sendable {
    var begun = false
    var appended: [(TrackKind, Double)] = []
    var finishedURL = URL(fileURLWithPath: "/tmp/spy.mov")
    private let lock = NSLock()

    func begin(at startTime: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        begun = true
    }

    func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws {
        lock.lock(); defer { lock.unlock() }
        appended.append((track, buffer.presentationTimeStamp.seconds))
    }

    func finish() async throws -> URL { finishedURL }
}

@Test("Routes each output type to its matching track")
func routesBuffersToTracks() throws {
    let sink = SpySink()
    let session = CaptureSession.forTesting(sink: sink)
    let size = CGSize(width: 320, height: 240)

    session.handle(makeVideoBuffer(at: 0.0, size: size), of: .screen)
    session.handle(makeAudioBuffer(at: 0.1), of: .audio)
    session.handle(makeAudioBuffer(at: 0.2), of: .microphone)

    #expect(sink.appended.count == 3)
    #expect(sink.appended.map(\.0) == [.video, .systemAudio, .microphone])
}

@Test("Begins the sink on the first buffer, not before")
func beginsLazilyOnFirstBuffer() throws {
    let sink = SpySink()
    let session = CaptureSession.forTesting(sink: sink)

    #expect(sink.begun == false, "no session before any media arrives")

    session.handle(makeVideoBuffer(at: 5.0, size: CGSize(width: 320, height: 240)),
                   of: .screen)
    #expect(sink.begun == true)
}

@Test("Begins only once across many buffers")
func beginsExactlyOnce() throws {
    let sink = SpySink()
    let session = CaptureSession.forTesting(sink: sink)
    let size = CGSize(width: 320, height: 240)

    for frame in 0..<10 {
        session.handle(makeVideoBuffer(at: Double(frame) / 60.0, size: size),
                       of: .screen)
    }
    #expect(sink.appended.count == 10)
    #expect(sink.begun == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureSessionTests`
Expected: FAIL — `cannot find 'CaptureSession' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/CaptureSession.swift`:

```swift
import Foundation
import ScreenCaptureKit
import CoreMedia

public struct CaptureOptions: Sendable {
    public var captureMicrophone: Bool
    public var captureSystemAudio: Bool
    public var maxDuration: Duration?

    public init(captureMicrophone: Bool = false,
                captureSystemAudio: Bool = true,
                maxDuration: Duration? = nil) {
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
        self.maxDuration = maxDuration
    }
}

public enum CaptureError: Error, Equatable {
    case alreadyRunning
    case notRunning
}

/// Owns the `SCStream` lifecycle and routes delivered buffers to a sink.
///
/// All three inputs arrive on this one stream against one clock, which is
/// why macOS 15 is the floor (spec sections 4.6 and 9).
public final class CaptureSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private let target: CaptureTarget?
    private let sink: SampleBufferSink
    private let options: CaptureOptions

    private var stream: SCStream?
    private let lock = NSLock()
    private var didBegin = false

    public init(target: CaptureTarget,
                sink: SampleBufferSink,
                options: CaptureOptions = CaptureOptions()) {
        self.target = target
        self.sink = sink
        self.options = options
        super.init()
    }

    private init(sink: SampleBufferSink) {
        self.target = nil
        self.sink = sink
        self.options = CaptureOptions()
        super.init()
    }

    /// Builds a session with no stream, for routing tests.
    static func forTesting(sink: SampleBufferSink) -> CaptureSession {
        CaptureSession(sink: sink)
    }

    public func start() async throws {
        guard let target else { throw CaptureError.notRunning }
        guard stream == nil else { throw CaptureError.alreadyRunning }

        let descriptor = target.descriptor
        let configuration = SCStreamConfiguration()
        configuration.width = descriptor.width
        configuration.height = descriptor.height
        configuration.capturesAudio = options.captureSystemAudio
        configuration.captureMicrophone = options.captureMicrophone
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let stream = SCStream(filter: target.contentFilter(),
                              configuration: configuration,
                              delegate: nil)

        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: .global(qos: .userInitiated))
        if options.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio,
                                       sampleHandlerQueue: .global(qos: .userInitiated))
        }
        if options.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone,
                                       sampleHandlerQueue: .global(qos: .userInitiated))
        }

        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops the stream. Deliberately does NOT finish the sink: `Recorder`
    /// owns the bundle lifecycle and finishes it, so the sink is never
    /// finalized twice.
    public func stop() async throws {
        guard let stream else { throw CaptureError.notRunning }
        try await stream.stopCapture()
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        handle(sampleBuffer, of: type)
    }

    /// Routes one buffer. Separated from the delegate method so tests can
    /// drive the pipeline without an SCStream (spec section 15).
    func handle(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let track = TrackKind(type) else { return }
        guard CMSampleBufferDataIsReady(buffer) else { return }

        lock.lock()
        let needsBegin = !didBegin
        if needsBegin { didBegin = true }
        lock.unlock()

        do {
            // The session starts at the first buffer's timestamp, so the
            // three tracks share one timeline from the same clock.
            if needsBegin {
                try sink.begin(at: buffer.presentationTimeStamp)
            }
            try sink.append(buffer, to: track)
        } catch {
            // Dropping a buffer must never tear down the stream; a partial
            // recording beats no recording (spec section 11).
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureSessionTests`
Expected: PASS — three tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittCapture/CaptureSession.swift Tests/SnittCaptureTests/CaptureSessionTests.swift
git commit -m "feat(capture): add SCStream session with buffer routing

One stream delivers video, system audio, and mic against one clock.
Routing is tested with a spy sink and no real screen."
```

---

## Task 10: Record into a bundle, end to end

**Files:**
- Create: `Sources/SnittCapture/Recorder.swift`
- Create: `Tests/SnittCaptureTests/RecorderTests.swift`
- Create: `Sources/snitt-probe/main.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: everything from Tasks 4–9
- Produces:
  - `public actor Recorder`
  - `init(target: CaptureTarget, bundleURL: URL, options: CaptureOptions, initiator: Initiator)`
  - `func start() async throws`
  - `func stop() async throws -> SnittBundle`
  - Executable `snitt-probe` for manual verification through `Scripts/make-app.sh`

**This closes M1.** After this task, a recording produces a complete `.snitt` bundle: `capture.mov` with three tracks, plus `meta.json`, `events.json`, and `edit.json` with correct defaults.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/RecorderTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import SnittCapture
@testable import SnittDocument

@Test("A finished recording produces a complete bundle")
func producesCompleteBundle() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let recorder = try Recorder.forTesting(bundleURL: bundleURL,
                                           videoSize: CGSize(width: 320, height: 240))
    try await recorder.startForTesting()

    let size = CGSize(width: 320, height: 240)
    for frame in 0..<30 {
        let t = Double(frame) / 30.0
        await recorder.feedForTesting(makeVideoBuffer(at: t, size: size), .screen)
        await recorder.feedForTesting(makeAudioBuffer(at: t), .audio)
    }

    let bundle = try await recorder.stop()
    let fm = FileManager.default

    #expect(fm.fileExists(atPath: bundle.captureURL.path))
    #expect(fm.fileExists(atPath: bundle.metaURL.path))
    #expect(fm.fileExists(atPath: bundle.eventsURL.path))
    #expect(fm.fileExists(atPath: bundle.editURL.path))

    let meta = try RecordingMetadata.read(from: bundle)
    #expect(meta.schemaVersion == 1)
    #expect(meta.initiator == .human)
    #expect((meta.durationSeconds ?? 0) > 0)

    let edit = try EditDecisionList.read(from: bundle)
    #expect(edit.cuts.isEmpty)
    #expect(edit.trackStates.count == 3)

    let events = try EventLog.read(from: bundle)
    #expect(events.events.isEmpty, "M1 records no events; that is M3")
}

@Test("capture.mov is a real movie with a video track")
func captureIsPlayable() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    for frame in 0..<30 {
        await recorder.feedForTesting(
            makeVideoBuffer(at: Double(frame) / 30.0, size: size), .screen
        )
    }
    let bundle = try await recorder.stop()

    let asset = AVURLAsset(url: bundle.captureURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecorderTests`
Expected: FAIL — `cannot find 'Recorder' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/Recorder.swift`:

```swift
import Foundation
import CoreMedia
import ScreenCaptureKit
import SnittDocument

/// Drives a capture into a complete `.snitt` bundle.
///
/// On stop, writes the sidecar files so the bundle is valid the moment
/// recording ends — no separate "save" step exists (spec section 7).
public actor Recorder {
    private let bundle: SnittBundle
    private let session: CaptureSession
    private let sink: AssetWriterSink
    private let initiator: Initiator

    private var startedAt: Date?

    public init(target: CaptureTarget,
                bundleURL: URL,
                options: CaptureOptions = CaptureOptions(),
                initiator: Initiator = .human) throws {
        let bundle = try SnittBundle(creatingAt: bundleURL)
        let descriptor = target.descriptor
        let sink = try AssetWriterSink(
            outputURL: bundle.captureURL,
            videoSize: CGSize(width: descriptor.width, height: descriptor.height)
        )
        self.bundle = bundle
        self.sink = sink
        self.initiator = initiator
        self.session = CaptureSession(target: target, sink: sink, options: options)
    }

    private init(bundle: SnittBundle,
                 sink: AssetWriterSink,
                 session: CaptureSession,
                 initiator: Initiator) {
        self.bundle = bundle
        self.sink = sink
        self.session = session
        self.initiator = initiator
    }

    public func start() async throws {
        startedAt = Date()
        try await session.start()
    }

    public func stop() async throws -> SnittBundle {
        // No-op when there is no live stream, which is the testing path.
        try? await session.stop()
        _ = try? await sink.finish()
        try writeSidecars()
        return bundle
    }

    private func writeSidecars() throws {
        let duration = startedAt.map { Date().timeIntervalSince($0) }
        let metadata = RecordingMetadata(
            createdAt: startedAt ?? Date(),
            initiator: initiator,
            durationSeconds: duration,
            git: nil,      // populated in M2
            health: nil    // populated in M2
        )
        try metadata.write(to: bundle)
        try EventLog().write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
    }

    // MARK: - Testing seam

    static func forTesting(bundleURL: URL, videoSize: CGSize) throws -> Recorder {
        let bundle = try SnittBundle(creatingAt: bundleURL)
        let sink = try AssetWriterSink(outputURL: bundle.captureURL,
                                       videoSize: videoSize)
        let session = CaptureSession.forTesting(sink: sink)
        return Recorder(bundle: bundle, sink: sink,
                        session: session, initiator: .human)
    }

    func startForTesting() async throws {
        startedAt = Date()
    }

    func feedForTesting(_ buffer: CMSampleBuffer, _ type: SCStreamOutputType) {
        session.handle(buffer, of: type)
    }
}
```

Create `Sources/snitt-probe/main.swift` for manual verification:

```swift
// Manual verification harness for M1. Replaced by the real app at M2.
import Foundation
import SnittCapture
import SnittDocument

let targets = try await CaptureTarget.available()
guard let display = targets.first(where: {
    if case .display = $0 { return true } else { return false }
}) else {
    FileHandle.standardError.write(Data("no display available\n".utf8))
    exit(1)
}

let output = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(
        "Desktop/SnittProbe-\(Int(Date().timeIntervalSince1970)).snitt"
    )

let recorder = try Recorder(
    target: display,
    bundleURL: output,
    options: CaptureOptions(captureMicrophone: true, captureSystemAudio: true)
)

print("Recording 5 seconds to \(output.path)")
try await recorder.start()
try await Task.sleep(for: .seconds(5))
let bundle = try await recorder.stop()

let meta = try RecordingMetadata.read(from: bundle)
print("Done. Duration: \(meta.durationSeconds ?? 0)s")
print("Bundle: \(bundle.url.path)")
```

Add to `Package.swift`:

```swift
.executableTarget(
    name: "snitt-probe",
    dependencies: ["SnittCapture", "SnittDocument"],
    path: "Sources/snitt-probe"
),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecorderTests`
Expected: PASS — two tests green.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS — every test from Tasks 1 and 4–10 green.

- [ ] **Step 6: Verify manually through the app wrapper**

Run:

```bash
./Scripts/make-app.sh
open build/Snitt.app
```

Grant Screen Recording and Microphone when prompted. Confirm on disk:

1. A `.snitt` bundle appeared on the Desktop.
2. `capture.mov` opens in QuickTime and shows the screen.
3. `mdls -name kMDItemAudioTrackCount <bundle>/capture.mov` reports **2**.
4. `meta.json`, `events.json`, and `edit.json` are all present and valid JSON.

Point 3 is the one that matters most: two audio tracks proves mic and system audio stayed discrete, which everything in §4.4's mute/gain editing depends on.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittCapture/Recorder.swift Sources/snitt-probe \
        Tests/SnittCaptureTests/RecorderTests.swift Package.swift
git commit -m "feat(capture): record into a complete .snitt bundle

Closes M1. A finished recording yields capture.mov with three discrete
tracks plus meta.json, events.json, and edit.json at their defaults."
```

---

## Definition of done for M0–M1

- [ ] `swift test` passes with no failures
- [ ] `docs/superpowers/spikes/S1-keystroke-monitoring.md` states a recommendation with observed numbers
- [ ] `docs/superpowers/spikes/S3-ipc-triggered-capture.md` states whether §4.9's thin-client architecture holds
- [ ] A manual recording produces a bundle whose `capture.mov` has 1 video and 2 audio tracks
- [ ] `Package.resolved` is committed **if any external dependency was added** (this plan adds none, so it will not exist yet)
- [ ] No production code depends on anything in `Spikes/`

## What this plan deliberately does not build

Each belongs to a later milestone and its own plan: the IPC server, CLI, and MCP frontends (M2); the consent model and status item (M2); capture health metrics (M2, §12.1); event logging and markers (M3); the EDL editing UI (M4); the custom compositor (M7, gated).

**Two open questions this plan cannot answer**, both resolved by the spikes it starts with: whether keystroke capture needs Input Monitoring (S1), and whether background-initiated capture works at all (S3). If S3 comes back negative, M2's architecture needs redesign before it is planned — which is exactly why the spike runs first.
