# Snitt M2a: The Capture App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn M1's headless capture library into an app a person can actually use — press a hotkey, record a window, find the video on the clipboard.

**Architecture:** Target selection forks into two resolvers behind one protocol: `SCContentSharingPicker` for interactive human selection, and cached re-resolution via `SCShareableContent` for the hotkey path. Both produce an already-resolved `SCContentFilter`, so `CaptureSession` stops caring where its target came from. A menu-bar app hosts the hotkey, the recording indicator, and the kill switch.

**Tech Stack:** Swift 6, SPM, ScreenCaptureKit, AppKit (`NSStatusItem`, `NSPasteboard`), Carbon `RegisterEventHotKey`, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md`

**Scope:** M2a only — the human-facing capture app. The automation surface (`SnittAutomation`, IPC, CLI, MCP server, consent enforcement) is M2b and gets its own plan. This plan produces working software without any of it.

## Global Constraints

Copied from the spec. Every task's requirements implicitly include these.

- **Minimum OS is macOS 15.** Do not change `.macOS(.v15)`. (§4.6)
- **`capture.mov` is immutable**; `edit.json` is the only file editing mutates. (§7)
- **Window-scoped capture is the default for EVERY recording**, human or agent. Full-display is a deliberate choice, never what happens by default. (§5.1)
- **The monthly re-consent prompt is a permanent, accepted cost** of the hotkey path. Do not attempt to architect around it. Explain it (§5.5); never claim it is fixed. (§5.2, D33)
- **`SCContentSharingPicker` cannot be replayed.** There is no API to reuse a prior selection non-interactively (V12). Any cached-target path MUST go through `SCShareableContent`. Do not search for a picker replay API; it does not exist. (§5.2)
- **No persistent per-application agent grant store.** It was specified and deleted; do not reintroduce it. (§5.4, D34)
- **Capture stays behind a protocol seam** so tests inject synthetic buffers with no real screen. (§15)
- Swift 6 language mode, strict concurrency. `swift build -Xswiftc -strict-concurrency=complete` must stay at zero warnings.

---

## File Structure

| File | Responsibility |
|---|---|
| `Scripts/signing-identity.sh` | Create/locate a stable self-signed code-signing identity |
| `Scripts/make-app.sh` (modify) | Sign with the stable identity instead of ad-hoc |
| `Sources/SnittCapture/TargetReference.swift` | The *persistable* description of a target (bundle id + hints), and why it isn't a window id |
| `Sources/SnittCapture/ResolvedTarget.swift` | A target already resolved to a live `SCContentFilter`, plus provenance |
| `Sources/SnittCapture/TargetResolver.swift` | The resolver protocol both paths conform to |
| `Sources/SnittCapture/CachedTargetResolver.swift` | Re-resolves a `TargetReference` via `SCShareableContent` |
| `Sources/SnittCapture/PickerTargetResolver.swift` | Drives `SCContentSharingPicker`, returns its filter |
| `Sources/SnittDocument/TargetStore.swift` | Persists the last-approved `TargetReference` |
| `Sources/SnittApp/SnittApp.swift` | Menu-bar app entry point |
| `Sources/SnittApp/StatusItemController.swift` | Status item, recording indicator, kill switch |
| `Sources/SnittApp/HotkeyMonitor.swift` | Carbon `RegisterEventHotKey` — needs no permission |
| `Sources/SnittApp/RecordingCoordinator.swift` | Wires hotkey → resolver → recorder → clipboard |
| `Sources/SnittApp/ConsentExplainer.swift` | First-occurrence sheet for the recurring prompt (§5.5) |
| `Sources/SnittExport/ClipboardDestination.swift` | Writes a finished recording to `NSPasteboard` |
| `Spikes/S4NagObservation/` | Long-running observation harness for spike S4 |

**Why the resolver fork:** M1's `CaptureTarget.available() -> [CaptureTarget]` is synchronous enumerate-then-select. `SCContentSharingPicker` is asynchronous and delegate-driven and hands back a finished `SCContentFilter`. These are not the same shape, so this is a rework of the capture entry point, not a swap of one call for another. Making both paths produce a `ResolvedTarget` is what keeps `CaptureSession` from growing two code paths.

---

## Task 1: Stable code-signing identity

**Files:**
- Create: `Scripts/signing-identity.sh`
- Modify: `Scripts/make-app.sh`
- Create: `docs/superpowers/notes/signing.md`

**Interfaces:**
- Consumes: nothing
- Produces: an exported shell function contract — `Scripts/signing-identity.sh` prints a codesign identity string on stdout and exits 0, or prints instructions to stderr and exits 1.

**Why this is first (§13, D39):** TCC keys permission grants to the app's code identity. Ad-hoc signing recomputes that identity on every build, so every rebuild risks resetting the Screen Recording grant. §5.5 draws a line — the monthly prompt is expected, anything beyond it is a defect — and that line is unenforceable while the app's identity changes underneath it. Nothing else in M2a is trustworthy until this is stable.

- [ ] **Step 1: Write the identity script**

Create `Scripts/signing-identity.sh`:

```bash
#!/bin/bash
# Prints a stable codesign identity for local development.
#
# Ad-hoc signing ("-") changes the app's code identity on every build, which
# makes macOS TCC forget Screen Recording permission each time. A self-signed
# certificate keeps the identity constant so permission grants persist.
set -euo pipefail

IDENTITY_NAME="Snitt Development"

if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
  echo "$IDENTITY_NAME"
  exit 0
fi

cat >&2 <<INSTRUCTIONS
No code-signing identity named "$IDENTITY_NAME" was found.

Create one ONCE (it is local-only and never leaves this machine):

  1. Open Keychain Access
  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate...
  3. Name:              $IDENTITY_NAME
     Identity Type:     Self Signed Root
     Certificate Type:  Code Signing
     (tick "Let me override defaults" only if you want a longer validity)
  4. Create, then Done.

Then re-run this script. See docs/superpowers/notes/signing.md for why.
INSTRUCTIONS
exit 1
```

Make it executable: `chmod +x Scripts/signing-identity.sh`

- [ ] **Step 2: Run it and observe the failure path**

Run: `./Scripts/signing-identity.sh`
Expected: exits 1 with the instructions (assuming no such identity yet). This is
the correct behaviour — confirm the message is legible before relying on it.

- [ ] **Step 3: Create the certificate as the script instructs, then verify**

Follow the printed instructions in Keychain Access, then run:

Run: `./Scripts/signing-identity.sh`
Expected: prints `Snitt Development` and exits 0.

- [ ] **Step 4: Use the identity in make-app.sh**

In `Scripts/make-app.sh`, replace the ad-hoc signing line
`codesign --force --deep --sign - "$APP"` and its trailing NOTE echo with:

```bash
if IDENTITY="$(./Scripts/signing-identity.sh)"; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with stable identity: $IDENTITY"
  echo "TCC grants will persist across rebuilds."
else
  codesign --force --sign - "$APP"
  echo "WARNING: signed ad-hoc. The app's identity changes on every build, so" >&2
  echo "macOS will forget Screen Recording permission each time you rebuild." >&2
  echo "Run ./Scripts/signing-identity.sh for one-time setup instructions." >&2
fi
```

Note `--deep` is dropped: Apple discourages it, and the bundle has no nested code.

- [ ] **Step 5: Verify the identity is stable across two builds**

Run:

```bash
./Scripts/make-app.sh && codesign -dv build/Snitt.app 2>&1 | grep -E "Identifier|Authority"
touch Sources/SnittCapture/CaptureSession.swift
./Scripts/make-app.sh && codesign -dv build/Snitt.app 2>&1 | grep -E "Identifier|Authority"
```

Expected: the `Authority` line is identical across both builds. With ad-hoc
signing it would have shown no Authority at all. This is the whole point of the
task — if the two differ, stop and fix it before continuing.

- [ ] **Step 6: Write the note explaining why**

Create `docs/superpowers/notes/signing.md`:

```markdown
# Local code-signing identity

Snitt signs local development builds with a self-signed certificate named
"Snitt Development" rather than ad-hoc (`codesign -s -`).

## Why

macOS TCC keys permission grants — including Screen Recording — to an app's
code identity. Ad-hoc signing derives that identity from the code directory
hash, which changes on every build. The practical effect is that macOS forgets
Screen Recording permission each time you rebuild, and you re-approve constantly.

That matters beyond annoyance. Spec §5.5 sets the rule that a monthly
re-consent prompt is expected OS behaviour, while anything more frequent is a
defect worth fixing. With an unstable identity nobody can tell those apart, so
the rule is unenforceable and real bugs hide behind expected noise.

## What this is not

This is a local development convenience, not distribution. Developer ID
signing and notarization remain part of M5 packaging; this certificate never
leaves the machine that created it and confers no trust anywhere else.
```

- [ ] **Step 7: Commit**

```bash
git add Scripts/signing-identity.sh Scripts/make-app.sh docs/superpowers/notes/signing.md
git commit -m "build: sign local builds with a stable identity

