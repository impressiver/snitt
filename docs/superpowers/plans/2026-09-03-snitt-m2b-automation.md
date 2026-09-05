# Snitt M2b: The Automation Surface — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a coding agent record a demo — start, stop, and retrieve a `.snitt` bundle — over a CLI and an MCP server, without a human at the keyboard.

**Architecture:** One `SnittAutomation` core owns sessions and enforces consent. It listens on a Unix domain socket inside the already-granted `Snitt.app`, speaking newline-delimited JSON with a version handshake. The `snitt` CLI and the MCP server are thin clients over that socket, so their behaviour cannot diverge. Nothing in a client ever touches ScreenCaptureKit.

**Tech Stack:** Swift 6, SPM, Network.framework (`NWListener`/`NWConnection`) over `NWEndpoint.unix`, Codable JSON, JSON-RPC 2.0 over stdio for MCP.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md`

**Scope:** M2b only. Event logging, markers, `--auto-trim`, auto-focus and permission onboarding are M3. The EDL and timeline are M4. Export flags (`--max-size`), `snitt inspect` and capture health moved to M3 and are **not** built here.

## Global Constraints

Copied from the spec. Every task's requirements implicitly include these.

- **The CLI must never call ScreenCaptureKit.** macOS TCC attributes a capability to the *responsible process*, and children inherit their parent's `p_responsible_pid`. A CLI capturing directly attributes the prompt to whatever launched it — Claude Code's terminal, a CI runner — and each new parent re-prompts. Clients are thin; `Snitt.app` holds the single grant and performs all capture. (§4.9)
- **There is NO persistent agent grant store.** It was specified and deleted (D34) because a stored grant cannot become an `SCContentFilter` — the picker has no replay API (V12) — so it removed a Snitt dialog while the OS prompt fired anyway. Do not reintroduce it.
- **`consent_required` means "agent recording is not enabled in settings"** (D35). It does not mean "this target lacks a grant"; there are no per-target grants.
- **Agent recording is OFF by default**, behind an explicit settings opt-in. (§5.3)
- **Agent recordings are window-scoped and cannot silently escalate to full-display.** (§5.1, §5.3)
- **Agent sessions have a maximum duration**, so a hung agent cannot fill the disk. (§5.3)
- **An agent must never block on a dialog it cannot see.** Failures return immediately as structured errors with non-zero exit codes. (§11)
- **Agent-facing output contract:** structured JSON on stdout, human-readable text on stderr, meaningful exit codes. (§4.8)
- **The visible indicator and kill switch already exist** from M2a and must cover agent sessions too. (§5.3)
- Swift 6 language mode, strict concurrency. `swift build -Xswiftc -strict-concurrency=complete` must stay at **zero warnings**. macOS 15 minimum.
- 59 tests currently pass on `main`. Every task keeps them passing.

---

## File Structure

| File | Responsibility |
|---|---|
| `Spikes/S5RealTopology/S5Probe.swift` | Throwaway: prove capture works in the real CLI→IPC→app topology |
| `Sources/SnittAutomation/Protocol.swift` | The wire types: requests, responses, errors, protocol version |
| `Sources/SnittAutomation/LineFraming.swift` | Newline-delimited JSON framing over a byte stream |
| `Sources/SnittAutomation/SocketPath.swift` | Where the socket lives, and why there |
| `Sources/SnittAutomation/AutomationServer.swift` | `NWListener`, connection handling, request dispatch |
| `Sources/SnittAutomation/AutomationClient.swift` | Client half, shared by both frontends |
| `Sources/SnittAutomation/ConsentPolicy.swift` | Pure rules: may this agent request proceed? |
| `Sources/SnittAutomation/SessionRegistry.swift` | Active agent sessions, ids, max-duration enforcement |
| `Sources/SnittApp/AutomationHost.swift` | Wires the server into the app; owns the bridge to `RecordingCoordinator` |
| `Sources/SnittApp/AgentSettings.swift` | The opt-in, persisted; read by `ConsentPolicy` |
| `Sources/snitt-cli/main.swift` | Argument parsing → one request → JSON on stdout |
| `Sources/snitt-mcp/main.swift` | JSON-RPC 2.0 over stdio → the same requests |
| `Tests/SnittAutomationTests/*.swift` | Protocol, framing, consent, registry, round-trip |

**Why one core with two thin frontends:** §4.8 requires the CLI and MCP server to be
incapable of diverging. Both construct the same `AutomationRequest` values and both go
through `AutomationClient`. A behaviour that differs between them is a bug by construction,
not a judgement call.

---

## Task 1: Spike S5 — prove the real topology before building on it

**Files:**
- Create: `Spikes/S5RealTopology/S5Probe.swift` (throwaway)
- Create: `docs/superpowers/spikes/S5-real-topology.md`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: nothing
- Produces: a written recommendation. **No production code.**

**Why this is first (§13, §4.9):** Spike S3 confirmed a *background* process can capture —
but both of its runs inherited the **terminal's** TCC grant. The production topology is
different and untested: a client whose parent is an arbitrary agent host asks `Snitt.app`,
which holds its *own* grant, to capture. §4.9's entire thin-client architecture rests on
that working. If it does not, M2b's design changes before any of it is built.

**This is a spike.** Output is the findings document. Do not build production code on it.

- [ ] **Step 1: Write the probe pair**

Create `Spikes/S5RealTopology/S5Probe.swift`:

```swift
// THROWAWAY SPIKE CODE — spec §14, S5. Do not build on this.
//
// Question: when a client whose parent is NOT Snitt asks Snitt.app over a socket
// to capture, does the capture use SNITT'S grant and produce real frames?
//
// Run `S5Probe serve` from inside a granted Snitt.app context, and
// `S5Probe ask` from an unrelated parent process.
import Foundation
import ScreenCaptureKit

let socketPath = "/tmp/snitt-s5.sock"

@main
struct S5Probe {
    static func main() async {
        switch CommandLine.arguments.dropFirst().first ?? "ask" {
        case "serve": await serve()
        default:      ask()
        }
    }

    /// Listens on a Unix socket; on any byte, captures and reports frame counts.
    static func serve() async {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strcpy(UnsafeMutableRawPointer(ptr)
                .assumingMemoryBound(to: CChar.self), $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        listen(fd, 1)
        print("S5 server listening on \(socketPath)")

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var byte: UInt8 = 0
            _ = read(client, &byte, 1)
            let result = await capture()
            var reply = result + "\n"
            _ = reply.withUTF8 { write(client, $0.baseAddress, $0.count) }
            close(client)
            print("S5 server handled a request: \(result)")
        }
    }

    /// Connects and prints whatever the server reports.
    static func ask() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strcpy(UnsafeMutableRawPointer(ptr)
                .assumingMemoryBound(to: CChar.self), $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard ok == 0 else {
            print("S5 client: could not connect — is the server running?"); exit(1)
        }
        var go: UInt8 = 1
        _ = write(fd, &go, 1)
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buffer, 512)
        print("S5 client got: " + (String(bytes: buffer[0..<max(0, n)], encoding: .utf8) ?? "?"))
        close(fd)
    }

    /// Two seconds of capture, counting frames that carry real content.
    static func capture() async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return "NO DISPLAY" }
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            let collector = FrameCounter()
            let stream = SCStream(filter: SCContentFilter(display: display,
                                                          excludingWindows: []),
                                  configuration: config, delegate: nil)
            try stream.addStreamOutput(collector, type: .screen,
                                       sampleHandlerQueue: .global())
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(2))
            try await stream.stopCapture()
            return "frames=\(collector.count) nonBlack=\(collector.nonBlack)"
        } catch {
            return "CAPTURE FAILED: \(error)"
        }
    }
}

final class FrameCounter: NSObject, SCStreamOutput, @unchecked Sendable {
    private(set) var count = 0
    private(set) var nonBlack = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        count += 1
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var sum = 0
        for row in Swift.stride(from: 0, to: CVPixelBufferGetHeight(pb), by: 32) {
            for col in Swift.stride(from: 0, to: stride, by: 256) {
                sum += Int(bytes[row * stride + col])
            }
        }
        if sum > 0 { nonBlack += 1 }
    }
}
```

Add to `Package.swift` targets:

```swift
        .executableTarget(name: "S5RealTopology", path: "Spikes/S5RealTopology"),
```

Note the non-black check samples a GRID, not one pixel column — spike S3's heuristic
sampled a single column and its findings had to record that as a limitation.

- [ ] **Step 2: Build and sign the probe as its own app**

The probe must run under an identity that is **not the terminal's**, or it cannot
answer the question it exists to ask. Two things are required and neither is optional:

- **Its own signed bundle.** TCC keys on *code identity*, not on filesystem location.
  A binary copied into `Snitt.app/Contents/MacOS/` keeps its own ad-hoc signature
  (`Identifier=S5RealTopology-5555…`, `flags=0x2(adhoc)`) and gets no share of
  `com.impressiver.snitt`'s grant — it would silently fall back to the launching
  terminal's, which is precisely what made spike S3 unable to answer this. Copying
  into the signed bundle also breaks its seal.
- **Launch through LaunchServices.** Even a correctly signed binary started from a
  shell has the terminal as its `p_responsible_pid`. Only `open` makes the app
  responsible for itself.

Create `Scripts/make-s5-probe-app.sh`, modelled on `Scripts/make-app.sh` — same
`set -euo pipefail`, same `Scripts/signing-identity.sh` call with the same ad-hoc
fallback and warning. It assembles `build/S5Server.app` with `CFBundleExecutable`
`S5Server`, `CFBundleIdentifier` `com.impressiver.snitt.s5probe`,
`LSMinimumSystemVersion` `15.0`, and `LSUIElement` true, copying
`.build/debug/S5RealTopology` in as `Contents/MacOS/S5Server`.

Because `open` leaves the server with no stdout, add a `log()` helper to
`S5Probe.swift` that appends to `~/Desktop/S5-server.log`, and use it for every
message `serve()` emits. Leave `ask()` printing to stdout — it runs in a terminal.

- [ ] **Step 3: Run it (human)**

```bash
./Scripts/make-s5-probe-app.sh
rm -f ~/Desktop/S5-server.log
open build/S5Server.app --args serve
# Grant Screen Recording to "S5Server" when prompted, then relaunch it —
# macOS requires a relaunch after the grant is toggled.

# From a terminal, whose own identity holds no grant:
./.build/debug/S5RealTopology ask
cat ~/Desktop/S5-server.log

# Control: the same probe with the TERMINAL as responsible process. This is what
# S3 measured. It should succeed, and is only a baseline to compare against.
./.build/debug/S5RealTopology serve   # one terminal
./.build/debug/S5RealTopology ask     # another
```

- [ ] **Step 4: Write the findings document**

Create `docs/superpowers/spikes/S5-real-topology.md`:

```markdown
# S5 — Capture in the real client→IPC→app topology

**Question (spec §4.9, §13):** When a client whose parent is NOT Snitt asks
`Snitt.app` over a socket to capture, does the capture succeed using SNITT'S own
TCC grant?

**Why it matters:** Spike S3 showed a background process can capture, but both of
its runs inherited the terminal's grant. §4.9's thin-client architecture — the
whole reason the CLI does not call ScreenCaptureKit — depends on the app's grant
being what counts. If it is not, M2b needs a different design.

**Date:** <date> · **macOS:** <version> · **Status:** <Resolved | Blocked>

## Observations

| Condition | frames | nonBlack | Notes |
|---|---|---|---|
| Server = S5Server.app (own grant, launched via `open`), client from terminal | | | |
| Server run directly from the terminal (control) | | | |

## Recommendation

<Does §4.9's architecture hold? If capture fails or returns only black frames when
triggered by an unrelated client, say so plainly and state what M2b must do instead.>

## Consequences

- **Thin-client architecture (§4.9):** <validated / needs revision>
- **Socket location (§10):** <does the client need any special entitlement to connect>
- **What M2b builds next:** <unchanged / what changes>
```

- [ ] **Step 5: Commit**

```bash
git add Spikes/S5RealTopology docs/superpowers/spikes/S5-real-topology.md \
        Scripts/make-s5-probe-app.sh Package.swift
git commit -m "spike(S5): probe capture in the real client-to-app topology

S3 proved a background process can capture but inherited the terminal's grant
both times. This exercises the topology section 4.9 actually depends on: a
client with no grant of its own asking Snitt.app, which has one."
```

---

## Task 2: The wire protocol

**Files:**
- Create: `Sources/SnittAutomation/Protocol.swift`
- Create: `Sources/SnittAutomation/SocketPath.swift`
- Create: `Tests/SnittAutomationTests/ProtocolTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `TargetReference`, `StoredTargetKind` (existing)
- Produces:
  - `public enum AutomationProtocol { public static let version = 1 }`
  - `public struct AutomationRequest: Codable, Sendable` — `protocolVersion: Int`, `body: Body`
  - `public enum AutomationRequest.Body: Codable, Sendable` — `.handshake`, `.listTargets`, `.startRecording(StartOptions)`, `.stopRecording(sessionID: String)`, `.status`
  - `public struct StartOptions: Codable, Sendable` — `bundleIdentifier: String?`, `displayID: UInt32?`, `microphone: Bool`, `systemAudio: Bool`, `maxDurationSeconds: Double?`
  - `public enum AutomationResponse: Codable, Sendable` — `.handshake(HandshakeInfo)`, `.targets([TargetSummary])`, `.started(sessionID: String, target: String)`, `.stopped(bundlePath: String)`, `.status(StatusInfo)`, `.failure(AutomationError)`
  - `public struct AutomationError: Codable, Sendable, Equatable` — `code: Code`, `message: String`, `hint: String?`
  - `public enum AutomationError.Code: String, Codable, Sendable` — `consentRequired`, `upgradeRequired`, `noSuchSession`, `alreadyRecording`, `targetNotFound`, `permissionDenied`, `internalError`
  - `public struct TargetSummary: Codable, Sendable, Equatable` — `id: UInt32`, `kind: String`, `title: String?`, `applicationName: String?`, `bundleIdentifier: String?`
  - `public struct HandshakeInfo: Codable, Sendable` — `protocolVersion: Int`, `appVersion: String`
  - `public struct StatusInfo: Codable, Sendable` — `recording: Bool`, `sessionID: String?`, `elapsedSeconds: Double?`
  - `public enum SocketPath { public static func url() -> URL }`
  - `public static let exitCode: [AutomationError.Code: Int32]` on `AutomationError`

**The error codes are the CLI's contract with agents.** An agent branches on `code`, not on
prose. Adding a case later is fine; renaming one is a breaking change.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/ProtocolTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittAutomation

@Test("A request round-trips through JSON with its protocol version intact")
func requestRoundTrips() throws {
    let request = AutomationRequest(
        protocolVersion: AutomationProtocol.version,
        body: .startRecording(StartOptions(bundleIdentifier: "com.apple.Safari",
                                           displayID: nil,
                                           microphone: false,
                                           systemAudio: true,
                                           maxDurationSeconds: 300))
    )
    let data = try JSONEncoder().encode(request)
    let back = try JSONDecoder().decode(AutomationRequest.self, from: data)

    #expect(back.protocolVersion == AutomationProtocol.version)
    guard case .startRecording(let options) = back.body else {
        Issue.record("wrong body case"); return
    }
    #expect(options.bundleIdentifier == "com.apple.Safari")
    #expect(options.systemAudio == true)
    #expect(options.microphone == false)
}

@Test("Every response case round-trips")
func responsesRoundTrip() throws {
    let cases: [AutomationResponse] = [
        .handshake(HandshakeInfo(protocolVersion: 1, appVersion: "0.1.0")),
        .targets([TargetSummary(id: 7, kind: "window", title: "Docs",
                                applicationName: "Safari",
                                bundleIdentifier: "com.apple.Safari")]),
        .started(sessionID: "abc", target: "Safari"),
        .stopped(bundlePath: "/tmp/x.snitt"),
        .status(StatusInfo(recording: true, sessionID: "abc", elapsedSeconds: 4)),
        .failure(AutomationError(code: .consentRequired, message: "m", hint: "h")),
    ]
    for value in cases {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(AutomationResponse.self, from: data)
        #expect(String(describing: back).prefix(6) == String(describing: value).prefix(6))
    }
}

@Test("Error codes are stable strings — agents branch on these, not on prose")
func errorCodesAreStable() {
    #expect(AutomationError.Code.consentRequired.rawValue == "consent_required")
    #expect(AutomationError.Code.upgradeRequired.rawValue == "upgrade_required")
    #expect(AutomationError.Code.noSuchSession.rawValue == "no_such_session")
    #expect(AutomationError.Code.alreadyRecording.rawValue == "already_recording")
    #expect(AutomationError.Code.targetNotFound.rawValue == "target_not_found")
    #expect(AutomationError.Code.permissionDenied.rawValue == "permission_denied")
    #expect(AutomationError.Code.internalError.rawValue == "internal_error")
}

@Test("Every error code maps to a distinct non-zero exit code")
func exitCodesAreDistinctAndNonZero() {
    let codes = AutomationError.Code.allCases
    let exits = codes.map { AutomationError.exitCode[$0] ?? -1 }
    #expect(exits.allSatisfy { $0 > 0 }, "success is 0; every failure must differ from it")
    #expect(Set(exits).count == codes.count, "an agent must be able to tell them apart")
}

@Test("The socket lives under Application Support, not /tmp")
func socketPathIsNotWorldWritable() {
    let path = SocketPath.url().path
    #expect(path.contains("Application Support/Snitt"))
    #expect(!path.hasPrefix("/tmp"), "/tmp is world-writable; another user could squat the socket")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProtocolTests`
Expected: FAIL — `no such module 'SnittAutomation'`.

- [ ] **Step 3: Write minimal implementation**

Add to `Package.swift`:

```swift
        .library(name: "SnittAutomation", targets: ["SnittAutomation"]),
```
```swift
        .target(name: "SnittAutomation", dependencies: ["SnittCapture", "SnittDocument"]),
```
```swift
        .testTarget(name: "SnittAutomationTests", dependencies: ["SnittAutomation"]),
```

Create `Sources/SnittAutomation/SocketPath.swift`:

```swift
import Foundation

/// Where the automation socket lives.
///
/// Application Support rather than `/tmp`: `/tmp` is world-writable, so another
/// user on a shared machine could create the path first and receive an agent's
/// recording requests. Application Support is per-user and not writable by others.
public enum SocketPath {
    public static func url() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Snitt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        return base.appendingPathComponent("automation.sock")
    }
}
```

Create `Sources/SnittAutomation/Protocol.swift`:

```swift
import Foundation

public enum AutomationProtocol {
    /// Bumped whenever the wire format changes incompatibly. The server refuses
    /// mismatches rather than guessing (§10).
    public static let version = 1
}

public struct StartOptions: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    public var displayID: UInt32?
    public var microphone: Bool
    public var systemAudio: Bool
    public var maxDurationSeconds: Double?

    public init(bundleIdentifier: String? = nil,
                displayID: UInt32? = nil,
                microphone: Bool = false,
                systemAudio: Bool = true,
                maxDurationSeconds: Double? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayID = displayID
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.maxDurationSeconds = maxDurationSeconds
    }
}

public struct AutomationRequest: Codable, Sendable {
    public enum Body: Codable, Sendable {
        case handshake
        case listTargets
        case startRecording(StartOptions)
        case stopRecording(sessionID: String)
        case status
    }

    public var protocolVersion: Int
    public var body: Body

    public init(protocolVersion: Int = AutomationProtocol.version, body: Body) {
        self.protocolVersion = protocolVersion
        self.body = body
    }
}

public struct TargetSummary: Codable, Sendable, Equatable {
    public var id: UInt32
    public var kind: String
    public var title: String?
    public var applicationName: String?
    public var bundleIdentifier: String?

    public init(id: UInt32, kind: String, title: String?,
                applicationName: String?, bundleIdentifier: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct HandshakeInfo: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var appVersion: String
    public init(protocolVersion: Int, appVersion: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }
}

public struct StatusInfo: Codable, Sendable, Equatable {
    public var recording: Bool
    public var sessionID: String?
    public var elapsedSeconds: Double?
    public init(recording: Bool, sessionID: String?, elapsedSeconds: Double?) {
        self.recording = recording
        self.sessionID = sessionID
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct AutomationError: Codable, Sendable, Equatable, Error {
    /// The agent-facing contract. An agent branches on this, never on `message`.
    /// Adding a case is safe; renaming one is a breaking protocol change.
    public enum Code: String, Codable, Sendable, CaseIterable {
        case consentRequired = "consent_required"
        case upgradeRequired = "upgrade_required"
        case noSuchSession = "no_such_session"
        case alreadyRecording = "already_recording"
        case targetNotFound = "target_not_found"
        case permissionDenied = "permission_denied"
        case internalError = "internal_error"
    }

    public var code: Code
    public var message: String
    public var hint: String?

    public init(code: Code, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    /// Distinct, non-zero exit codes so a shell script can branch without parsing
    /// JSON. Success is 0.
    public static let exitCode: [Code: Int32] = [
        .consentRequired: 10,
        .upgradeRequired: 11,
        .noSuchSession: 12,
        .alreadyRecording: 13,
        .targetNotFound: 14,
        .permissionDenied: 15,
        .internalError: 16,
    ]
}

public enum AutomationResponse: Codable, Sendable {
    case handshake(HandshakeInfo)
    case targets([TargetSummary])
    case started(sessionID: String, target: String)
    case stopped(bundlePath: String)
    case status(StatusInfo)
    case failure(AutomationError)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProtocolTests`
Expected: PASS — 5 new tests, 64 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittAutomation Tests/SnittAutomationTests Package.swift
git commit -m "feat(automation): add the wire protocol and socket location

Error codes are the agent-facing contract — agents branch on the code, never
on the message — so each maps to a distinct non-zero exit code for shell
callers. The socket lives under Application Support rather than /tmp, which is
world-writable and could be squatted by another user."
```

---

## Task 3: Newline-delimited framing

**Files:**
- Create: `Sources/SnittAutomation/LineFraming.swift`
- Create: `Tests/SnittAutomationTests/LineFramingTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct LineFramer: Sendable` with `mutating func append(_ data: Data) -> [Data]`
  - `public static func frame(_ payload: Data) -> Data`
  - `public enum FramingError: Error, Equatable { case messageTooLarge(Int) }`
  - `public static let maximumMessageBytes = 1 << 20`

**Why framing needs its own type:** a stream socket delivers arbitrary chunks. One `read`
can contain half a message, or three. Getting this wrong produces bugs that only appear
under load, so it is separated out and tested directly against split and coalesced input.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/LineFramingTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittAutomation

@Test("A whole message in one chunk yields exactly one payload")
func singleWholeMessage() {
    var framer = LineFramer()
    let out = framer.append(LineFramer.frame(Data("hello".utf8)))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "hello")
}

@Test("A message split across chunks is reassembled, not dropped")
func splitMessageIsReassembled() {
    var framer = LineFramer()
    let whole = LineFramer.frame(Data("abcdef".utf8))
    let first = whole.prefix(3), second = whole.suffix(from: 3)

    #expect(framer.append(Data(first)).isEmpty, "a partial message must yield nothing yet")
    let out = framer.append(Data(second))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "abcdef")
}

@Test("Several messages coalesced into one chunk all come out, in order")
func coalescedMessagesAllEmerge() {
    var framer = LineFramer()
    var chunk = Data()
    for word in ["one", "two", "three"] { chunk.append(LineFramer.frame(Data(word.utf8))) }

    let out = framer.append(chunk)
    #expect(out.count == 3, "a single read can carry more than one message")
    #expect(out.map { String(data: $0, encoding: .utf8) } == ["one", "two", "three"])
}

@Test("An empty line is skipped rather than surfacing as an empty message")
func emptyLinesAreSkipped() {
    var framer = LineFramer()
    let out = framer.append(Data("\n\nvalue\n".utf8))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "value")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LineFramingTests`
Expected: FAIL — `cannot find 'LineFramer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittAutomation/LineFraming.swift`:

```swift
import Foundation

public enum FramingError: Error, Equatable {
    case messageTooLarge(Int)
}

/// Splits a byte stream into newline-delimited messages.
///
/// A stream socket delivers arbitrary chunks: one read can hold half a message or
/// three whole ones. This buffers partial input and emits only complete messages,
/// which is why it is a separate, directly tested type — framing bugs otherwise
/// appear only under load.
///
/// The payload is JSON, which never contains a raw newline outside a string
/// literal, and `JSONEncoder` does not emit newlines inside strings unescaped —
/// so a bare `\n` is an unambiguous terminator.
public struct LineFramer: Sendable {
    /// Refuse absurd input rather than buffering without bound.
    public static let maximumMessageBytes = 1 << 20

    private var buffer = Data()

    public init() {}

    public static func frame(_ payload: Data) -> Data {
        var out = payload
        out.append(0x0A)
        return out
    }

    /// Appends a chunk and returns every complete message it completed.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []

        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer = Data(buffer[buffer.index(after: index)...])
            if !line.isEmpty { messages.append(Data(line)) }
        }

        if buffer.count > Self.maximumMessageBytes { buffer.removeAll() }
        return messages
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LineFramingTests`
Expected: PASS — 4 new tests, 68 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittAutomation/LineFraming.swift Tests/SnittAutomationTests/LineFramingTests.swift
git commit -m "feat(automation): newline framing over the stream socket

Separated and tested directly against split and coalesced input, because
framing bugs otherwise surface only under load."
```

---

## Task 4: Consent policy

**Files:**
- Create: `Sources/SnittAutomation/ConsentPolicy.swift`
- Create: `Tests/SnittAutomationTests/ConsentPolicyTests.swift`

**Interfaces:**
- Consumes: `StartOptions`, `AutomationError`
- Produces:
  - `public struct ConsentPolicy: Sendable` with `init(agentRecordingEnabled: Bool, fullDisplayAllowed: Bool, maximumSessionSeconds: Double)`
  - `public func evaluate(_ options: StartOptions) -> AutomationError?` — nil means allowed
  - `public func effectiveMaxDuration(_ requested: Double?) -> Double`
  - `public static let defaultMaximumSessionSeconds: Double = 600`

**This is §5.3 as code, and it is the whole safety story for M2b.** The indicator and kill
switch already exist from M2a; this decides whether a request is permitted at all. It is
pure so it can be tested exhaustively without a socket, an app, or a screen.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/ConsentPolicyTests.swift`:

```swift
import Testing
@testable import SnittAutomation

private func policy(enabled: Bool = true,
                    fullDisplay: Bool = false,
                    maxSeconds: Double = 600) -> ConsentPolicy {
    ConsentPolicy(agentRecordingEnabled: enabled,
                  fullDisplayAllowed: fullDisplay,
                  maximumSessionSeconds: maxSeconds)
}

@Test("Agent recording disabled refuses every request with consent_required")
func disabledRefusesEverything() {
    let error = policy(enabled: false)
        .evaluate(StartOptions(bundleIdentifier: "com.apple.Safari"))
    #expect(error?.code == .consentRequired)
}

@Test("A window request is allowed when agent recording is enabled")
func windowRequestAllowed() {
    #expect(policy().evaluate(StartOptions(bundleIdentifier: "com.apple.Safari")) == nil)
}

@Test("A display request is refused unless full-display was granted specifically")
func displayRefusedByDefault() {
    // §5.3: an agent may not silently escalate to full-display. This is the
    // request a naive implementation would wave through, so it is tested directly.
    let error = policy(fullDisplay: false).evaluate(StartOptions(displayID: 1))
    #expect(error?.code == .consentRequired)
    #expect(error?.hint != nil, "a refusal an agent cannot act on is a dead end")
}

@Test("A display request is allowed once full-display is granted")
func displayAllowedWhenGranted() {
    #expect(policy(fullDisplay: true).evaluate(StartOptions(displayID: 1)) == nil)
}

@Test("A request naming neither a window nor a display is refused")
func targetlessRequestRefused() {
    #expect(policy().evaluate(StartOptions())?.code == .targetNotFound)
}

@Test("An over-long requested duration is capped, not honoured")
func durationIsCapped() {
    // §5.3: a hung agent must not be able to fill the disk, so the cap is a
    // ceiling rather than a default an agent can raise.
    #expect(policy(maxSeconds: 600).effectiveMaxDuration(99_999) == 600)
    #expect(policy(maxSeconds: 600).effectiveMaxDuration(30) == 30)
    #expect(policy(maxSeconds: 600).effectiveMaxDuration(nil) == 600)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConsentPolicyTests`
Expected: FAIL — `cannot find 'ConsentPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittAutomation/ConsentPolicy.swift`:

```swift
import Foundation

/// §5.3's rules for agent-initiated recording, as pure logic.
///
/// The visible indicator and the kill switch already exist in the app; this
/// decides whether a request is permitted at all. Kept free of sockets, AppKit and
/// ScreenCaptureKit so every rule can be tested exhaustively.
public struct ConsentPolicy: Sendable {
    public static let defaultMaximumSessionSeconds: Double = 600

    private let agentRecordingEnabled: Bool
    private let fullDisplayAllowed: Bool
    private let maximumSessionSeconds: Double

    public init(agentRecordingEnabled: Bool,
                fullDisplayAllowed: Bool = false,
                maximumSessionSeconds: Double = ConsentPolicy.defaultMaximumSessionSeconds) {
        self.agentRecordingEnabled = agentRecordingEnabled
        self.fullDisplayAllowed = fullDisplayAllowed
        self.maximumSessionSeconds = maximumSessionSeconds
    }

    /// Returns nil when the request may proceed, or the error to send back.
    public func evaluate(_ options: StartOptions) -> AutomationError? {
        guard agentRecordingEnabled else {
            return AutomationError(
                code: .consentRequired,
                message: "Agent recording is turned off.",
                hint: "A person must enable it in Snitt's settings. Ask them to open "
                    + "Snitt and turn on agent recording, then try again.")
        }

        if options.displayID != nil {
            guard fullDisplayAllowed else {
                return AutomationError(
                    code: .consentRequired,
                    message: "Recording a whole display is not permitted for agents.",
                    hint: "Record a window instead by passing an application bundle "
                        + "identifier, or ask a person to allow full-display agent "
                        + "recording in Snitt's settings.")
            }
            return nil
        }

        guard options.bundleIdentifier != nil else {
            return AutomationError(
                code: .targetNotFound,
                message: "No target was specified.",
                hint: "Pass --app with an application bundle identifier. "
                    + "Use `snitt targets list` to see what is available.")
        }
        return nil
    }

    /// The cap is a CEILING, not a default an agent can raise — §5.3 exists so a
    /// hung or abandoned agent cannot fill the disk.
    public func effectiveMaxDuration(_ requested: Double?) -> Double {
        guard let requested, requested > 0 else { return maximumSessionSeconds }
        return min(requested, maximumSessionSeconds)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConsentPolicyTests`
Expected: PASS — 6 new tests, 74 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittAutomation/ConsentPolicy.swift Tests/SnittAutomationTests/ConsentPolicyTests.swift
git commit -m "feat(automation): enforce section 5.3's agent consent rules

Pure logic, no socket or screen, so every rule is exhaustively testable. The
duration limit is a ceiling rather than a default an agent can raise, and a
full-display request is refused unless a person granted that specifically."
```

---

## Task 5: Session registry

**Files:**
- Create: `Sources/SnittAutomation/SessionRegistry.swift`
- Create: `Tests/SnittAutomationTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `AutomationError`
- Produces:
  - `public actor SessionRegistry`
  - `public func open(maxDuration: Double, now: Date) throws -> String` — returns a session id
  - `public func close(_ id: String) throws`
  - `public func current(now: Date) -> StatusInfo`
  - `public func expiredSession(now: Date) -> String?`
  - `public var isRecording: Bool { get }`

**Only one agent session exists at a time.** A second `open` fails with `alreadyRecording`
rather than silently replacing the first — two `AVAssetWriter`s on one screen is the exact
defect M2a's reentrancy guard was added to prevent, and the same failure is reachable here
through two agents.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/SessionRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittAutomation

@Test("A fresh registry reports not recording")
func freshRegistryIsIdle() async {
    let registry = SessionRegistry()
    let status = await registry.current(now: Date())
    #expect(status.recording == false)
    #expect(status.sessionID == nil)
}

@Test("Opening a session makes it current and reports elapsed time")
func openMakesSessionCurrent() async throws {
    let registry = SessionRegistry()
    let start = Date(timeIntervalSince1970: 1000)
    let id = try await registry.open(maxDuration: 60, now: start)

    let status = await registry.current(now: start.addingTimeInterval(5))
    #expect(status.recording == true)
    #expect(status.sessionID == id)
    #expect(status.elapsedSeconds == 5)
}

@Test("A second open is refused rather than replacing the first")
func secondOpenRefused() async throws {
    let registry = SessionRegistry()
    _ = try await registry.open(maxDuration: 60, now: Date())

    await #expect(throws: AutomationError.self) {
        _ = try await registry.open(maxDuration: 60, now: Date())
    }
}

@Test("Closing an unknown session id fails rather than succeeding quietly")
func closingUnknownSessionFails() async {
    let registry = SessionRegistry()
    await #expect(throws: AutomationError.self) {
        try await registry.close("not-a-session")
    }
}

@Test("A session past its maximum duration is reported as expired")
func expiredSessionIsReported() async throws {
    // §5.3: a hung agent must not record forever. Something has to notice.
    let registry = SessionRegistry()
    let start = Date(timeIntervalSince1970: 1000)
    let id = try await registry.open(maxDuration: 30, now: start)

    #expect(await registry.expiredSession(now: start.addingTimeInterval(29)) == nil)
    #expect(await registry.expiredSession(now: start.addingTimeInterval(31)) == id)
}

@Test("After closing, a new session can open")
func closeThenReopen() async throws {
    let registry = SessionRegistry()
    let first = try await registry.open(maxDuration: 60, now: Date())
    try await registry.close(first)
    let second = try await registry.open(maxDuration: 60, now: Date())
    #expect(second != first, "each session gets its own id")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionRegistryTests`
Expected: FAIL — `cannot find 'SessionRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittAutomation/SessionRegistry.swift`:

```swift
import Foundation

/// Tracks the one active agent session.
///
/// Deliberately single-session: a second `open` is refused rather than replacing
/// the first. Two concurrent recordings would mean two `AVAssetWriter`s on one
/// screen — the same defect the app's own transition guard prevents for hotkey
/// presses, reachable here through two agents instead.
public actor SessionRegistry {
    private struct Session {
        let id: String
        let startedAt: Date
        let maxDuration: Double
    }

    private var session: Session?

    public init() {}

    public var isRecording: Bool { session != nil }

    public func open(maxDuration: Double, now: Date) throws -> String {
        if session != nil {
            throw AutomationError(
                code: .alreadyRecording,
                message: "A recording is already in progress.",
                hint: "Stop it first with `snitt record stop`, or check `snitt status`.")
        }
        let id = UUID().uuidString
        session = Session(id: id, startedAt: now, maxDuration: maxDuration)
        return id
    }

    public func close(_ id: String) throws {
        guard let current = session, current.id == id else {
            throw AutomationError(
                code: .noSuchSession,
                message: "No recording with that session id.",
                hint: "Check `snitt status` for the current session.")
        }
        session = nil
    }

    public func current(now: Date) -> StatusInfo {
        guard let session else {
            return StatusInfo(recording: false, sessionID: nil, elapsedSeconds: nil)
        }
        return StatusInfo(recording: true,
                          sessionID: session.id,
                          elapsedSeconds: now.timeIntervalSince(session.startedAt))
    }

    /// The id of a session that has outlived its cap, if any.
    ///
    /// Reporting rather than acting: the registry does not own the `Recorder`, so
    /// the host decides what stopping means. §5.3 requires only that something
    /// notices.
    public func expiredSession(now: Date) -> String? {
        guard let session else { return nil }
        return now.timeIntervalSince(session.startedAt) > session.maxDuration
            ? session.id : nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionRegistryTests`
Expected: PASS — 6 new tests, 80 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittAutomation/SessionRegistry.swift Tests/SnittAutomationTests/SessionRegistryTests.swift
git commit -m "feat(automation): single-session registry with expiry reporting

A second open is refused rather than replacing the first — two agents would
otherwise produce two AVAssetWriters on one screen, the same defect the app's
transition guard prevents for hotkey presses."
```

---

## Task 6: Server and client over the socket

**Files:**
- Create: `Sources/SnittAutomation/AutomationServer.swift`
- Create: `Sources/SnittAutomation/AutomationClient.swift`
- Create: `Tests/SnittAutomationTests/RoundTripTests.swift`

**Interfaces:**
- Consumes: `AutomationRequest`, `AutomationResponse`, `LineFramer`, `SocketPath`
- Produces:
  - `public protocol AutomationHandling: Sendable { func handle(_ body: AutomationRequest.Body) async -> AutomationResponse }`
  - `public final class AutomationServer` with `init(socketURL: URL, handler: AutomationHandling)`, `func start() throws`, `func stop()`
  - `public struct AutomationClient: Sendable` with `init(socketURL: URL)`, `func send(_ body: AutomationRequest.Body) async throws -> AutomationResponse`
  - `public enum ClientError: Error, Equatable { case notRunning, malformedResponse }`

**The version handshake lives here (§10):** the server checks `protocolVersion` on every
request and returns `upgrade_required` on a mismatch. It never partially executes and never
guesses at a newer format — an old CLI talking to a new app must fail loudly.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/RoundTripTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittAutomation

/// Answers with a canned response and records what it was asked.
final class SpyHandler: AutomationHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [AutomationRequest.Body] = []
    var received: [AutomationRequest.Body] {
        lock.lock(); defer { lock.unlock() }; return _received
    }

    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse {
        lock.lock(); _received.append(body); lock.unlock()
        return .status(StatusInfo(recording: false, sessionID: nil, elapsedSeconds: nil))
    }
}

private func tempSocketURL() -> URL {
    // Short path: a Unix socket path is limited to ~104 bytes.
    URL(fileURLWithPath: "/tmp/snitt-test-\(UUID().uuidString.prefix(8)).sock")
}

@Test("A request reaches the handler and its response comes back")
func requestRoundTrips() async throws {
    let url = tempSocketURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let handler = SpyHandler()
    let server = AutomationServer(socketURL: url, handler: handler)
    try server.start()
    defer { server.stop() }

    let client = AutomationClient(socketURL: url)
    let response = try await client.send(.status)

    guard case .status(let info) = response else {
        Issue.record("expected a status response"); return
    }
    #expect(info.recording == false)
    #expect(handler.received.count == 1)
}

@Test("A client talking to nothing fails fast instead of hanging")
func noServerFailsFast() async {
    // An agent must never block on something it cannot see (§11).
    let client = AutomationClient(socketURL: tempSocketURL())
    await #expect(throws: ClientError.notRunning) {
        _ = try await client.send(.status)
    }
}

@Test("A protocol mismatch is refused with upgrade_required, not guessed at")
func versionMismatchIsRefused() async throws {
    let url = tempSocketURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let server = AutomationServer(socketURL: url, handler: SpyHandler())
    try server.start()
    defer { server.stop() }

    // Hand-roll a request from a "future" client.
    let request = AutomationRequest(protocolVersion: AutomationProtocol.version + 1,
                                    body: .status)
    let client = AutomationClient(socketURL: url)
    let response = try await client.sendRaw(request)

    guard case .failure(let error) = response else {
        Issue.record("a version mismatch must not be executed"); return
    }
    #expect(error.code == .upgradeRequired)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RoundTripTests`
Expected: FAIL — `cannot find 'AutomationServer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittAutomation/AutomationServer.swift`:

```swift
import Foundation
import Network

public protocol AutomationHandling: Sendable {
    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse
}

/// Listens on a Unix domain socket and dispatches one request per line.
///
/// The version check lives here rather than in each handler: §10 requires a
/// mismatch to be refused outright rather than partially executed, and putting it
/// at the boundary means no handler can forget it.
public final class AutomationServer: @unchecked Sendable {
    private let socketURL: URL
    private let handler: AutomationHandling
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.impressiver.snitt.automation")

    public init(socketURL: URL, handler: AutomationHandling) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        // A stale socket file from a crash would make bind fail.
        try? FileManager.default.removeItem(at: socketURL)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketURL.path)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, framer: LineFramer())
    }

    private func receive(on connection: NWConnection, framer: LineFramer) {
        var framer = framer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for message in framer.append(data) {
                    Task { await self.respond(to: message, on: connection) }
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, framer: framer)
            }
        }
    }

    private func respond(to message: Data, on connection: NWConnection) async {
        let response: AutomationResponse
        do {
            let request = try JSONDecoder().decode(AutomationRequest.self, from: message)
            if request.protocolVersion != AutomationProtocol.version {
                response = .failure(AutomationError(
                    code: .upgradeRequired,
                    message: "This Snitt speaks protocol \(AutomationProtocol.version); "
                           + "the client sent \(request.protocolVersion).",
                    hint: "Update whichever of the app or the CLI is older. Snitt "
                        + "refuses a mismatch rather than guessing at the format."))
            } else {
                response = await handler.handle(request.body)
            }
        } catch {
            response = .failure(AutomationError(
                code: .internalError,
                message: "Could not decode the request.",
                hint: "This usually means a protocol mismatch between the CLI and the app."))
        }

        guard let payload = try? JSONEncoder().encode(response) else { return }
        connection.send(content: LineFramer.frame(payload),
                        completion: .contentProcessed { _ in })
    }
}
```

Create `Sources/SnittAutomation/AutomationClient.swift`:

```swift
import Foundation
import Network

public enum ClientError: Error, Equatable {
    /// Nothing is listening — Snitt.app is not running.
    case notRunning
    case malformedResponse
}

/// The client half, shared by the CLI and the MCP server.
///
/// Both frontends go through this type so their behaviour cannot diverge (§4.8).
/// Neither ever touches ScreenCaptureKit: the app holds the capture grant (§4.9).
public struct AutomationClient: Sendable {
    private let socketURL: URL

    public init(socketURL: URL = SocketPath.url()) {
        self.socketURL = socketURL
    }

    public func send(_ body: AutomationRequest.Body) async throws -> AutomationResponse {
        try await sendRaw(AutomationRequest(body: body))
    }

    public func sendRaw(_ request: AutomationRequest) async throws -> AutomationResponse {
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            throw ClientError.notRunning
        }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let connection = NWConnection(
            to: .unix(path: socketURL.path), using: params)
        let queue = DispatchQueue(label: "com.impressiver.snitt.automation.client")
        connection.start(queue: queue)
        defer { connection.cancel() }

        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let box = OnceBox(continuation)

            connection.send(content: LineFramer.frame(payload),
                            completion: .contentProcessed { error in
                if let error { box.fail(ClientError.notRunning); _ = error }
            })

            var framer = LineFramer()
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                    data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        for message in framer.append(data) {
                            if let response = try? JSONDecoder()
                                .decode(AutomationResponse.self, from: message) {
                                box.succeed(response)
                                return
                            }
                            box.fail(ClientError.malformedResponse)
                            return
                        }
                    }
                    if isComplete || error != nil {
                        box.fail(ClientError.notRunning)
                    } else {
                        read()
                    }
                }
            }
            read()
        }
    }
}

/// Resumes a continuation at most once. Network callbacks can fire more than
/// once, and resuming twice traps.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AutomationResponse, Error>?

    init(_ continuation: CheckedContinuation<AutomationResponse, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: AutomationResponse) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }

    func fail(_ error: Error) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RoundTripTests`
Expected: PASS — 3 new tests, 83 total.

- [ ] **Step 5: Verify strict concurrency**

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittAutomation/AutomationServer.swift Sources/SnittAutomation/AutomationClient.swift Tests/SnittAutomationTests/RoundTripTests.swift
git commit -m "feat(automation): socket server and shared client

The version check sits at the connection boundary so no handler can forget it —
a mismatch is refused outright rather than partially executed. The client
resumes its continuation through a once-only box, because network callbacks can
fire more than once and resuming twice traps."
```

---

## Task 7: Host the server in the app

**Files:**
- Create: `Sources/SnittApp/AgentSettings.swift`
- Create: `Sources/SnittApp/AutomationHost.swift`
- Create: `Tests/SnittAppTests/AgentSettingsTests.swift`
- Modify: `Sources/SnittApp/main.swift`
- Modify: `Sources/SnittApp/StatusItemController.swift`
- Modify: `Sources/SnittCapture/CaptureTarget.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `AutomationServer`, `AutomationHandling`, `ConsentPolicy`, `SessionRegistry`, `RecordingCoordinator`, `CachedTargetResolver`, `TargetReference`
- Produces:
  - `public struct AgentSettings: Sendable` with `var agentRecordingEnabled: Bool`, `var fullDisplayAllowed: Bool`, `static func load(_ defaults: UserDefaults) -> AgentSettings`, `func save(to defaults: UserDefaults)`
  - `final class AutomationHost: AutomationHandling` with `init(coordinator: RecordingCoordinator, settings: @escaping () -> AgentSettings)`, `func start()`, `func stop()`
  - `StatusItemController.onToggleAgentRecording: ((Bool) -> Void)?`
  - `CaptureTarget.headlessAvailable() async throws -> [CaptureTarget]`

**Agent recording is off by default (§5.3),** so `AgentSettings.load` returns
`agentRecordingEnabled == false` for a `UserDefaults` that has never been written. A test
asserts exactly that, because a default that silently flips to on is the difference between
a safety rule and a comment.

**The indicator must cover agent sessions.** M2a's status item already shows recording
state; this wires agent-started recordings into the same path so §5.3's "visible for the
entire duration" holds regardless of who started it.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/AgentSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.test.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Agent recording is OFF for defaults that have never been written")
func agentRecordingDefaultsOff() {
    // §5.3 is a safety rule, not a preference — a default that silently reads as
    // enabled would make the opt-in decorative.
    let settings = AgentSettings.load(emptyDefaults())
    #expect(settings.agentRecordingEnabled == false)
    #expect(settings.fullDisplayAllowed == false)
}

@Test("Settings survive a save and reload")
func settingsRoundTrip() {
    let defaults = emptyDefaults()
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.save(to: defaults)

    #expect(AgentSettings.load(defaults).agentRecordingEnabled == true)
}

@Test("Enabling agent recording does NOT enable full-display recording")
func enablingAgentsDoesNotGrantDisplay() {
    // Two separate grants on purpose: agreeing to agent recording is not agreeing
    // to hand over the whole screen (§5.3).
    let defaults = emptyDefaults()
    var settings = AgentSettings.load(defaults)
    settings.agentRecordingEnabled = true
    settings.save(to: defaults)

    #expect(AgentSettings.load(defaults).fullDisplayAllowed == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentSettingsTests`
Expected: FAIL — `cannot find 'AgentSettings' in scope`.

- [ ] **Step 3: Write the settings type**

Create `Sources/SnittApp/AgentSettings.swift`:

```swift
import Foundation

/// The agent-recording opt-in (§5.3).
///
/// Both flags default to FALSE for defaults that have never been written. That is
/// the safety rule, not a preference: an opt-in whose default reads as enabled is
/// decorative. They are separate because agreeing that agents may record is not
/// agreeing to hand over the whole screen.
public struct AgentSettings: Sendable, Equatable {
    public var agentRecordingEnabled: Bool
    public var fullDisplayAllowed: Bool

    private static let enabledKey = "com.impressiver.snitt.agentRecordingEnabled"
    private static let displayKey = "com.impressiver.snitt.agentFullDisplayAllowed"

    public init(agentRecordingEnabled: Bool = false, fullDisplayAllowed: Bool = false) {
        self.agentRecordingEnabled = agentRecordingEnabled
        self.fullDisplayAllowed = fullDisplayAllowed
    }

    public static func load(_ defaults: UserDefaults = .standard) -> AgentSettings {
        AgentSettings(agentRecordingEnabled: defaults.bool(forKey: enabledKey),
                      fullDisplayAllowed: defaults.bool(forKey: displayKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(agentRecordingEnabled, forKey: Self.enabledKey)
        defaults.set(fullDisplayAllowed, forKey: Self.displayKey)
    }
}
```

- [ ] **Step 4: Write the host**

Create `Sources/SnittApp/AutomationHost.swift`:

```swift
import Foundation
import SnittAutomation
import SnittCapture

/// Bridges automation requests to the same recording machinery the hotkey uses.
///
/// Requests arrive off the main actor; anything touching the coordinator or the
/// status item hops to it. Agent recordings go through the SAME coordinator as
/// hotkey presses, so M2a's transition guard, visible indicator and kill switch
/// all apply to them without a second implementation (§5.3).
final class AutomationHost: AutomationHandling, @unchecked Sendable {
    private let coordinator: RecordingCoordinator
    private let settings: @Sendable () -> AgentSettings
    private let registry = SessionRegistry()
    private var server: AutomationServer?

    init(coordinator: RecordingCoordinator,
         settings: @escaping @Sendable () -> AgentSettings) {
        self.coordinator = coordinator
        self.settings = settings
    }

    func start() {
        let server = AutomationServer(socketURL: SocketPath.url(), handler: self)
        try? server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse {
        switch body {
        case .handshake:
            return .handshake(HandshakeInfo(protocolVersion: AutomationProtocol.version,
                                            appVersion: "0.1.0"))

        case .status:
            return .status(await registry.current(now: Date()))

        case .listTargets:
            return await listTargets()

        case .startRecording(let options):
            return await start(options)

        case .stopRecording(let sessionID):
            return await stop(sessionID)
        }
    }

    private func policy() -> ConsentPolicy {
        let current = settings()
        return ConsentPolicy(agentRecordingEnabled: current.agentRecordingEnabled,
                             fullDisplayAllowed: current.fullDisplayAllowed)
    }

    private func listTargets() async -> AutomationResponse {
        // Enumeration is gated too: an agent that may not record has no business
        // learning what windows are open.
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }
        do {
            let targets = try await CaptureTarget.headlessAvailable()
            return .targets(targets.map { target in
                let d = target.descriptor
                // The bundle identifier comes from the SCWindow rather than the
                // descriptor, which does not carry one. It has to be here: the
                // CLI's own `--app` flag takes a bundle id, so a listing without
                // one would advertise targets an agent cannot then record.
                var bundleID: String?
                if case .window(let window) = target {
                    bundleID = window.owningApplication?.bundleIdentifier
                }
                return TargetSummary(id: d.id, kind: d.kind, title: d.title,
                                     applicationName: d.applicationName,
                                     bundleIdentifier: bundleID)
            })
        } catch {
            return .failure(AutomationError(
                code: .permissionDenied,
                message: "Snitt could not list what is on screen.",
                hint: "This usually means Screen Recording permission is missing. "
                    + "Open Snitt and grant it, then relaunch Snitt."))
        }
    }

    private func start(_ options: StartOptions) async -> AutomationResponse {
        if let refusal = policy().evaluate(options) { return .failure(refusal) }

        let maxDuration = policy().effectiveMaxDuration(options.maxDurationSeconds)
        let sessionID: String
        do {
            sessionID = try await registry.open(maxDuration: maxDuration, now: Date())
        } catch let error as AutomationError {
            return .failure(error)
        } catch {
            return .failure(AutomationError(code: .internalError,
                                            message: "Could not open a session."))
        }

        let reference: TargetReference
        if let bundleID = options.bundleIdentifier {
            reference = .window(bundleIdentifier: bundleID, titleHint: nil)
        } else if let displayID = options.displayID {
            reference = .display(id: displayID)
        } else {
            try? await registry.close(sessionID)
            return .failure(AutomationError(code: .targetNotFound,
                                            message: "No target was specified."))
        }

        let outcome = await coordinator.startForAgent(reference: reference)
        switch outcome {
        case .started(let name, _):
            return .started(sessionID: sessionID, target: name)
        default:
            try? await registry.close(sessionID)
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not start recording that target.",
                hint: "Check `snitt targets list` — the application may not be running."))
        }
    }

    private func stop(_ sessionID: String) async -> AutomationResponse {
        do {
            try await registry.close(sessionID)
        } catch let error as AutomationError {
            return .failure(error)
        } catch {
            return .failure(AutomationError(code: .internalError,
                                            message: "Could not close the session."))
        }

        guard let outcome = await coordinator.stopIfRecording(),
              case .stopped(let url, _) = outcome else {
            return .failure(AutomationError(code: .internalError,
                                            message: "The recording did not finalize."))
        }
        return .stopped(bundlePath: url.path)
    }
}
```

- [ ] **Step 5: Add a non-deprecated headless enumeration path**

`CaptureTarget.available()` is deprecated with an explicit carve-out for "headless
callers with no human to drive a picker" — which is exactly this caller. But calling a
deprecated API emits a warning, and the zero-warnings constraint is not negotiable, so
give the carve-out its own sanctioned entry point rather than suppressing the warning.

In `Sources/SnittCapture/CaptureTarget.swift`, add alongside `available()`:

```swift
    /// Enumerates what can be recorded, for callers with no human present.
    ///
    /// This is the carve-out `available()`'s deprecation note describes, given
    /// its own name so headless callers do not have to suppress a warning aimed
    /// at interactive ones. It is still the bypass path (§5.2) and still costs
    /// the recurring re-consent prompt — that is a cost of automation, which
    /// D42 accepted deliberately. Interactive callers must keep using
    /// `PickerTargetResolver`.
    public static func headlessAvailable() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return content.displays.map { .display($0) }
             + content.windows.map { .window($0) }
    }
```

- [ ] **Step 6: Add the coordinator's agent entry point**

`RecordingCoordinator` already holds `cachedResolverFactory`, so the agent path reuses
it rather than introducing a second way to build a resolver.

In `Sources/SnittApp/RecordingCoordinator.swift`, change the signature of
`startRecording()` (currently `private func startRecording() async -> CoordinatorOutcome`)
to take an optional override:

```swift
    private func startRecording(
        forcedResolver: TargetResolver? = nil
    ) async -> CoordinatorOutcome {
```

Then, inside it, replace these three lines:

```swift
        let stored = store.load()
        let choice = Self.resolverChoice(hasCachedTarget: stored != nil)

        let resolver: TargetResolver
```

with:

```swift
        let stored = store.load()
        // An agent names its target explicitly, so there is nothing to pick and
        // nothing to cache-check — but everything downstream (permission
        // preflight, resolution, the Recorder, the indicator) stays shared.
        let choice: ResolverChoice = forcedResolver != nil
            ? .cache
            : Self.resolverChoice(hasCachedTarget: stored != nil)

        var resolver: TargetResolver
```

and immediately after the existing `switch choice { ... }` block, add:

```swift
        if let forcedResolver { resolver = forcedResolver }
```

Leaving the switch itself untouched keeps the hotkey path's behaviour byte-for-byte
unchanged; the override is applied after it rather than woven into it.

Finally add the public entry point next to `toggle()`:

```swift
    /// Starts a recording on behalf of an agent, against an explicit target.
    ///
    /// Deliberately shares `startRecording()` and the same `isTransitioning`
    /// guard as the hotkey path: an agent request arriving mid-hotkey-press must
    /// not start a second recording, and the visible indicator and kill switch
    /// then apply to agent sessions for free (§5.3).
    public func startForAgent(reference: TargetReference) async -> CoordinatorOutcome {
        guard !isTransitioning else { return .ignored }
        isTransitioning = true
        defer { isTransitioning = false }
        guard active == nil else {
            return .failed("A recording is already in progress.")
        }
        return await startRecording(forcedResolver: cachedResolverFactory(reference))
    }
```

Note `startForAgent` takes only the reference. `StartOptions` carries audio flags that
M2b does not yet plumb into `Recorder` — the coordinator builds a `Recorder` with its
default `CaptureOptions`, and threading the agent's audio choices through is M3 work.
Passing an unused parameter now would advertise a capability that does not exist.

- [ ] **Step 7: Wire it into the app and add the settings toggle**

In `Sources/SnittApp/StatusItemController.swift`, extend `showContextMenu()`'s menu
construction, before the Quit item:

```swift
        let agentItem = NSMenuItem(title: "Allow agent recording",
                                   action: #selector(toggleAgentRecording),
                                   keyEquivalent: "")
        agentItem.target = self
        agentItem.state = agentRecordingEnabled ? .on : .off
        menu.addItem(agentItem)
        menu.addItem(.separator())
```

and add to the class:

```swift
    /// Mirrors the persisted setting so the menu can show a checkmark.
    var agentRecordingEnabled = false

    /// Invoked when the user toggles agent recording from the menu.
    var onToggleAgentRecording: ((Bool) -> Void)?

    @objc private func toggleAgentRecording() {
        onToggleAgentRecording?(!agentRecordingEnabled)
    }
```

In `Sources/SnittApp/main.swift`'s `applicationDidFinishLaunching`, after the coordinator
is constructed:

```swift
        var agentSettings = AgentSettings.load()
        statusItem.agentRecordingEnabled = agentSettings.agentRecordingEnabled
        statusItem.onToggleAgentRecording = { [weak self] enabled in
            agentSettings.agentRecordingEnabled = enabled
            agentSettings.save()
            self?.statusItem.agentRecordingEnabled = enabled
        }

        let host = AutomationHost(coordinator: coordinator,
                                  settings: { AgentSettings.load() })
        host.start()
        automationHost = host
```

and add the stored property `private var automationHost: AutomationHost?` to `AppDelegate`.

Add `"SnittAutomation"` to the `SnittApp` target's dependencies in `Package.swift`.

- [ ] **Step 8: Run the suite**

Run: `swift test`
Expected: PASS — 86 tests, 0 failures.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero warnings.

- [ ] **Step 9: Commit**

```bash
git add Sources/SnittApp Sources/SnittCapture/CaptureTarget.swift \
        Tests/SnittAppTests/AgentSettingsTests.swift Package.swift
git commit -m "feat(app): host the automation server, behind an opt-in

Agent recording defaults OFF and is a separate grant from full-display, so
agreeing that agents may record is not agreeing to hand over the whole screen.

Agent recordings go through the SAME coordinator as hotkey presses, so the
transition guard, the visible indicator and the kill switch apply to them
without a second implementation."
```

---

## Task 8: The `snitt` CLI

**Files:**
- Create: `Sources/snitt-cli/main.swift`
- Create: `Sources/snitt-cli/CommandLineParser.swift`
- Create: `Tests/SnittAutomationTests/CommandLineParserTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `AutomationClient`, `AutomationRequest.Body`, `StartOptions`, `AutomationError`
- Produces:
  - `public enum ParsedCommand: Equatable` — `.targetsList`, `.recordStart(StartOptions)`, `.recordStop(String)`, `.status`, `.help`
  - `public static func parse(_ arguments: [String]) -> Result<ParsedCommand, String>`
  - Executable target `snitt-cli` producing a binary named `snitt`

**The output contract is the deliverable (§4.8):** structured JSON on stdout, human text on
stderr, distinct non-zero exit codes. An agent parses stdout; a person reads stderr; a shell
script branches on `$?`. The parser is pure so all of it is testable without a socket.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/CommandLineParserTests.swift`:

```swift
import Testing
@testable import SnittAutomation

@Test("targets list parses")
func parsesTargetsList() {
    #expect(CommandLineParser.parse(["targets", "list"]) == .success(.targetsList))
}

@Test("record start parses its target and audio flags")
func parsesRecordStart() {
    let parsed = CommandLineParser.parse(
        ["record", "start", "--app", "com.apple.Safari", "--mic", "--max-duration", "30"])
    guard case .success(.recordStart(let options)) = parsed else {
        Issue.record("expected recordStart, got \(parsed)"); return
    }
    #expect(options.bundleIdentifier == "com.apple.Safari")
    #expect(options.microphone == true)
    #expect(options.maxDurationSeconds == 30)
}

@Test("Microphone is OFF unless asked for")
func micDefaultsOff() {
    guard case .success(.recordStart(let options)) =
        CommandLineParser.parse(["record", "start", "--app", "com.apple.Safari"]) else {
        Issue.record("parse failed"); return
    }
    #expect(options.microphone == false,
            "an agent recording a demo should not capture the room by default")
}

@Test("record stop requires a session id")
func recordStopNeedsSession() {
    #expect(CommandLineParser.parse(["record", "stop"]).isFailure)
    #expect(CommandLineParser.parse(["record", "stop", "abc"]) == .success(.recordStop("abc")))
}

@Test("An unknown command fails with a message rather than defaulting to something")
func unknownCommandFails() {
    let parsed = CommandLineParser.parse(["frobnicate"])
    guard case .failure(let message) = parsed else {
        Issue.record("an unknown command must not silently succeed"); return
    }
    #expect(message.contains("frobnicate"))
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandLineParserTests`
Expected: FAIL — `cannot find 'CommandLineParser' in scope`.

- [ ] **Step 3: Write the parser**

Create `Sources/SnittAutomation/CommandLineParser.swift` (in the library, so it is testable
without the executable):

```swift
import Foundation

public enum ParsedCommand: Equatable {
    case targetsList
    case recordStart(StartOptions)
    case recordStop(String)
    case status
    case help
}

/// Parses the CLI's arguments. Pure, so the whole surface is testable without a
/// socket or a running app.
public enum CommandLineParser {
    public static func parse(_ arguments: [String]) -> Result<ParsedCommand, String> {
        var args = arguments
        guard let first = args.first else { return .success(.help) }
        args.removeFirst()

        switch first {
        case "help", "--help", "-h":
            return .success(.help)

        case "status":
            return .success(.status)

        case "targets":
            guard args.first == "list" else {
                return .failure("Unknown targets subcommand. Try `snitt targets list`.")
            }
            return .success(.targetsList)

        case "record":
            guard let sub = args.first else {
                return .failure("Expected `record start` or `record stop`.")
            }
            args.removeFirst()
            switch sub {
            case "start": return parseStart(args)
            case "stop":
                guard let session = args.first else {
                    return .failure("`record stop` needs a session id. "
                                  + "Run `snitt status` to find it.")
                }
                return .success(.recordStop(session))
            default:
                return .failure("Unknown record subcommand: \(sub)")
            }

        default:
            return .failure("Unknown command: \(first). Try `snitt help`.")
        }
    }

    private static func parseStart(_ args: [String]) -> Result<ParsedCommand, String> {
        var options = StartOptions()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--app":
                index += 1
                guard index < args.count else { return .failure("--app needs a bundle id") }
                options.bundleIdentifier = args[index]
            case "--display":
                index += 1
                guard index < args.count, let id = UInt32(args[index]) else {
                    return .failure("--display needs a numeric display id")
                }
                options.displayID = id
            case "--mic":
                options.microphone = true
            case "--no-system-audio":
                options.systemAudio = false
            case "--max-duration":
                index += 1
                guard index < args.count, let seconds = Double(args[index]) else {
                    return .failure("--max-duration needs a number of seconds")
                }
                options.maxDurationSeconds = seconds
            default:
                return .failure("Unknown option: \(args[index])")
            }
            index += 1
        }
        return .success(.recordStart(options))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CommandLineParserTests`
Expected: PASS — 5 new tests, 91 total.

- [ ] **Step 5: Write the executable**

Create `Sources/snitt-cli/main.swift`:

```swift
// The `snitt` CLI: one request, one JSON document on stdout, one exit code.
//
// Deliberately thin. It never touches ScreenCaptureKit — macOS attributes a
// capture grant to the responsible process, so a CLI that captured directly
// would attribute the prompt to whatever launched it and re-prompt for every
// new parent (spec §4.9). Snitt.app holds the grant; this asks it to act.
import Foundation
import SnittAutomation

func emit(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let helpText = """
snitt — record a window and hand back a .snitt bundle

  snitt targets list                     what can be recorded, as JSON
  snitt record start --app <bundle-id>   start; prints a session id
        [--display <id>] [--max-duration <seconds>]
        [--mic] [--no-system-audio]        parsed, not yet applied (M3)
  snitt record stop <session-id>         stop; prints the bundle path
  snitt status                           whether a recording is running

Output is JSON on stdout and human text on stderr, so a script can parse one
and a person can read the other. Exit codes are distinct per failure.
"""

let parsed = CommandLineParser.parse(Array(CommandLine.arguments.dropFirst()))

let command: ParsedCommand
switch parsed {
case .success(let value): command = value
case .failure(let message):
    note(message)
    exit(2)
}

if case .help = command {
    note(helpText)
    exit(0)
}

let body: AutomationRequest.Body
switch command {
case .targetsList:              body = .listTargets
case .recordStart(let options): body = .startRecording(options)
case .recordStop(let session):  body = .stopRecording(sessionID: session)
case .status:                   body = .status
case .help:                     body = .status  // unreachable; handled above
}

do {
    let response = try await AutomationClient().send(body)
    switch response {
    case .failure(let error):
        emit(error)
        note("\(error.message)" + (error.hint.map { "\n\($0)" } ?? ""))
        exit(AutomationError.exitCode[error.code] ?? 1)
    case .targets(let targets):        emit(targets)
    case .started(let id, let target):
        emit(["sessionId": id, "target": target])
        note("Recording \(target). Stop with: snitt record stop \(id)")
    case .stopped(let path):
        emit(["bundlePath": path])
        note("Saved \(path)")
    case .status(let info):            emit(info)
    case .handshake(let info):         emit(info)
    }
} catch ClientError.notRunning {
    note("Snitt is not running. Open Snitt and try again.")
    exit(3)
} catch {
    note("Could not talk to Snitt: \(error)")
    exit(1)
}
```

Add to `Package.swift`:

```swift
        .executableTarget(name: "snitt-cli",
                          dependencies: ["SnittAutomation"],
                          path: "Sources/snitt-cli"),
```

- [ ] **Step 6: Verify the CLI end to end**

Run:

```bash
swift build --product snitt-cli
./.build/debug/snitt-cli help
./.build/debug/snitt-cli status ; echo "exit=$?"
```

Expected: help text on stderr, exit 0. With Snitt not running, `status` prints
"Snitt is not running" and exits 3.

Then launch the app and repeat:

```bash
./Scripts/make-app.sh && open build/Snitt.app
./.build/debug/snitt-cli status ; echo "exit=$?"
./.build/debug/snitt-cli targets list ; echo "exit=$?"
```

With agent recording still OFF, `targets list` must print a `consent_required` error and
exit **10**. Enable it from the menu-bar item's right-click menu, then run it again and
confirm JSON targets and exit 0. That progression is the §5.3 opt-in working.

- [ ] **Step 7: Commit**

```bash
git add Sources/snitt-cli Sources/SnittAutomation/CommandLineParser.swift Tests/SnittAutomationTests/CommandLineParserTests.swift Package.swift
git commit -m "feat(cli): add the snitt command

JSON on stdout, human text on stderr, distinct exit codes per failure — an
agent parses one stream, a person reads the other, a script branches on the
code. The parser lives in the library so its whole surface is testable without
a socket."
```

---

## Task 9: The MCP server

**Files:**
- Create: `Sources/snitt-mcp/main.swift`
- Create: `Sources/SnittAutomation/MCPBridge.swift`
- Create: `Tests/SnittAutomationTests/MCPBridgeTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `AutomationClient`, `AutomationRequest.Body`, `StartOptions`
- Produces:
  - `public enum MCPBridge` with `static func toolDefinitions() -> [ToolDefinition]`, `static func request(forTool name: String, arguments: [String: Any]) -> Result<AutomationRequest.Body, String>`
  - `public struct ToolDefinition: Encodable, Sendable` — `name: String`, `description: String`, `inputSchema: [String: Any]` encoded as JSON
  - Executable target `snitt-mcp`

**The MCP server maps tools onto the SAME request bodies the CLI builds (§4.8).** It adds no
capability of its own — if a behaviour differs between the two frontends, it is a bug by
construction rather than a design choice.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/MCPBridgeTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittAutomation

@Test("Every advertised tool maps to a request — none is decorative")
func everyToolMaps() {
    for tool in MCPBridge.toolDefinitions() {
        let args: [String: Any] = tool.name == "snitt_start_recording"
            ? ["bundleIdentifier": "com.apple.Safari"]
            : (tool.name == "snitt_stop_recording" ? ["sessionId": "abc"] : [:])
        let mapped = MCPBridge.request(forTool: tool.name, arguments: args)
        guard case .success = mapped else {
            Issue.record("advertised tool \(tool.name) does not map to a request"); return
        }
    }
}

@Test("Tool names are the agent-facing contract and must not drift")
func toolNamesAreStable() {
    let names = Set(MCPBridge.toolDefinitions().map(\.name))
    #expect(names == ["snitt_list_targets", "snitt_start_recording",
                      "snitt_stop_recording", "snitt_status"])
}

@Test("Starting a recording without a target is refused before it reaches the app")
func startNeedsATarget() {
    let mapped = MCPBridge.request(forTool: "snitt_start_recording", arguments: [:])
    guard case .failure(let message) = mapped else {
        Issue.record("a targetless start must not be sent"); return
    }
    #expect(message.contains("bundleIdentifier"))
}

@Test("An unknown tool is refused rather than silently ignored")
func unknownToolRefused() {
    guard case .failure = MCPBridge.request(forTool: "snitt_do_magic", arguments: [:]) else {
        Issue.record("unknown tools must fail"); return
    }
}

@Test("The MCP microphone default matches the CLI's — off")
func micDefaultMatchesCLI() {
    guard case .success(.startRecording(let options)) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: ["bundleIdentifier": "com.apple.Safari"]) else {
        Issue.record("mapping failed"); return
    }
    // §4.8: the two frontends must not diverge. This is the cheapest place for
    // them to drift, so it is asserted directly.
    #expect(options.microphone == false)
    #expect(options.systemAudio == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MCPBridgeTests`
Expected: FAIL — `cannot find 'MCPBridge' in scope`.

- [ ] **Step 3: Write the bridge**

Create `Sources/SnittAutomation/MCPBridge.swift`:

```swift
import Foundation

public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the tool's arguments, as a JSON string so it can be
    /// embedded verbatim in the MCP response.
    public let inputSchemaJSON: String
}

/// Maps MCP tool calls onto the same request bodies the CLI builds.
///
/// The bridge adds no capability of its own. §4.8 requires the two frontends to
/// be incapable of diverging, so both construct `AutomationRequest.Body` values
/// and both travel through `AutomationClient`.
public enum MCPBridge {
    public static func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "snitt_list_targets",
                description: "List windows and displays that can be recorded.",
                inputSchemaJSON: #"{"type":"object","properties":{}}"#),
            ToolDefinition(
                name: "snitt_start_recording",
                description: "Start recording a window belonging to an application. "
                           + "Returns a session id used to stop it.",
                inputSchemaJSON: #"""
                {"type":"object",
                 "properties":{
                   "bundleIdentifier":{"type":"string",
                     "description":"Bundle id of the app whose window to record"},
                   "microphone":{"type":"boolean","default":false},
                   "systemAudio":{"type":"boolean","default":true},
                   "maxDurationSeconds":{"type":"number"}},
                 "required":["bundleIdentifier"]}
                """#),
            ToolDefinition(
                name: "snitt_stop_recording",
                description: "Stop a recording and return the path to its .snitt bundle.",
                inputSchemaJSON: #"""
                {"type":"object",
                 "properties":{"sessionId":{"type":"string"}},
                 "required":["sessionId"]}
                """#),
            ToolDefinition(
                name: "snitt_status",
                description: "Report whether a recording is currently running.",
                inputSchemaJSON: #"{"type":"object","properties":{}}"#),
        ]
    }

    public static func request(forTool name: String,
                               arguments: [String: Any]) -> Result<AutomationRequest.Body, String> {
        switch name {
        case "snitt_list_targets":
            return .success(.listTargets)

        case "snitt_status":
            return .success(.status)

        case "snitt_start_recording":
            guard let bundleID = arguments["bundleIdentifier"] as? String else {
                return .failure("snitt_start_recording requires bundleIdentifier")
            }
            var options = StartOptions(bundleIdentifier: bundleID)
            if let mic = arguments["microphone"] as? Bool { options.microphone = mic }
            if let sys = arguments["systemAudio"] as? Bool { options.systemAudio = sys }
            if let max = arguments["maxDurationSeconds"] as? Double {
                options.maxDurationSeconds = max
            }
            return .success(.startRecording(options))

        case "snitt_stop_recording":
            guard let session = arguments["sessionId"] as? String else {
                return .failure("snitt_stop_recording requires sessionId")
            }
            return .success(.stopRecording(sessionID: session))

        default:
            return .failure("Unknown tool: \(name)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MCPBridgeTests`
Expected: PASS — 5 new tests, 96 total.

- [ ] **Step 5: Write the stdio server**

Create `Sources/snitt-mcp/main.swift`:

```swift
// snitt-mcp — an MCP server over stdio.
//
// JSON-RPC 2.0, one message per line. Every tool maps to the same request the
// CLI builds and travels through the same client, so the two frontends cannot
// diverge (spec §4.8).
import Foundation
import SnittAutomation

func respond(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func result(id: Any?, _ payload: [String: Any]) {
    respond(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": payload])
}

func failure(id: Any?, _ message: String) {
    respond(["jsonrpc": "2.0", "id": id ?? NSNull(),
             "error": ["code": -32000, "message": message]])
}

func textContent(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]]]
}

/// Renders a response as the text an agent reads back.
func describe(_ response: AutomationResponse) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch response {
    case .targets(let targets):
        return (try? encoder.encode(targets)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
    case .started(let id, let target):
        return "Recording \(target). Session id: \(id)"
    case .stopped(let path):
        return "Saved \(path)"
    case .status(let info):
        return (try? encoder.encode(info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    case .handshake(let info):
        return "Snitt \(info.appVersion), protocol \(info.protocolVersion)"
    case .failure(let error):
        return "\(error.code.rawValue): \(error.message)" + (error.hint.map { "\n\($0)" } ?? "")
    }
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    let id = message["id"]
    switch message["method"] as? String {
    case "initialize":
        result(id: id, [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "snitt", "version": "0.1.0"],
        ])

    case "tools/list":
        let tools: [[String: Any]] = MCPBridge.toolDefinitions().map { tool in
            let schema = (try? JSONSerialization.jsonObject(
                with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any] ?? [:]
            return ["name": tool.name,
                    "description": tool.description,
                    "inputSchema": schema]
        }
        result(id: id, ["tools": tools])

    case "tools/call":
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch MCPBridge.request(forTool: name, arguments: arguments) {
        case .failure(let problem):
            failure(id: id, problem)
        case .success(let body):
            do {
                let response = try await AutomationClient().send(body)
                result(id: id, textContent(describe(response)))
            } catch ClientError.notRunning {
                // Fail immediately rather than blocking: an agent cannot see or
                // answer a dialog, and a hung call is worse than a clean error (§11).
                result(id: id, textContent(
                    "Snitt is not running. Ask the person at the machine to open it."))
            } catch {
                result(id: id, textContent("Could not talk to Snitt: \(error)"))
            }
        }

    default:
        if id != nil { failure(id: id, "Unsupported method") }
    }
}
```

Add to `Package.swift`:

```swift
        .executableTarget(name: "snitt-mcp",
                          dependencies: ["SnittAutomation"],
                          path: "Sources/snitt-mcp"),
```

- [ ] **Step 6: Verify the MCP server answers**

Run:

```bash
swift build --product snitt-mcp
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | ./.build/debug/snitt-mcp
```

Expected: two JSON-RPC responses, the second listing exactly the four tools.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: PASS — 96 tests, 0 failures.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero warnings.

- [ ] **Step 8: Commit**

```bash
git add Sources/snitt-mcp Sources/SnittAutomation/MCPBridge.swift Tests/SnittAutomationTests/MCPBridgeTests.swift Package.swift
git commit -m "feat(mcp): add the MCP server over stdio

Tools map onto the same request bodies the CLI builds and travel through the
same client, so the two frontends cannot diverge. A test asserts the microphone
default matches the CLI's, since that is the cheapest place for them to drift."
```

---

## Definition of done for M2b

- [ ] `swift test` passes — 96 tests, 0 failures
- [ ] `swift build -Xswiftc -strict-concurrency=complete` emits zero warnings
- [ ] `docs/superpowers/spikes/S5-real-topology.md` states whether §4.9's architecture holds
- [ ] With Snitt **not** running, `snitt status` prints a human message and exits **3**
- [ ] With Snitt running and agent recording **off**, `snitt targets list` returns
      `consent_required` and exits **10**
- [ ] After enabling agent recording from the menu, `snitt targets list` returns JSON, exit 0
- [ ] **`snitt record start --app <id>` then `snitt record stop <session>` produces a
      `.snitt` bundle whose `capture.mov` plays** — the end-to-end agent path
- [ ] While an agent recording runs, the menu-bar indicator shows it, and **clicking the
      menu-bar item stops it** — §5.3's kill switch covers agent sessions
- [ ] `snitt-mcp` answers `tools/list` with exactly four tools
- [ ] A second `record start` while one is running returns `already_recording`, exit 13

## What this plan deliberately does not build

Event logging, markers, `--auto-trim`, auto-focus and progressive permission onboarding are
**M3**, along with `--max-size`, `snitt inspect`, export manifests, capture health and git
context. The EDL and timeline are **M4**. Packaging is **M5**.

**Three things to watch, recorded rather than assumed:**

1. **Spike S5 gates the rest.** If capture fails in the real topology, Tasks 2–9 are built
   on a design that does not work. Run it first and read the result before continuing.
2. **The audio flags are parsed but not applied.** `--mic` and `--no-system-audio`
   reach `StartOptions` and are tested there, but `startForAgent` hands the coordinator
   only a target — the `Recorder` still uses its default `CaptureOptions`. Plumbing them
   through is M3. The CLI help and this list say so rather than letting an agent believe
   `--mic` did something.
3. **`snitt` is not on `PATH`.** This plan builds `.build/debug/snitt-cli`; installing it as
   `snitt` somewhere an agent will find it is packaging work (M5). Until then every
   invocation is by full path, and the Definition of Done above reflects that.