TCC keys grants to code identity, and ad-hoc signing recomputes it every
build, so macOS forgets Screen Recording permission each rebuild. Spec 5.5's
rule that monthly prompts are expected and anything more is a defect cannot
be enforced while the identity is unstable."
```

---

## Task 2: Spike S4 observation harness

**Files:**
- Create: `Spikes/S4NagObservation/S4Probe.swift`
- Create: `docs/superpowers/spikes/S4-nag-scoping.md`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: nothing
- Produces: a written findings document, filled in over weeks. **No production code.**

**Why this is early despite being a spike (§14, D41):** S4 asks whether the
monthly re-consent prompt is scoped per-app (any `SCShareableContent` use taints
everything) or per-recording-path. The answer decides whether §4.11's
cached-target design and the picker's residual value are real. **It cannot be
answered from documentation and cannot be rushed** — the prompt fires monthly, so
the observation window is weeks. Starting the clock now means the answer arrives
while M2b is being built rather than after.

**This is a spike.** The output is the findings document. Do not fabricate
observations. Do not build production code on this file.

- [ ] **Step 1: Write the observation harness**

Create `Spikes/S4NagObservation/S4Probe.swift`:

```swift
// THROWAWAY SPIKE CODE — spec section 14, S4. Do not build on this.
//
// Question: is the macOS monthly screen-recording re-consent prompt scoped to
// the APP (any SCShareableContent use taints it) or to the recording PATH?
//
// This cannot be answered from documentation, and it cannot be answered
// quickly: the prompt is monthly. This harness records which selection path
// each recording used and when, so that when a prompt eventually fires the
// history can be correlated against it.
import Foundation
import ScreenCaptureKit

@main
struct S4Probe {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/snitt-s4-observation.log")

    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "enumerate"
        switch mode {
        case "enumerate":
            await recordEnumeration()
        case "note-prompt":
            append("PROMPT-OBSERVED user reported the monthly re-consent prompt")
            print("Recorded. Include this timestamp in the findings table.")
        case "report":
            printReport()
        default:
            print("usage: S4Probe [enumerate|note-prompt|report]")
        }
    }

    /// Exercises the bypass path once and logs it.
    static func recordEnumeration() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            append("ENUMERATE ok displays=\(content.displays.count) windows=\(content.windows.count)")
            print("Logged one SCShareableContent call.")
        } catch {
            append("ENUMERATE failed \(error)")
            print("Failed: \(error)")
        }
    }

    static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: logURL)
        }
    }

    static func printReport() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            print("No observations yet at \(logURL.path)")
            return
        }
        print(text)
    }
}
```

Add to `Package.swift` targets:

```swift
.executableTarget(name: "S4NagObservation", path: "Spikes/S4NagObservation"),
```

- [ ] **Step 2: Verify it builds and logs**

Run:

```bash
swift build --product S4NagObservation
swift run S4NagObservation enumerate
swift run S4NagObservation report
```

Expected: build succeeds; `report` prints one `ENUMERATE ok` line with a timestamp.

- [ ] **Step 3: Write the findings document**

Create `docs/superpowers/spikes/S4-nag-scoping.md`:

```markdown
# S4 — Is the monthly re-consent prompt scoped per-app or per-path?

**Question (spec §14):** macOS 15 shows a recurring monthly screen-recording
re-consent prompt to apps that bypass `SCContentSharingPicker`. Is that charged
to the *app* (any `SCShareableContent` call taints it) or to the *recording
path* (only bypass-path recordings count)?

**Why it matters:** §4.11's cached-target instant capture and §5.2's residual
justification for adopting the picker both assume per-path scoping. If scoping
is per-app, then picker-driven sessions are prompted too once any hotkey
recording ships, and picker adoption buys almost nothing.

**Date opened:** 2026-09-02 · **Status:** Open — long-running observation

## Method

`swift run S4NagObservation enumerate` logs one `SCShareableContent` call with a
timestamp. Use the app normally. When the monthly prompt appears, immediately run
`swift run S4NagObservation note-prompt` to timestamp it.

## Observations

| Date | Event | Notes |
|---|---|---|
| | | |

## Interpretation guide — fill in when the data arrives

- **Prompt fires even in months containing only picker-driven recordings** →
  scoping is per-app. §4.11's design still stands on its own merits (a monthly
  prompt still beats a per-recording picker) but §5.2 must stop claiming the
  picker helps, and D38's justification for picker adoption weakens to
  "API-correctness only".
- **Prompt fires only in months containing a bypass-path recording** → scoping
  is per-path. The cached-target hybrid is genuinely a hybrid, and picker
  adoption keeps its value for manual recording.

## Status

**AWAITING OBSERVATION — do not fill in the conclusion without data.** This
spike takes weeks by construction; an empty table is the correct state until the
prompt has actually been seen at least twice.
```

- [ ] **Step 4: Commit**

```bash
git add Spikes/S4NagObservation docs/superpowers/spikes/S4-nag-scoping.md Package.swift
git commit -m "spike(S4): open long-running observation of prompt scoping

Starts the clock on the one question documentation cannot answer: whether
the monthly re-consent prompt is charged per-app or per-recording-path.
The prompt is monthly, so this takes weeks; opening it now means the answer
lands while M2b is being built rather than after."
```

---

## Task 3: TargetReference and its store

**Files:**
- Create: `Sources/SnittCapture/TargetReference.swift`
- Create: `Sources/SnittDocument/TargetStore.swift`
- Create: `Tests/SnittCaptureTests/TargetReferenceTests.swift`
- Create: `Tests/SnittDocumentTests/TargetStoreTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct TargetReference: Codable, Sendable, Equatable` with
    `kind: Kind`, `bundleIdentifier: String?`, `titleHint: String?`, `displayID: UInt32?`
  - `public enum TargetReference.Kind: String, Codable, Sendable { case window, display }`
  - `public static func window(bundleIdentifier: String, titleHint: String?) -> TargetReference`
  - `public static func display(id: UInt32) -> TargetReference`
  - `public final class TargetStore: Sendable` with
    `init(fileURL: URL)`, `func load() -> TargetReference?`, `func save(_ reference: TargetReference) throws`, `func clear() throws`
  - `public static func defaultURL() -> URL` on `TargetStore`

**Why a reference and not a window id (V10, §5.4):** `SCWindow.windowID` is a
per-session integer. A relaunched app produces new windows with new IDs, so a
stored window id silently stops matching and the "cached target" would appear to
work once and then quietly fail. The durable identity is the owning
application's bundle identifier, with the window title kept only as a
disambiguation hint when an app has several windows.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SnittCaptureTests/TargetReferenceTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittCapture

@Test("A window reference stores bundle id and title hint, never a window id")
func windowReferenceShape() throws {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Release Notes")
    #expect(ref.kind == .window)
    #expect(ref.bundleIdentifier == "com.apple.Safari")
    #expect(ref.titleHint == "Release Notes")
    #expect(ref.displayID == nil)
}

@Test("A display reference stores the display id and no bundle id")
func displayReferenceShape() throws {
    let ref = TargetReference.display(id: 7)
    #expect(ref.kind == .display)
    #expect(ref.displayID == 7)
    #expect(ref.bundleIdentifier == nil)
}

@Test("References round-trip through JSON")
func referenceRoundTrips() throws {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: nil)
    let data = try JSONEncoder().encode(ref)
    let back = try JSONDecoder().decode(TargetReference.self, from: data)
    #expect(back == ref)
}
```

Create `Tests/SnittDocumentTests/TargetStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittDocument

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
}

@Test("An empty store loads nil rather than throwing")
func emptyStoreLoadsNil() {
    let store = TargetStore(fileURL: tempStoreURL())
    #expect(store.load() == nil)
}

@Test("A saved reference survives a reload")
func savedReferenceReloads() throws {
    let url = tempStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = TargetStore(fileURL: url)
    try store.save(StoredTargetReference(kind: "window",
                                         bundleIdentifier: "com.apple.Safari",
                                         titleHint: "Docs",
                                         displayID: nil))

    let reloaded = TargetStore(fileURL: url).load()
    #expect(reloaded?.bundleIdentifier == "com.apple.Safari")
    #expect(reloaded?.kind == "window")
}

@Test("A corrupt store loads nil instead of throwing or crashing")
func corruptStoreLoadsNil() throws {
    let url = tempStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("this is not json".utf8).write(to: url)

    let store = TargetStore(fileURL: url)
    #expect(store.load() == nil, "a corrupt cache must degrade to 'no cached target', never crash")
}

@Test("Clearing removes the stored reference")
func clearRemovesReference() throws {
    let url = tempStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = TargetStore(fileURL: url)
    try store.save(StoredTargetReference(kind: "display",
                                         bundleIdentifier: nil,
                                         titleHint: nil,
                                         displayID: 3))
    try store.clear()
    #expect(store.load() == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TargetReferenceTests`
Expected: FAIL — `cannot find 'TargetReference' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/TargetReference.swift`:

```swift
import Foundation

/// A durable description of something Snitt can record.
///
/// Deliberately does NOT store a window id. `SCWindow.windowID` is a
/// per-session integer, so a relaunched application produces new windows with
/// new ids and a stored id silently stops matching (spec §5.4, V10). The
/// durable identity is the owning application's bundle identifier; the title is
/// kept only to disambiguate when one app has several windows.
public struct TargetReference: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case window
        case display
    }

    public var kind: Kind
    public var bundleIdentifier: String?
    public var titleHint: String?
    public var displayID: UInt32?

    public static func window(bundleIdentifier: String,
                              titleHint: String?) -> TargetReference {
        TargetReference(kind: .window,
                        bundleIdentifier: bundleIdentifier,
                        titleHint: titleHint,
                        displayID: nil)
    }

    public static func display(id: UInt32) -> TargetReference {
        TargetReference(kind: .display,
                        bundleIdentifier: nil,
                        titleHint: nil,
                        displayID: id)
    }
}
```

Create `Sources/SnittDocument/TargetStore.swift`:

```swift
import Foundation

/// The on-disk shape of a cached target. Kept as a plain string-keyed record in
/// `SnittDocument` so the storage layer does not depend on ScreenCaptureKit.
public struct StoredTargetReference: Codable, Sendable, Equatable {
    public var kind: String
    public var bundleIdentifier: String?
    public var titleHint: String?
    public var displayID: UInt32?

    public init(kind: String,
                bundleIdentifier: String?,
                titleHint: String?,
                displayID: UInt32?) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.titleHint = titleHint
        self.displayID = displayID
    }
}

/// Persists the last target a human approved, so the hotkey can reuse it.
///
/// Reads never throw: a missing or corrupt cache degrades to "no cached
/// target", which sends the user to the picker. A convenience cache must never
/// be able to break recording.
public final class TargetStore: @unchecked Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Snitt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        return base.appendingPathComponent("last-target.json")
    }

    public func load() -> StoredTargetReference? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredTargetReference.self, from: data)
    }

    public func save(_ reference: StoredTargetReference) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reference).write(to: fileURL)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — 23 pre-existing plus 7 new = 30 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittCapture/TargetReference.swift Sources/SnittDocument/TargetStore.swift \
        Tests/SnittCaptureTests/TargetReferenceTests.swift Tests/SnittDocumentTests/TargetStoreTests.swift
git commit -m "feat(capture): add TargetReference and its store

References key on bundle identifier, never window id: SCWindow.windowID is
per-session, so a stored id silently stops matching after a relaunch. A
corrupt or missing cache degrades to 'no cached target' rather than
throwing — a convenience cache must never break recording."
```

---

## Task 4: ResolvedTarget and the resolver seam

**Files:**
- Create: `Sources/SnittCapture/ResolvedTarget.swift`
- Create: `Sources/SnittCapture/TargetResolver.swift`
- Create: `Tests/SnittCaptureTests/TargetResolverTests.swift`

**Interfaces:**
- Consumes: `TargetReference`, `CaptureTargetDescriptor` (existing, from M1)
- Produces:
  - `public struct ResolvedTarget: @unchecked Sendable` with
    `let filter: SCContentFilter`, `let descriptor: CaptureTargetDescriptor`,
    `let reference: TargetReference?`, `let provenance: Provenance`
  - `public enum ResolvedTarget.Provenance: String, Sendable { case picker, cache }`
  - `public protocol TargetResolver: Sendable { func resolve() async throws -> ResolvedTarget }`
  - `public enum TargetResolutionError: Error, Equatable { case cancelled, noCachedTarget, targetGone(String), unavailable }`

**Why this exists:** the picker delivers a finished `SCContentFilter`
asynchronously via delegate callback; the cached path builds one synchronously
from enumeration. `ResolvedTarget` is the point where those two shapes converge,
so `CaptureSession` never learns which one it got. `provenance` is retained
because spike S4 needs to know which path produced each recording.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/TargetResolverTests.swift`:

```swift
import Testing
import Foundation
import ScreenCaptureKit
@testable import SnittCapture

/// A resolver that returns a canned result, so callers can be tested with no
/// picker UI and no real screen.
final class StubResolver: TargetResolver, @unchecked Sendable {
    let result: Result<ResolvedTarget, TargetResolutionError>
    private(set) var callCount = 0

    init(_ result: Result<ResolvedTarget, TargetResolutionError>) {
        self.result = result
    }

    func resolve() async throws -> ResolvedTarget {
        callCount += 1
        return try result.get()
    }
}

@Test("A resolver that fails surfaces its error unchanged")
func resolverPropagatesError() async {
    let resolver = StubResolver(.failure(.noCachedTarget))
    await #expect(throws: TargetResolutionError.noCachedTarget) {
        _ = try await resolver.resolve()
    }
    #expect(resolver.callCount == 1)
}

@Test("Provenance distinguishes picker from cache for spike S4")
func provenanceIsDistinguishable() {
    #expect(ResolvedTarget.Provenance.picker.rawValue == "picker")
    #expect(ResolvedTarget.Provenance.cache.rawValue == "cache")
    #expect(ResolvedTarget.Provenance.picker != ResolvedTarget.Provenance.cache)
}

@Test("Resolution errors are distinguishable by case")
func errorsAreDistinguishable() {
    #expect(TargetResolutionError.cancelled != TargetResolutionError.noCachedTarget)
    #expect(TargetResolutionError.targetGone("Safari")
            != TargetResolutionError.targetGone("Xcode"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TargetResolverTests`
Expected: FAIL — `cannot find 'TargetResolver' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/ResolvedTarget.swift`:

```swift
import Foundation
import ScreenCaptureKit

/// A target that has already been resolved to a live `SCContentFilter`.
///
/// Both selection paths converge here — the interactive picker and cached
/// re-resolution — so `CaptureSession` never has to know which produced it.
///
/// `@unchecked Sendable` for the same reason `CaptureTarget` is: `SCContentFilter`
/// is not marked `Sendable` by ScreenCaptureKit, but Snitt only reads it after
/// construction and never mutates it.
public struct ResolvedTarget: @unchecked Sendable {
    /// Which path produced this target. Retained because spike S4 (§14) needs
    /// to correlate the monthly re-consent prompt against the paths actually used.
    public enum Provenance: String, Sendable, Equatable {
        case picker
        case cache
    }

    public let filter: SCContentFilter
    public let descriptor: CaptureTargetDescriptor
    /// The durable form, when one exists — displays and windows resolved from
    /// the picker can be re-found later; some picker selections cannot.
    public let reference: TargetReference?
    public let provenance: Provenance

    public init(filter: SCContentFilter,
                descriptor: CaptureTargetDescriptor,
                reference: TargetReference?,
                provenance: Provenance) {
        self.filter = filter
        self.descriptor = descriptor
        self.reference = reference
        self.provenance = provenance
    }
}
```

Create `Sources/SnittCapture/TargetResolver.swift`:

```swift
import Foundation

public enum TargetResolutionError: Error, Equatable {
    /// The human dismissed the picker without choosing.
    case cancelled
    /// No previously-approved target exists to reuse.
    case noCachedTarget
    /// A cached target's application is no longer running or has no windows.
    case targetGone(String)
    /// The picker is unavailable on this system.
    case unavailable
}

/// Produces a target ready to record.
///
/// Two conformers exist: `PickerTargetResolver` (interactive, human-driven) and
/// `CachedTargetResolver` (re-resolves a stored reference). Callers depend on
/// this protocol so they can be tested without picker UI or a real screen.
public protocol TargetResolver: Sendable {
    func resolve() async throws -> ResolvedTarget
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TargetResolverTests`
Expected: PASS — 3 new tests green, 33 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittCapture/ResolvedTarget.swift Sources/SnittCapture/TargetResolver.swift \
        Tests/SnittCaptureTests/TargetResolverTests.swift
git commit -m "feat(capture): add ResolvedTarget and the resolver seam

The picker delivers a finished SCContentFilter asynchronously; the cached
path builds one from enumeration. ResolvedTarget is where those shapes
converge so CaptureSession never learns which it got. Provenance is
retained because spike S4 needs to correlate prompts against paths used."
```

---

## Task 5: CachedTargetResolver

**Files:**
- Create: `Sources/SnittCapture/CachedTargetResolver.swift`
- Create: `Tests/SnittCaptureTests/CachedTargetMatchingTests.swift`

**Interfaces:**
- Consumes: `TargetReference`, `ResolvedTarget`, `TargetResolver`, `TargetResolutionError`, `CaptureTargetDescriptor`
- Produces:
  - `public struct CachedTargetResolver: TargetResolver`
  - `public init(reference: TargetReference)`
  - `static func bestMatch(for reference: TargetReference, among candidates: [WindowCandidate]) -> WindowCandidate?`
  - `public struct WindowCandidate: Sendable, Equatable` with `windowID: UInt32`, `bundleIdentifier: String?`, `title: String?`, `width: Int`, `height: Int`

**This is the bypass path, deliberately.** It calls `SCShareableContent` and
therefore incurs the monthly re-consent prompt (§5.2, V9). That is the accepted
cost of instant capture (§4.11, D36) — do not attempt to avoid it here, and do
not look for a picker replay API; V12 established that none exists.

**The matching logic is the testable core.** Resolution needs a real screen, but
choosing *which* window best matches a stored reference is pure logic and gets
full coverage.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/CachedTargetMatchingTests.swift`:

```swift
import Testing
@testable import SnittCapture

private func candidate(_ id: UInt32, _ bundle: String?, _ title: String?) -> WindowCandidate {
    WindowCandidate(windowID: id, bundleIdentifier: bundle,
                    title: title, width: 800, height: 600)
}

@Test("Matches the only window of the referenced application")
func matchesSoleWindow() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: nil)
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(1, "com.apple.Xcode", "Project"),
        candidate(2, "com.apple.Safari", "Anything"),
    ])
    #expect(found?.windowID == 2)
}

@Test("Prefers the window whose title matches the hint")
func prefersTitleHint() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Release Notes")
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(1, "com.apple.Safari", "Inbox"),
        candidate(2, "com.apple.Safari", "Release Notes"),
        candidate(3, "com.apple.Safari", "Docs"),
    ])
    #expect(found?.windowID == 2)
}

@Test("Falls back to the first window of the app when no title matches")
func fallsBackWhenHintMisses() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Long Gone")
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(7, "com.apple.Safari", "Inbox"),
        candidate(8, "com.apple.Safari", "Docs"),
    ])
    #expect(found?.windowID == 7,
            "a stale title must not prevent recording the right app")
}

@Test("Returns nil when the application has no windows")
func noMatchWhenAppAbsent() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: nil)
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(1, "com.apple.Xcode", "Project"),
    ])
    #expect(found == nil)
}

@Test("Ignores window ids entirely when matching")
func ignoresWindowIDs() {
    // The same app, different window ids than any previous session — matching
    // must not depend on them, because they change every relaunch.
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Docs")
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(99_001, "com.apple.Safari", "Docs"),
    ])
    #expect(found?.windowID == 99_001)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CachedTargetMatchingTests`
Expected: FAIL — `cannot find 'CachedTargetResolver' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/CachedTargetResolver.swift`:

```swift
import Foundation
import ScreenCaptureKit

/// A window observed on screen right now, reduced to the fields matching needs.
///
/// Separated from `SCWindow` so the matching logic is pure and testable without
/// a real screen.
public struct WindowCandidate: Sendable, Equatable {
    public var windowID: UInt32
    public var bundleIdentifier: String?
    public var title: String?
    public var width: Int
    public var height: Int

    public init(windowID: UInt32, bundleIdentifier: String?,
                title: String?, width: Int, height: Int) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.width = width
        self.height = height
    }
}

/// Re-resolves a stored `TargetReference` against what is on screen now.
///
/// - Important: This is the bypass path. It calls `SCShareableContent`, which
///   incurs the macOS monthly re-consent prompt (§5.2). That is the accepted
///   cost of instant capture (§4.11) — there is no picker API that can replay a
///   prior selection (V12), so this is not an oversight to be optimised away.
public struct CachedTargetResolver: TargetResolver {
    private let reference: TargetReference

    public init(reference: TargetReference) {
        self.reference = reference
    }

    /// Chooses the window that best matches a stored reference.
    ///
    /// Window ids are deliberately ignored: they change every relaunch (V10).
    /// Matching is by bundle identifier, with the title used only to
    /// disambiguate — a stale title falls back to the app's first window rather
    /// than failing, because recording the right app beats recording nothing.
    static func bestMatch(for reference: TargetReference,
                          among candidates: [WindowCandidate]) -> WindowCandidate? {
        guard let bundleID = reference.bundleIdentifier else { return nil }
        let sameApp = candidates.filter { $0.bundleIdentifier == bundleID }
        guard !sameApp.isEmpty else { return nil }

        if let hint = reference.titleHint,
           let exact = sameApp.first(where: { $0.title == hint }) {
            return exact
        }
        return sameApp.first
    }

    public func resolve() async throws -> ResolvedTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        switch reference.kind {
        case .display:
            guard let displayID = reference.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { throw TargetResolutionError.targetGone("display") }

            return ResolvedTarget(
                filter: SCContentFilter(display: display, excludingWindows: []),
                descriptor: CaptureTargetDescriptor(
                    id: display.displayID,
                    kind: CaptureTargetDescriptor.Kind.display.rawValue,
                    title: "Display \(display.displayID)",
                    applicationName: nil,
                    width: display.width,
                    height: display.height
                ),
                reference: reference,
                provenance: .cache
            )

        case .window:
            let candidates = content.windows.map {
                WindowCandidate(windowID: $0.windowID,
                                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                                title: $0.title,
                                width: Int($0.frame.width),
                                height: Int($0.frame.height))
            }
            guard let match = Self.bestMatch(for: reference, among: candidates),
                  let window = content.windows.first(where: { $0.windowID == match.windowID })
            else {
                throw TargetResolutionError.targetGone(
                    reference.bundleIdentifier ?? "unknown application"
                )
            }

            return ResolvedTarget(
                filter: SCContentFilter(desktopIndependentWindow: window),
                descriptor: CaptureTargetDescriptor(
                    id: window.windowID,
                    kind: CaptureTargetDescriptor.Kind.window.rawValue,
                    title: window.title,
                    applicationName: window.owningApplication?.applicationName,
                    width: match.width,
                    height: match.height
                ),
                reference: reference,
                provenance: .cache
            )
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CachedTargetMatchingTests`
Expected: PASS — 5 new tests green, 38 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittCapture/CachedTargetResolver.swift \
        Tests/SnittCaptureTests/CachedTargetMatchingTests.swift
git commit -m "feat(capture): re-resolve cached targets by bundle id

Matching ignores window ids because they change every relaunch. A stale
title hint falls back to the app's first window rather than failing —
recording the right app beats recording nothing.

This is knowingly the bypass path and incurs the monthly prompt; no picker
replay API exists (V12), so that is a cost, not an oversight."
```

---

## Task 6: PickerTargetResolver

**Files:**
- Create: `Sources/SnittCapture/PickerTargetResolver.swift`
- Create: `Tests/SnittCaptureTests/PickerObserverTests.swift`

**Interfaces:**
- Consumes: `ResolvedTarget`, `TargetResolver`, `TargetResolutionError`
- Produces:
  - `public final class PickerTargetResolver: TargetResolver`
  - `public init(allowedModes: SCContentSharingPickerMode = [.singleWindow, .singleApplication])`
  - `final class PickerObserver: NSObject, SCContentSharingPickerObserver` — internal, holds the continuation

**Do not attempt to cache or replay the picker's result here.** V12: the picker
has no replay API. Reuse happens by storing a `TargetReference` (Task 3) and
re-resolving through `CachedTargetResolver` (Task 5), which is a different
mechanism with a different cost.

**Testing note:** the picker cannot be driven in tests — it is system UI
requiring a human. The tests cover the observer's continuation bookkeeping,
which is where the real bugs live (double-resume crashes Swift concurrency).

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/PickerObserverTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittCapture

@Test("The observer delivers exactly one outcome even if signalled twice")
func observerDeliversOnce() async throws {
    let box = PickerOutcomeBox()

    let first = await box.deliver(.failure(.cancelled))
    let second = await box.deliver(.failure(.unavailable))

    #expect(first == true, "the first outcome must be accepted")
    #expect(second == false,
            "a second outcome must be refused — resuming a continuation twice traps")
}

@Test("The observer reports whether it has already completed")
func observerTracksCompletion() async {
    let box = PickerOutcomeBox()
    #expect(await box.hasCompleted == false)
    _ = await box.deliver(.failure(.cancelled))
    #expect(await box.hasCompleted == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PickerObserverTests`
Expected: FAIL — `cannot find 'PickerOutcomeBox' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/PickerTargetResolver.swift`:

```swift
import Foundation
import ScreenCaptureKit

/// Guards continuation resumption.
///
/// `SCContentSharingPicker` can signal more than once — a cancel following an
/// update, for instance. Resuming a Swift continuation twice is a runtime trap,
/// so every outcome funnels through here and only the first is accepted.
actor PickerOutcomeBox {
    private(set) var hasCompleted = false

    /// Returns true if this outcome was accepted, false if one already arrived.
    @discardableResult
    func deliver(_ outcome: Result<ResolvedTarget, TargetResolutionError>) -> Bool {
        guard !hasCompleted else { return false }
        hasCompleted = true
        stored = outcome
        return true
    }

    private(set) var stored: Result<ResolvedTarget, TargetResolutionError>?
}

/// Presents the system window picker and returns what the human chose.
///
/// This is the only path that avoids the monthly re-consent prompt (§5.2) — and
/// it works only when a human is present to choose. There is no API to replay a
/// prior selection (V12); reuse goes through `CachedTargetResolver` instead, at
/// the cost of the prompt.
public final class PickerTargetResolver: NSObject, TargetResolver, @unchecked Sendable {
    private let allowedModes: SCContentSharingPickerMode
    private let box = PickerOutcomeBox()
    private var continuation: CheckedContinuation<ResolvedTarget, Error>?

    public init(allowedModes: SCContentSharingPickerMode = [.singleWindow,
                                                            .singleApplication]) {
        self.allowedModes = allowedModes
        super.init()
    }

    public func resolve() async throws -> ResolvedTarget {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw TargetResolutionError.unavailable }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = allowedModes
        picker.configuration = configuration

        picker.add(self)
        picker.isActive = true
        defer {
            picker.remove(self)
            picker.isActive = false
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }
    }

    private func finish(_ outcome: Result<ResolvedTarget, TargetResolutionError>) {
        Task {
            guard await box.deliver(outcome) else { return }
            guard let continuation else { return }
            self.continuation = nil
            switch outcome {
            case .success(let target): continuation.resume(returning: target)
            case .failure(let error):  continuation.resume(throwing: error)
            }
        }
    }
}

extension PickerTargetResolver: SCContentSharingPickerObserver {
    public func contentSharingPicker(_ picker: SCContentSharingPicker,
                                     didUpdateWith filter: SCContentFilter,
                                     for stream: SCStream?) {
        // The picker hands back a finished filter but no descriptor, so the
        // dimensions come from the filter's own content rect.
        let rect = filter.contentRect
        let scale = filter.pointPixelScale
        let descriptor = CaptureTargetDescriptor(
            id: 0,
            kind: CaptureTargetDescriptor.Kind.window.rawValue,
            title: nil,
            applicationName: nil,
            width: Int(rect.width * CGFloat(scale)),
            height: Int(rect.height * CGFloat(scale))
        )
        finish(.success(ResolvedTarget(filter: filter,
                                       descriptor: descriptor,
                                       reference: nil,
                                       provenance: .picker)))
    }

    public func contentSharingPicker(_ picker: SCContentSharingPicker,
                                     didCancelFor stream: SCStream?) {
        finish(.failure(.cancelled))
    }

    public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(.unavailable))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PickerObserverTests`
Expected: PASS — 2 new tests green, 40 total.

- [ ] **Step 5: Verify strict concurrency is still clean**

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero warnings, zero errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittCapture/PickerTargetResolver.swift \
        Tests/SnittCaptureTests/PickerObserverTests.swift
git commit -m "feat(capture): add SCContentSharingPicker resolver

The picker can signal more than once (a cancel after an update), and
resuming a continuation twice is a runtime trap, so outcomes funnel through
an actor that accepts only the first.

This is the only path that avoids the monthly prompt, and only when a human
is present. Reuse goes through CachedTargetResolver instead — the picker has
no replay API (V12)."
```

---

## Task 7: CaptureSession and Recorder accept a ResolvedTarget

**Files:**
- Modify: `Sources/SnittCapture/CaptureSession.swift`
- Modify: `Sources/SnittCapture/Recorder.swift`
- Modify: `Sources/SnittCapture/CaptureTarget.swift`
- Modify: `Tests/SnittCaptureTests/RecorderTests.swift`

**Interfaces:**
- Consumes: `ResolvedTarget` (Task 4)
- Produces:
  - `CaptureSession.init(target: ResolvedTarget, sink: SampleBufferSink, options: CaptureOptions)` — replaces the `CaptureTarget` initializer
  - `Recorder.init(target: ResolvedTarget, bundleURL: URL, options: CaptureOptions, initiator: Initiator)` — replaces the `CaptureTarget` initializer
  - `CaptureTarget.available()` retained, marked deprecated in favour of resolvers

**This is the rework the fork exists for.** `CaptureSession.start()` currently
calls `target.contentFilter()` to build a filter itself. After this task the
filter arrives already built, so the session stops participating in selection at
all.

- [ ] **Step 1: Update the Recorder tests to the new initializer**

In `Tests/SnittCaptureTests/RecorderTests.swift` there are no direct uses of
`CaptureTarget` (the tests use `Recorder.forTesting`), so they should compile
unchanged. Run them first to confirm that baseline:

Run: `swift test --filter RecorderTests`
Expected: PASS — 4 tests, unchanged.

- [ ] **Step 2: Change CaptureSession to take a ResolvedTarget**

In `Sources/SnittCapture/CaptureSession.swift`:

Replace the stored property and initializer:

```swift
    private let target: ResolvedTarget?
```

```swift
    public init(target: ResolvedTarget,
                sink: SampleBufferSink,
                options: CaptureOptions = CaptureOptions()) {
        self.target = target
        self.sink = sink
        self.options = options
        super.init()
    }
```

In `start()`, replace the descriptor and filter lines. Where it currently reads
`let descriptor = target.descriptor` and
`SCStream(filter: target.contentFilter(), ...)`, use the already-resolved filter:

```swift
        guard let target else { throw CaptureError.notRunning }

        let descriptor = target.descriptor
        let configuration = SCStreamConfiguration()
        configuration.width = descriptor.width
        configuration.height = descriptor.height
        configuration.capturesAudio = options.captureSystemAudio
        configuration.captureMicrophone = options.captureMicrophone
        configuration.channelCount = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        // The filter arrives already resolved — by the picker for interactive
        // selection, or by cache re-resolution for the hotkey path. The session
        // deliberately does not participate in selection (§5.2).
        let stream = SCStream(filter: target.filter,
                              configuration: configuration,
                              delegate: nil)
```

- [ ] **Step 3: Change Recorder to take a ResolvedTarget**

In `Sources/SnittCapture/Recorder.swift`, change the initializer signature and
the videoSize derivation:

```swift
    public init(target: ResolvedTarget,
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
```

- [ ] **Step 4: Deprecate the old enumeration entry point**

In `Sources/SnittCapture/CaptureTarget.swift`, add the deprecation attribute
directly above `public static func available()`, keeping the existing
`- Important:` doc comment:

```swift
    @available(*, deprecated,
               message: "Use PickerTargetResolver or CachedTargetResolver. This enumerates directly, which is the bypass path (§5.2).")
    public static func available() async throws -> [CaptureTarget] {
```

- [ ] **Step 5: Update snitt-probe to the new API**

In `Sources/snitt-probe/main.swift`, replace the target selection block. Where it
calls `CaptureTarget.available()` and picks a display, use a display reference
through the cached resolver instead:

```swift
let resolver = CachedTargetResolver(
    reference: .display(id: CGMainDisplayID())
)

let resolved: ResolvedTarget
do {
    resolved = try await resolver.resolve()
} catch {
    fail("Could not resolve the main display: \(error)",
         hint: "This almost always means Screen Recording is still denied.")
}

print("Recording display: \(resolved.descriptor.width)x\(resolved.descriptor.height)")
```

Then pass `target: resolved` to `Recorder(...)` instead of `target: display`.
Add `import CoreGraphics` at the top if it is not already present.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS — 40 tests, 0 failures.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittCapture Sources/snitt-probe Tests/SnittCaptureTests
git commit -m "refactor(capture): sessions take an already-resolved target

CaptureSession no longer builds its own SCContentFilter. Both selection
paths — picker and cache — deliver a finished filter, so the session stops
participating in selection entirely. CaptureTarget.available() is retained
for the headless case but deprecated toward the resolvers."
```

---

## Task 8: Clipboard destination

**Files:**
- Create: `Sources/SnittExport/ClipboardDestination.swift`
- Create: `Tests/SnittExportTests/ClipboardDestinationTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - New target `SnittExport` depending on `SnittDocument`
  - `public enum ClipboardDestination` with
    `static func pasteboardItems(for fileURL: URL) -> [NSPasteboardWriting]`
    and `static func copy(fileURL: URL, to pasteboard: NSPasteboard) -> Bool`

**Why this is its own target:** §6's architecture lists `SnittExport` as a
module. Introducing it here, with one small responsibility, keeps the boundary
honest rather than letting clipboard code accrete inside the app.

**Why copying happens at all (§4.1, D18):** the distance from "the file exists on
disk" to "it is pasted in Slack" is where the §1 clock is actually lost. Copying
is the default outcome of stopping, not a subsequent step.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittExportTests/ClipboardDestinationTests.swift`:

```swift
import Testing
import Foundation
import AppKit
@testable import SnittExport

@Test("A file URL becomes a pasteboard item")
func fileBecomesPasteboardItem() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("not a real movie".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let items = ClipboardDestination.pasteboardItems(for: url)
    #expect(items.count == 1)
}

@Test("Copying writes a file URL a paste target can read back")
func copyWritesReadableURL() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("not a real movie".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    // A uniquely-named pasteboard, so the test never disturbs the user's own.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    let ok = ClipboardDestination.copy(fileURL: url, to: pasteboard)

    #expect(ok)
    let read = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    #expect(read?.first?.lastPathComponent == url.lastPathComponent)
}

@Test("Copying a file that does not exist fails rather than clearing the clipboard")
func missingFileDoesNotClobberClipboard() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp4")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    pasteboard.clearContents()
    pasteboard.setString("something the user copied earlier", forType: .string)

    let ok = ClipboardDestination.copy(fileURL: missing, to: pasteboard)

    #expect(ok == false)
    #expect(pasteboard.string(forType: .string) == "something the user copied earlier",
            "a failed copy must not destroy what the user already had")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipboardDestinationTests`
Expected: FAIL — `no such module 'SnittExport'`.

- [ ] **Step 3: Write minimal implementation**

Add to `Package.swift` — a product, a target, and a test target:

```swift
        .library(name: "SnittExport", targets: ["SnittExport"]),
```

```swift
        .target(name: "SnittExport", dependencies: ["SnittDocument"]),
```

```swift
        .testTarget(name: "SnittExportTests", dependencies: ["SnittExport"]),
```

Create `Sources/SnittExport/ClipboardDestination.swift`:

```swift
import Foundation
import AppKit

/// Puts a finished recording on the clipboard.
///
/// Copying is the default outcome of stopping a recording, not a step the user
/// takes afterwards (§4.1). The gap between "the file exists" and "it is pasted
/// into Slack" is where the time-to-share budget is actually spent.
public enum ClipboardDestination {
    public static func pasteboardItems(for fileURL: URL) -> [NSPasteboardWriting] {
        [fileURL as NSURL]
    }

    /// Copies the file, returning false if it could not be copied.
    ///
    /// A missing file is refused BEFORE the pasteboard is cleared, so a failed
    /// copy never destroys whatever the user already had on their clipboard.
    @discardableResult
    public static func copy(fileURL: URL, to pasteboard: NSPasteboard) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(pasteboardItems(for: fileURL))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipboardDestinationTests`
Expected: PASS — 3 new tests green, 43 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittExport Tests/SnittExportTests Package.swift
git commit -m "feat(export): copy finished recordings to the clipboard

Copying is the default outcome of stopping, not a later step — the gap
between 'file exists' and 'pasted into Slack' is where the time-to-share
budget goes. A missing file is refused before the pasteboard is cleared, so
a failed copy never destroys what the user already had."
```

---

## Task 9: Menu-bar app shell with recording indicator and kill switch

**Files:**
- Create: `Sources/SnittApp/SnittApp.swift`
- Create: `Sources/SnittApp/StatusItemController.swift`
- Create: `Tests/SnittAppTests/StatusItemStateTests.swift`
- Modify: `Package.swift`
- Modify: `Scripts/make-app.sh`

**Interfaces:**
- Consumes: nothing yet (wired to recording in Task 11)
- Produces:
  - New executable target `SnittApp`
  - `public enum RecordingState: Equatable, Sendable { case idle, recording(startedAt: Date), stopping }`
  - `public struct StatusItemPresentation: Equatable` with `symbolName: String`, `title: String`, `isStopEnabled: Bool`
  - `public static func presentation(for state: RecordingState, now: Date) -> StatusItemPresentation`
  - `final class StatusItemController` — owns the `NSStatusItem`

**Why the status item is here and not later (§5, D12):** §5.3 requires a visible
indicator for the entire duration of any agent-initiated session plus a kill
switch that stops it immediately. That is a safety guarantee, and a guarantee
whose enforcement mechanism ships in a later milestone is not a guarantee. The
indicator must exist before anything can start a recording without a window
open.

**Testing note:** `NSStatusItem` is UI and cannot be asserted on meaningfully.
The presentation *logic* — what the item should show for a given state — is pure
and gets covered.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/StatusItemStateTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp

@Test("Idle shows the record affordance and no stop control")
func idlePresentation() {
    let p = StatusItemController.presentation(for: .idle, now: Date())
    #expect(p.isStopEnabled == false)
    #expect(p.symbolName == "record.circle")
}

@Test("Recording shows elapsed time and an enabled stop control")
func recordingPresentation() {
    let started = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_065)
    let p = StatusItemController.presentation(for: .recording(startedAt: started),
                                              now: now)
    #expect(p.isStopEnabled == true)
    #expect(p.title == "1:05", "elapsed time must be visible while recording")
    #expect(p.symbolName == "stop.circle.fill")
}

@Test("Elapsed time pads seconds below ten")
func elapsedPadsSeconds() {
    let started = Date(timeIntervalSince1970: 0)
    let p = StatusItemController.presentation(for: .recording(startedAt: started),
                                              now: Date(timeIntervalSince1970: 63))
    #expect(p.title == "1:03")
}

@Test("Stopping disables the stop control so it cannot be pressed twice")
func stoppingDisablesStop() {
    let p = StatusItemController.presentation(for: .stopping, now: Date())
    #expect(p.isStopEnabled == false,
            "a second stop press during finalization must be impossible")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StatusItemStateTests`
Expected: FAIL — `no such module 'SnittApp'`.

- [ ] **Step 3: Write minimal implementation**

Add to `Package.swift`:

```swift
        .executableTarget(
            name: "SnittApp",
            dependencies: ["SnittCapture", "SnittDocument", "SnittExport"]
        ),
        .testTarget(name: "SnittAppTests", dependencies: ["SnittApp"]),
```

Create `Sources/SnittApp/StatusItemController.swift`:

```swift
import AppKit
import Foundation

public enum RecordingState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case stopping
}

public struct StatusItemPresentation: Equatable {
    public var symbolName: String
    public var title: String
    public var isStopEnabled: Bool
}

/// Owns the menu-bar item: the recording indicator and the kill switch.
///
/// §5.3 requires a visible indicator for the whole duration of a recording and
/// a control that stops it immediately. Both live here, and both exist before
/// anything can start a recording without a visible window.
///
/// `NSObject` subclass because the click handler is an `@objc` selector target.
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private(set) var state: RecordingState = .idle

    /// What the menu-bar item should show. Pure, so it can be tested without UI.
    public static func presentation(for state: RecordingState,
                                    now: Date) -> StatusItemPresentation {
        switch state {
        case .idle:
            return StatusItemPresentation(symbolName: "record.circle",
                                          title: "",
                                          isStopEnabled: false)
        case .recording(let startedAt):
            let elapsed = Int(now.timeIntervalSince(startedAt))
            let text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            return StatusItemPresentation(symbolName: "stop.circle.fill",
                                          title: text,
                                          isStopEnabled: true)
        case .stopping:
            return StatusItemPresentation(symbolName: "stop.circle",
                                          title: "Saving…",
                                          isStopEnabled: false)
        }
    }

    /// Invoked when the user clicks the menu-bar item. This is §5.3's kill
    /// switch: a control that stops a recording immediately. Wired by the app
    /// delegate; without it the item would be a display-only indicator and the
    /// safety guarantee would be unmet.
    var onClick: (() -> Void)?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        statusItem = item
        apply(.idle)
    }

    @objc private func handleClick() {
        onClick?()
    }

    func update(_ newState: RecordingState) {
        state = newState
        apply(newState)

        timer?.invalidate()
        timer = nil
        if case .recording = newState {
            // Refresh the elapsed-time readout once a second so the indicator
            // is visibly live rather than a static dot.
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, case .recording = self.state else { return }
                self.apply(self.state)
            }
        }
    }

    private func apply(_ state: RecordingState) {
        let p = Self.presentation(for: state, now: Date())
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: p.symbolName,
                               accessibilityDescription: "Snitt")
        button.title = p.title.isEmpty ? "" : " \(p.title)"
    }
}
```

Create `Sources/SnittApp/SnittApp.swift`:

```swift
import AppKit

/// Menu-bar app entry point.
///
/// An accessory app: no Dock icon, no window at launch. §4.11 requires that
/// recording start from a keystroke without a window ever opening, so the app
/// must be able to live entirely in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StatusItemStateTests`
Expected: PASS — 4 new tests green, 47 total.

- [ ] **Step 5: Point make-app.sh at the real app**

In `Scripts/make-app.sh`, replace the `snitt-probe` product name with `SnittApp`
in both the build command and the binary path check, and copy it to
`$APP/Contents/MacOS/Snitt` as before:

```bash
swift build -c debug --product SnittApp

if [ ! -f ".build/debug/SnittApp" ]; then
  echo "error: swift build did not produce .build/debug/SnittApp" >&2
  exit 1
fi
```

```bash
cp ".build/debug/SnittApp" "$APP/Contents/MacOS/Snitt"
```

- [ ] **Step 6: Verify the menu-bar item appears**

Run:

```bash
./Scripts/make-app.sh
open build/Snitt.app
```

Expected: a record-circle icon appears in the menu bar and no Dock icon or window
appears. Quit it with `pkill -f Snitt.app` when you have confirmed.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests Package.swift Scripts/make-app.sh
git commit -m "feat(app): add menu-bar shell with indicator and kill switch

Section 5.3 requires a visible indicator for a recording's whole duration
plus a control that stops it immediately. Both ship before anything can
start a recording without a window — a safety guarantee whose enforcement
arrives in a later milestone is not a guarantee.

Presentation logic is pure and tested; NSStatusItem itself is not."
```

---

## Task 10: Global hotkey

**Files:**
- Create: `Sources/SnittApp/HotkeyMonitor.swift`
- Create: `Tests/SnittAppTests/HotkeyMonitorTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct HotkeyCombination: Equatable, Sendable` with
    `keyCode: UInt32`, `modifiers: UInt32`
  - `public static let defaultCombination: HotkeyCombination` — ⌥⌘5
  - `public final class HotkeyMonitor` with `init(combination:onFire:)`,
    `func start() throws`, `func stop()`
  - `public enum HotkeyError: Error, Equatable { case registrationFailed(OSStatus) }`

**Why Carbon and not `NSEvent` (S1 finding):** `NSEvent.addGlobalMonitorForEvents`
requires the **Accessibility** grant — spike S1 measured `keyDown` at zero even
with Input Monitoring granted, because they are different TCC services. Carbon's
`RegisterEventHotKey` registers a specific combination with the window server and
needs **no permission at all**. For a hotkey that must work on first run without
a permission wall (§4.10's one-dialog budget), Carbon is the only option that
costs nothing.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/HotkeyMonitorTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp

@Test("The default combination is option-command-5")
func defaultCombinationIsOptCmd5() {
    let c = HotkeyCombination.defaultCombination
    // kVK_ANSI_5 is 0x17.
    #expect(c.keyCode == 0x17)
    #expect(c.modifiers != 0, "a bare keycode with no modifiers would hijack the key")
}

@Test("Combinations compare by keycode and modifiers together")
func combinationsCompareOnBothFields() {
    let a = HotkeyCombination(keyCode: 0x17, modifiers: 1)
    let b = HotkeyCombination(keyCode: 0x17, modifiers: 2)
    let c = HotkeyCombination(keyCode: 0x17, modifiers: 1)
    #expect(a != b)
    #expect(a == c)
}

@Test("Registering the same monitor twice is refused rather than duplicating")
func doubleStartIsSafe() throws {
    let monitor = HotkeyMonitor(combination: .defaultCombination) {}
    try monitor.start()
    defer { monitor.stop() }
    // A second start must not register a second handler for the same
    // combination — that would fire the callback twice per press.
    try monitor.start()
    #expect(monitor.isRegistered)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotkeyMonitorTests`
Expected: FAIL — `cannot find 'HotkeyCombination' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittApp/HotkeyMonitor.swift`:

```swift
import AppKit
import Carbon.HIToolbox

public struct HotkeyCombination: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Option-Command-5. Deliberately near ⌘⇧5, the system recorder's shortcut,
    /// without colliding with it.
    public static let defaultCombination = HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_5),
        modifiers: UInt32(optionKey | cmdKey)
    )
}

public enum HotkeyError: Error, Equatable {
    case registrationFailed(OSStatus)
}

/// A global hotkey that needs no permission.
///
/// Deliberately Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`. Spike S1 measured global `NSEvent`
/// keyDown at zero even with Input Monitoring granted, because AppKit global
/// key monitors are gated by **Accessibility** — a broader grant, and one more
/// users refuse. `RegisterEventHotKey` registers one combination with the
/// window server and requires no TCC grant at all, which is what lets the
/// hotkey work inside §4.10's one-dialog first-run budget.
public final class HotkeyMonitor {
    private let combination: HotkeyCombination
    private let onFire: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    public private(set) var isRegistered = false

    public init(combination: HotkeyCombination, onFire: @escaping () -> Void) {
        self.combination = combination
        self.onFire = onFire
    }

    public func start() throws {
        guard !isRegistered else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>
                .fromOpaque(userData).takeUnretainedValue()
            monitor.onFire()
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else { throw HotkeyError.registrationFailed(status) }

        var hotKeyID = EventHotKeyID(signature: OSType(0x534E_5454), id: 1) // 'SNTT'
        let registerStatus = RegisterEventHotKey(
            combination.keyCode, combination.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            throw HotkeyError.registrationFailed(registerStatus)
        }

        isRegistered = true
    }

    public func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        isRegistered = false
    }

    deinit { stop() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HotkeyMonitorTests`
Expected: PASS — 3 new tests green, 50 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittApp/HotkeyMonitor.swift Tests/SnittAppTests/HotkeyMonitorTests.swift
git commit -m "feat(app): add a global hotkey that needs no permission

Carbon RegisterEventHotKey rather than NSEvent global monitors. Spike S1
measured NSEvent keyDown at zero even with Input Monitoring granted, because
AppKit global key monitors are gated by Accessibility — a broader grant
users refuse more often. RegisterEventHotKey needs no TCC grant at all,
which is what keeps the hotkey inside the one-dialog first-run budget."
```

---

## Task 11: Wire it together — record, stop, copy

**Files:**
- Create: `Sources/SnittApp/RecordingCoordinator.swift`
- Create: `Sources/SnittApp/ConsentExplainer.swift`
- Create: `Tests/SnittAppTests/RecordingCoordinatorTests.swift`
- Modify: `Sources/SnittApp/SnittApp.swift`

**Interfaces:**
- Consumes: `TargetResolver`, `ResolvedTarget`, `TargetStore`, `StoredTargetReference`, `Recorder`, `ClipboardDestination`, `StatusItemController`, `HotkeyMonitor`
- Produces:
  - `public actor RecordingCoordinator`
  - `init(pickerResolver: TargetResolver, cachedResolverFactory: @Sendable (TargetReference) -> TargetResolver, store: TargetStore, outputDirectory: URL)`
  - `func toggle() async -> CoordinatorOutcome`
  - `public enum CoordinatorOutcome: Equatable, Sendable { case started(String), stopped(URL, copied: Bool), cancelled, failed(String) }`
  - `static func resolverChoice(hasCachedTarget: Bool) -> ResolverChoice`
  - `public enum ResolverChoice: Equatable { case picker, cache }`

**This is where §4.11's decision becomes code (D36):** the hotkey reuses the last
approved target through the cache; the picker appears only when there is nothing
cached. That costs the monthly prompt, deliberately — a per-recording picker
would cost far more.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/RecordingCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp

@Test("With no cached target the picker is used")
func firstRunUsesPicker() {
    #expect(RecordingCoordinator.resolverChoice(hasCachedTarget: false) == .picker)
}

@Test("With a cached target the cache is used, not the picker")
func laterRunsUseCache() {
    #expect(RecordingCoordinator.resolverChoice(hasCachedTarget: true) == .cache,
            "the hotkey must not present a picker on every press")
}

@Test("Outcomes distinguish cancellation from failure")
func outcomesAreDistinguishable() {
    #expect(CoordinatorOutcome.cancelled != CoordinatorOutcome.failed("x"))
    #expect(CoordinatorOutcome.failed("a") != CoordinatorOutcome.failed("b"))
}

@Test("A stopped outcome reports whether the copy succeeded")
func stoppedReportsCopyResult() {
    let url = URL(fileURLWithPath: "/tmp/x.snitt")
    #expect(CoordinatorOutcome.stopped(url, copied: true)
            != CoordinatorOutcome.stopped(url, copied: false),
            "the user must be told if the clipboard copy failed")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingCoordinatorTests`
Expected: FAIL — `cannot find 'RecordingCoordinator' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittApp/RecordingCoordinator.swift`:

```swift
import Foundation
import AppKit
import SnittCapture
import SnittDocument
import SnittExport

public enum ResolverChoice: Equatable, Sendable {
    case picker
    case cache
}

public enum CoordinatorOutcome: Equatable, Sendable {
    case started(String)
    case stopped(URL, copied: Bool)
    case cancelled
    case failed(String)
}

/// Drives one recording from hotkey press to clipboard.
public actor RecordingCoordinator {
    private let pickerResolver: TargetResolver
    private let cachedResolverFactory: @Sendable (TargetReference) -> TargetResolver
    private let store: TargetStore
    private let outputDirectory: URL

    private var active: Recorder?

    public init(pickerResolver: TargetResolver,
                cachedResolverFactory: @escaping @Sendable (TargetReference) -> TargetResolver,
                store: TargetStore,
                outputDirectory: URL) {
        self.pickerResolver = pickerResolver
        self.cachedResolverFactory = cachedResolverFactory
        self.store = store
        self.outputDirectory = outputDirectory
    }

    /// Which resolver a hotkey press should use.
    ///
    /// The picker appears only when nothing is cached. Presenting it on every
    /// press would put a system dialog between a keystroke and a recording,
    /// every time, forever — which costs far more than the monthly re-consent
    /// prompt the cache path incurs (§4.11, D36).
    public static func resolverChoice(hasCachedTarget: Bool) -> ResolverChoice {
        hasCachedTarget ? .cache : .picker
    }

    public func toggle() async -> CoordinatorOutcome {
        if active != nil { return await stopRecording() }
        return await startRecording()
    }

    private func startRecording() async -> CoordinatorOutcome {
        let stored = store.load()
        let choice = Self.resolverChoice(hasCachedTarget: stored != nil)

        let resolver: TargetResolver
        switch choice {
        case .cache:
            guard let stored, let reference = Self.reference(from: stored) else {
                return .failed("The cached target could not be read.")
            }
            resolver = cachedResolverFactory(reference)
        case .picker:
            resolver = pickerResolver
        }

        let target: ResolvedTarget
        do {
            target = try await resolver.resolve()
        } catch TargetResolutionError.cancelled {
            return .cancelled
        } catch TargetResolutionError.targetGone(let app) {
            // The cached app is gone. Clear the stale cache so the next press
            // offers the picker rather than failing again.
            try? store.clear()
            return .failed("\(app) is no longer available. Press again to pick a new target.")
        } catch {
            return .failed("Could not resolve a target: \(error)")
        }

        if let reference = target.reference, let stored = Self.stored(from: reference) {
            try? store.save(stored)
        }

        let url = outputDirectory.appendingPathComponent(
            "Snitt-\(Int(Date().timeIntervalSince1970)).snitt"
        )
        do {
            let recorder = try Recorder(target: target, bundleURL: url)
            try await recorder.start()
            active = recorder
            return .started(target.descriptor.title ?? "screen")
        } catch {
            return .failed("Could not start recording: \(error)")
        }
    }

    private func stopRecording() async -> CoordinatorOutcome {
        guard let recorder = active else { return .failed("Not recording.") }
        active = nil
        do {
            let bundle = try await recorder.stop()
            let copied = ClipboardDestination.copy(fileURL: bundle.captureURL,
                                                   to: .general)
            return .stopped(bundle.url, copied: copied)
        } catch {
            return .failed("Recording failed to finalize: \(error)")
        }
    }

    static func reference(from stored: StoredTargetReference) -> TargetReference? {
        switch stored.kind {
        case "window":
            guard let bundleID = stored.bundleIdentifier else { return nil }
            return .window(bundleIdentifier: bundleID, titleHint: stored.titleHint)
        case "display":
            guard let id = stored.displayID else { return nil }
            return .display(id: id)
        default:
            return nil
        }
    }

    static func stored(from reference: TargetReference) -> StoredTargetReference? {
        StoredTargetReference(kind: reference.kind.rawValue,
                              bundleIdentifier: reference.bundleIdentifier,
                              titleHint: reference.titleHint,
                              displayID: reference.displayID)
    }
}
```

Create `Sources/SnittApp/ConsentExplainer.swift`:

```swift
import AppKit
import Foundation

/// Explains the recurring macOS re-consent prompt, once (§5.5).
///
/// Hotkey recordings resolve targets via `SCShareableContent`, which macOS
/// charges a monthly re-consent prompt for. That cost is accepted deliberately
/// (§4.11) — but an unexplained recurring prompt reads as an app misbehaving,
/// so Snitt explains it the first time rather than letting the user guess.
enum ConsentExplainer {
    private static let shownKey = "com.impressiver.snitt.consentExplainerShown"

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = "macOS will ask about screen recording periodically"
        alert.informativeText = """
        To start recording instantly from a keystroke, Snitt reuses your last \
        chosen window rather than asking you to pick one every time.

        macOS re-confirms screen-recording access for apps that work this way, \
        about once a month. That prompt is macOS asking, not Snitt — approving \
        it keeps instant capture working.
        """
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }
}
```

- [ ] **Step 4: Wire the coordinator into the app**

Replace the body of `AppDelegate` in `Sources/SnittApp/SnittApp.swift`:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private var hotkey: HotkeyMonitor?
    private var coordinator: RecordingCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()

        let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")

        let coordinator = RecordingCoordinator(
            pickerResolver: PickerTargetResolver(),
            cachedResolverFactory: { CachedTargetResolver(reference: $0) },
            store: TargetStore(fileURL: TargetStore.defaultURL()),
            outputDirectory: outputDirectory
        )
        self.coordinator = coordinator

        let monitor = HotkeyMonitor(combination: .defaultCombination) { [weak self] in
            self?.handleHotkey()
        }
        try? monitor.start()
        hotkey = monitor

        // §5.3's kill switch: clicking the menu-bar item does the same thing as
        // the hotkey, so a recording can always be stopped by mouse alone —
        // which matters when the hotkey is what someone is demonstrating.
        statusItem.onClick = { [weak self] in
            self?.handleHotkey()
        }
    }

    private func handleHotkey() {
        guard let coordinator else { return }
        Task { @MainActor in
            ConsentExplainer.showIfNeeded()
            let outcome = await coordinator.toggle()
            switch outcome {
            case .started:
                statusItem.update(.recording(startedAt: Date()))
            case .stopped(let url, let copied):
                statusItem.update(.idle)
                notify(copied ? "Copied to clipboard" : "Saved to \(url.lastPathComponent)")
            case .cancelled:
                statusItem.update(.idle)
            case .failed(let message):
                statusItem.update(.idle)
                notify(message)
            }
        }
    }

    private func notify(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

Add the imports at the top of the file:

```swift
import AppKit
import Foundation
import SnittCapture
import SnittDocument
```

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS — 54 tests, 0 failures.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero warnings.

- [ ] **Step 6: Manual end-to-end verification**

Run:

```bash
./Scripts/make-app.sh
open build/Snitt.app
```

Then, in order:

1. Press **⌥⌘5**. The consent explainer appears once — read it, dismiss it.
2. The system picker appears (nothing is cached yet). Choose a window.
3. The menu-bar item switches to a stop symbol with a live elapsed timer.
4. Press **⌥⌘5** again. Recording stops; a "Copied to clipboard" alert appears.
5. Paste into any app that accepts files — the recording pastes.
6. Press **⌥⌘5** twice more. **The picker must NOT appear this time** — the
   cached target is reused. This is the check that matters most; if the picker
   reappears, §4.11's whole premise is broken and the cache is not working.
7. Confirm a `.snitt` bundle exists on the Desktop with a `capture.mov` inside.
8. Start one more recording with the hotkey, then **stop it by clicking the
   menu-bar item** rather than pressing the hotkey. It must stop. This is §5.3's
   kill switch, and it has to work by mouse alone — the hotkey is unusable as a
   stop control precisely when someone is demonstrating hotkeys.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests
git commit -m "feat(app): wire hotkey to record, stop, and copy

The picker appears only when nothing is cached; later presses reuse the
last approved target. That costs the monthly re-consent prompt deliberately
— a picker between every keystroke and its recording would cost far more.

A vanished cached target clears the cache so the next press offers the
picker rather than failing twice. The recurring prompt is explained once, so
it reads as macOS asking rather than Snitt misbehaving."
```

---

## Definition of done for M2a

- [ ] `swift test` passes — 54 tests, 0 failures
- [ ] `swift build -Xswiftc -strict-concurrency=complete` emits zero warnings
- [ ] `codesign -dv build/Snitt.app` shows the same `Authority` across two consecutive builds
- [ ] Pressing ⌥⌘5 twice in a row records and stops **without showing the picker the second time**
- [ ] A finished recording is on the clipboard and pastes into another app
- [ ] The menu-bar indicator shows a live elapsed timer for the whole recording
- [ ] Clicking the menu-bar item stops a recording (§5.3's kill switch, by mouse alone)
- [ ] `docs/superpowers/spikes/S4-nag-scoping.md` exists with its observation table open

## What this plan deliberately does not build

`SnittAutomation`, the IPC server and version handshake, the CLI, the MCP server,
and consent enforcement for agents are **M2b** and get their own plan. Event
logging, markers, `--auto-trim`, and progressive permission onboarding are M3.
The EDL and timeline are M4.

**One thing this plan cannot resolve:** spike S4 asks whether the monthly prompt
is scoped per-app or per-recording-path. Task 2 opens the observation, but the
answer takes weeks by construction. If it returns "per-app", then §5.2's residual
justification for picker adoption weakens considerably and the picker may be
worth dropping — but nothing in M2a needs to change either way, which is why the
milestone does not wait on it.
