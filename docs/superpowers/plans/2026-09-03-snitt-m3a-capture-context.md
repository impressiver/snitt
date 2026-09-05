# Snitt M3a: Capture Context — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a `.snitt` bundle explain itself — markers, capture health, and git
provenance — and make the recording watchable by focusing the target before capture starts.

**Architecture:** Every field this milestone fills already exists in `SnittDocument` and is
`nil` in every bundle Snitt writes today. M3a populates them at the moments they are
knowable: git context from the CLI's working directory at request time, health metrics
sampled during the existing `AVAssetWriter` pass, markers appended live over the automation
socket or a second hotkey.

**Tech Stack:** Swift 6, SPM, ScreenCaptureKit, AVFoundation, AppKit, Carbon (hotkeys).

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md`

**Scope:** M3a is the half of §13's M3 that costs **no new permission**. Event logging
(Input Monitoring — the third dialog), `--auto-trim`, WebVTT chapters, `--max-size`, and
`snitt inspect` + export manifest are **M3b** and are not built here. `--auto-trim-gaps`
remains unscheduled.

**Branch:** `feat/m3a-capture-context`, stacked on `feat/m2b-automation` (PR #2, unmerged).

## Global Constraints

Copied from the spec. Every task's requirements implicitly include these.

- **No new TCC permission.** §4.10's ladder is: 1 dialog to record screen + system audio,
  2 with voiceover, 3 with keystroke capture. M3a must not add a dialog. In particular
  **auto-focus must not require Accessibility** — see Task 5.
- **Nothing is requested at launch.** Each permission is requested at first use of the
  feature needing it. (§4.10)
- **Pre-explain before prompting.** Snitt shows its own sheet — what it needs, why, and
  that macOS will ask next — *before* triggering the system dialog. (§4.10)
- **Health metrics are warnings, never failures.** A legitimately static UI demo will trip
  low frame variance, so no threshold may gate anything until tuned against real
  recordings. (§12.1)
- **Sampling happens during the existing `AVAssetWriter` pass; there is no second decode.**
  (§12.1)
- **Events are data, never drawn into the video.** (§4.5)
- **Focus happens before capture starts**, so the activation transition is not in the
  recording, and **it must be skippable**. (§4.13)
- **The CLI must never call ScreenCaptureKit.** The app holds the single grant. A
  conformance test enforces this. (§4.9)
- Swift 6 language mode, strict concurrency, **zero source warnings**. macOS 15 minimum.
- 136 tests pass at the branch point. Every task keeps them passing.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SnittDocument/GitContextResolver.swift` | Discover branch/commit for a directory |
| `Sources/SnittCapture/HealthSampler.swift` | Frame variance + audio RMS, sampled in-pass |
| `Sources/SnittCapture/BundleNaming.swift` | Turn git context into a bundle filename |
| `Sources/SnittAutomation/Protocol.swift` | +`workingDirectory`, +`.mark`, version → 2 |
| `Sources/SnittApp/WindowFocuser.swift` | Activate the target's application |
| `Sources/SnittApp/PermissionOnboarding.swift` | Pre-explain sheet + already-denied deep link |
| `Sources/SnittApp/HotkeyMonitor.swift` | Route by `EventHotKeyID` so two hotkeys coexist |

**Why git context resolution lives in `SnittDocument`:** `GitContext` is already declared
there, and the resolver produces exactly that type. It shells out to `git`, so it must not
sit in `SnittCapture` where the access-conformance guard scans for capture APIs.

---

## Task 1: Git context discovery

**Files:**
- Create: `Sources/SnittDocument/GitContextResolver.swift`
- Create: `Tests/SnittDocumentTests/GitContextResolverTests.swift`

**Interfaces:**
- Consumes: `GitContext` (existing: `branch: String?`, `commit: String?`)
- Produces:
  - `public enum GitContextResolver`
  - `public static func resolve(in directory: URL, runner: CommandRunner = .git) -> GitContext?`
  - `public struct CommandRunner: Sendable` with `init(run: @Sendable @escaping (String, [String], URL) -> String?)` and `public static let git: CommandRunner`

**Why a `CommandRunner` seam:** the resolver's whole job is shelling out, so without an
injection point every test needs a real repository on disk. The seam keeps the parsing
logic — which is where the bugs are — testable with fixed strings.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittDocumentTests/GitContextResolverTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittDocument

private func runner(_ replies: [String: String?]) -> CommandRunner {
    CommandRunner { _, args, _ in replies[args.joined(separator: " ")] ?? nil }
}

@Test("A repository yields its branch and short commit")
func resolvesBranchAndCommit() {
    let git = runner([
        "rev-parse --abbrev-ref HEAD": "feature/markers",
        "rev-parse --short HEAD": "a1b2c3d",
    ])
    let context = GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"), runner: git)
    #expect(context?.branch == "feature/markers")
    #expect(context?.commit == "a1b2c3d")
}

@Test("A directory outside any repository yields nil, not an empty context")
func nonRepositoryYieldsNil() {
    // nil and GitContext(branch: nil, commit: nil) mean different things in
    // meta.json: absent versus "we looked and found nothing". Absent is correct.
    #expect(GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"),
                                       runner: runner([:])) == nil)
}

@Test("Detached HEAD reports the commit and no branch")
func detachedHeadHasNoBranch() {
    // `rev-parse --abbrev-ref HEAD` prints the literal "HEAD" when detached.
    // Recording that as a branch named HEAD would be a lie in every bundle
    // made during a bisect or a CI checkout.
    let git = runner([
        "rev-parse --abbrev-ref HEAD": "HEAD",
        "rev-parse --short HEAD": "deadbee",
    ])
    let context = GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"), runner: git)
    #expect(context?.branch == nil)
    #expect(context?.commit == "deadbee")
}

@Test("Output is trimmed of the trailing newline git always emits")
func trimsTrailingNewline() {
    let git = runner([
        "rev-parse --abbrev-ref HEAD": "main\n",
        "rev-parse --short HEAD": "a1b2c3d\n",
    ])
    #expect(GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"),
                                       runner: git)?.branch == "main")
}

@Test("A commit with no branch still produces a context")
func commitAloneIsEnough() {
    let git = runner(["rev-parse --short HEAD": "a1b2c3d"])
    #expect(GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"),
                                       runner: git)?.commit == "a1b2c3d")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GitContextResolverTests`
Expected: FAIL — `cannot find 'GitContextResolver' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittDocument/GitContextResolver.swift`:

```swift
import Foundation

/// Runs a command and returns its trimmed stdout, or nil if it failed.
///
/// Injected rather than called directly so the parsing — which is where the
/// interesting cases live — can be tested without a repository on disk.
public struct CommandRunner: Sendable {
    private let run: @Sendable (String, [String], URL) -> String?

    public init(run: @Sendable @escaping (String, [String], URL) -> String?) {
        self.run = run
    }

    public func callAsFunction(_ tool: String, _ arguments: [String],
                               in directory: URL) -> String? {
        run(tool, arguments, directory)
    }

    public static let git = CommandRunner { tool, arguments, directory in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Discovers the git branch and commit a recording was made against (§7).
public enum GitContextResolver {
    public static func resolve(in directory: URL,
                               runner: CommandRunner = .git) -> GitContext? {
        func value(_ arguments: [String]) -> String? {
            guard let raw = runner("git", arguments, in: directory) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let rawBranch = value(["rev-parse", "--abbrev-ref", "HEAD"])
        // git prints the literal "HEAD" when detached. Recording that as a
        // branch name would put a lie in every bundle made during a bisect or
        // a CI checkout, so it is dropped rather than stored.
        let branch = rawBranch == "HEAD" ? nil : rawBranch
        let commit = value(["rev-parse", "--short", "HEAD"])

        guard branch != nil || commit != nil else { return nil }
        return GitContext(branch: branch, commit: commit)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GitContextResolverTests`
Expected: PASS — 5 new tests, 141 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittDocument/GitContextResolver.swift Tests/SnittDocumentTests/GitContextResolverTests.swift
git commit -m "feat(document): discover git context for a directory

Detached HEAD reports no branch rather than a branch literally named HEAD,
which would otherwise put a lie in every bundle made during a bisect. The
command runner is injected so the parsing is testable without a repo on disk."
```

---

## Task 2: Protocol v2 — working directory and markers

**Files:**
- Modify: `Sources/SnittAutomation/Protocol.swift`
- Modify: `Tests/SnittAutomationTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: `AutomationProtocol.version`, `StartOptions`, `AutomationRequest.Body`
- Produces:
  - `StartOptions.workingDirectory: String?` (new stored property, defaulted `nil`)
  - `AutomationRequest.Body.mark(sessionID: String, label: String?)` (new case)
  - `AutomationResponse.marked(timeSeconds: Double)` (new case)
  - `AutomationProtocol.version == 2`

**Two rulings this task encodes.**

**The version goes to 2.** Adding `.mark` is not backward compatible in the way an optional
field is: a new CLI sending `mark` to an old app produces a decode failure reported as
`internal_error`. §10 requires a mismatch to be *refused outright rather than partially
executed*, and `upgrade_required` says exactly what to do while `internal_error` does not.
Bumping costs old-CLI-to-new-app compatibility, which is the correct trade for a
two-executable product shipped as one bundle.

**Git context travels from the client, not the app.** `Snitt.app`'s working directory is
`/`; it has no idea which repository a recording is *about*. The CLI does — it runs in the
agent's checkout. So `workingDirectory` is filled by the client and resolved by the app.
**Hotkey recordings therefore get no git context**, and that is correct rather than a gap:
there is no repository associated with pressing a key.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SnittAutomationTests/ProtocolTests.swift`:

```swift
@Test("The protocol version is 2 — .mark is not backward compatible")
func protocolVersionIsTwo() {
    // An old app receiving `.mark` fails to decode and reports internal_error.
    // §10 requires a mismatch to be refused outright with a usable message, so
    // the version moves and the handshake produces upgrade_required instead.
    #expect(AutomationProtocol.version == 2)
}

@Test("StartOptions carries the client's working directory")
func startOptionsCarryWorkingDirectory() throws {
    // Snitt.app's own cwd is "/" — only the client knows which repository a
    // recording is about (§7).
    var options = StartOptions(bundleIdentifier: "com.apple.Safari")
    options.workingDirectory = "/Users/x/project"
    let back = try JSONDecoder().decode(
        StartOptions.self, from: JSONEncoder().encode(options))
    #expect(back.workingDirectory == "/Users/x/project")
}

@Test("StartOptions still decodes when workingDirectory is absent")
func workingDirectoryIsOptional() throws {
    let json = Data(#"{"microphone":false,"systemAudio":true}"#.utf8)
    let options = try JSONDecoder().decode(StartOptions.self, from: json)
    #expect(options.workingDirectory == nil)
}

@Test("A mark request round-trips with its session and label")
func markRoundTrips() throws {
    let request = AutomationRequest(body: .mark(sessionID: "abc", label: "ran tests"))
    let back = try JSONDecoder().decode(
        AutomationRequest.self, from: JSONEncoder().encode(request))
    guard case .mark(let session, let label) = back.body else {
        Issue.record("wrong body case"); return
    }
    #expect(session == "abc")
    #expect(label == "ran tests")
}

@Test("A marked response carries the time the marker landed at")
func markedResponseRoundTrips() throws {
    let response = AutomationResponse.marked(timeSeconds: 12.5)
    let back = try JSONDecoder().decode(
        AutomationResponse.self, from: JSONEncoder().encode(response))
    #expect(back == response)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProtocolTests`
Expected: FAIL — version is 1; `workingDirectory` and `.mark` do not exist.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SnittAutomation/Protocol.swift`:

Change the version, keeping the comment accurate:

```swift
public enum AutomationProtocol {
    /// Bumped whenever the wire format changes incompatibly. The server refuses
    /// mismatches rather than guessing (§10).
    ///
    /// 2 — added `.mark` and `StartOptions.workingDirectory`. The new request
    /// case is why this is a bump and not an additive change: an old app cannot
    /// decode `.mark` and would report `internal_error`, where §10 wants a
    /// refusal that says what to do.
    public static let version = 2
}
```

Add to `StartOptions`, after `maxDurationSeconds`:

```swift
    /// The client's working directory, used to discover git context (§7).
    ///
    /// Filled by the CLI, not the app: `Snitt.app`'s own directory is `/`, so it
    /// cannot know which repository a recording is about. Hotkey recordings have
    /// no working directory and therefore no git context, which is correct —
    /// pressing a key is not associated with a checkout.
    public var workingDirectory: String?
```

and to its `init`, as the last parameter with a `nil` default:

```swift
                workingDirectory: String? = nil,
```
```swift
        self.workingDirectory = workingDirectory
```

Add the request case to `AutomationRequest.Body`:

```swift
        case mark(sessionID: String, label: String?)
```

Add the response case to `AutomationResponse`:

```swift
        case marked(timeSeconds: Double)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProtocolTests`
Expected: PASS — 5 new tests, 146 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittAutomation/Protocol.swift Tests/SnittAutomationTests/ProtocolTests.swift
git commit -m "feat(automation): protocol v2 — markers and client working directory

The version moves because .mark is not additive: an old app cannot decode it
and would report internal_error, where section 10 wants a refusal that names
the fix. Working directory travels from the client because Snitt.app's own cwd
is / and it cannot know which repository a recording is about."
```

---

## Task 3: Markers over the automation surface

**Files:**
- Create: `Sources/SnittCapture/MarkerLog.swift`
- Modify: `Sources/SnittCapture/Recorder.swift`
- Modify: `Sources/SnittApp/AutomationHost.swift`
- Modify: `Sources/SnittApp/RecordingCoordinator.swift`
- Modify: `Sources/SnittAutomation/CommandLineParser.swift`
- Modify: `Sources/snitt-cli/main.swift`
- Modify: `Sources/SnittAutomation/MCPBridge.swift`
- Create: `Tests/SnittCaptureTests/MarkerLogTests.swift`
- Modify: `Tests/SnittAutomationTests/CommandLineParserTests.swift`
- Modify: `Tests/SnittAutomationTests/MCPBridgeTests.swift`

**Interfaces:**
- Consumes: `LoggedEvent`, `EventKind.marker`, `EventLog`, `AutomationRequest.Body.mark`, `AgentRecordingControlling`
- Produces:
  - `public actor MarkerLog` with `func add(at: Double, label: String?)`, `func snapshot() -> [LoggedEvent]`
  - `Recorder.mark(label: String?) async -> Double` — returns the offset it recorded
  - `RecordingCoordinator.markForAgent(sessionID:label:) async -> AgentMarkResult`
  - `public enum AgentMarkResult: Equatable, Sendable { case marked(Double), notRecording, notCurrentSession }`
  - `ParsedCommand.recordMark(sessionID: String, label: String?)`
  - MCP tool `snitt_add_marker`

**The agent case is the stronger one (§4.12):** an agent narrates its own actions far better
than a human reconstructing them cold, and that narration currently has nowhere to attach.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/MarkerLogTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittCapture
import SnittDocument

@Test("Markers accumulate in the order they were added")
func markersAccumulateInOrder() async {
    let log = MarkerLog()
    await log.add(at: 1.0, label: "first")
    await log.add(at: 5.5, label: nil)
    let events = await log.snapshot()

    #expect(events.count == 2)
    #expect(events.map(\.timeSeconds) == [1.0, 5.5])
    #expect(events[0].label == "first")
    #expect(events[1].label == nil)
}

@Test("Every marker is stored as EventKind.marker")
func markersUseTheMarkerKind() async {
    // events.json is a shared log; M3b adds clicks and keystrokes to it. A
    // marker stored under any other kind would be invisible to chapter export.
    let log = MarkerLog()
    await log.add(at: 2.0, label: "x")
    #expect(await log.snapshot().allSatisfy { $0.kind == .marker })
}

@Test("A snapshot is a copy — later marks do not mutate it")
func snapshotIsACopy() async {
    let log = MarkerLog()
    await log.add(at: 1.0, label: "a")
    let first = await log.snapshot()
    await log.add(at: 2.0, label: "b")
    #expect(first.count == 1, "the snapshot handed to the writer must not change under it")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MarkerLogTests`
Expected: FAIL — `cannot find 'MarkerLog' in scope`.

- [ ] **Step 3: Write the marker log**

Create `Sources/SnittCapture/MarkerLog.swift`:

```swift
import Foundation
import SnittDocument

/// Timestamped bookmarks dropped while recording (§4.12).
///
/// An actor because marks arrive from the automation socket's connection
/// threads and from the main actor's hotkey, while the writer reads them at
/// stop. Ordering is arrival order, which is also time order in practice.
public actor MarkerLog {
    private var events: [LoggedEvent] = []

    public init() {}

    public func add(at timeSeconds: Double, label: String?) {
        events.append(LoggedEvent(timeSeconds: timeSeconds, kind: .marker, label: label))
    }

    public func snapshot() -> [LoggedEvent] { events }
}
```

- [ ] **Step 4: Wire markers into the recorder**

In `Sources/SnittCapture/Recorder.swift`, add a stored property beside the existing ones:

```swift
    private let markers = MarkerLog()
```

Add the marking entry point next to `stop()`:

```swift
    /// Records a marker at the current offset into the recording.
    ///
    /// Returns the offset so the caller can report it — an agent that just
    /// marked "ran the tests" wants to know where that landed.
    public func mark(label: String?) -> Double {
        let offset = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        Task { await markers.add(at: offset, label: label) }
        return offset
    }
```

Then change `writeSidecars(stoppedAt:)` so it writes the collected markers instead of an
empty log. Replace the line `try EventLog().write(to: bundle)` with:

```swift
        try EventLog(events: collectedMarkers).write(to: bundle)
```

and take the snapshot before calling it. In `stop()`, immediately before
`try writeSidecars(stoppedAt: stoppedAt)`, add:

```swift
        let collectedMarkers = await markers.snapshot()
```

and change `writeSidecars`'s signature to
`private func writeSidecars(stoppedAt: Date, collectedMarkers: [LoggedEvent]) throws`,
passing them through at the call site.

- [ ] **Step 5: Add the coordinator and host paths**

In `Sources/SnittApp/RecordingCoordinator.swift`, add beside `AgentStopResult`:

```swift
public enum AgentMarkResult: Equatable, Sendable {
    case marked(Double)
    case notRecording
    case notCurrentSession
}
```

and the method, next to `stopForAgent`:

```swift
    /// Drops a marker into the running agent recording (§4.12).
    ///
    /// Ownership is checked inside the actor, in the same critical section as
    /// the mark, for the same reason `stopForAgent` does: a marker landing in
    /// a human's recording because a stale session id was accepted is the same
    /// class of leak as returning them its bundle path.
    public func markForAgent(sessionID: String, label: String?) -> AgentMarkResult {
        guard let recorder = active, agentSessionID != nil else { return .notRecording }
        guard agentSessionID == sessionID else { return .notCurrentSession }
        return .marked(recorder.mark(label: label))
    }
```

Add it to the `AgentRecordingControlling` protocol so `AutomationHost` stays testable:

```swift
    func markForAgent(sessionID: String, label: String?) async -> AgentMarkResult
```

In `Sources/SnittApp/AutomationHost.swift`, add a `case .mark` arm to `handle(_:)`:

```swift
        case .mark(let sessionID, let label):
            return await mark(sessionID: sessionID, label: label)
```

and the method:

```swift
    private func mark(sessionID: String, label: String?) async -> AutomationResponse {
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }
        switch await coordinator.markForAgent(sessionID: sessionID, label: label) {
        case .marked(let offset):
            return .marked(timeSeconds: offset)
        case .notCurrentSession, .notRecording:
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No recording with that session id.",
                hint: "Markers can only be added to a recording you started. "
                    + "Check `snitt status` for the current session."))
        }
    }
```

- [ ] **Step 6: Add the CLI and MCP surfaces**

In `Sources/SnittAutomation/CommandLineParser.swift`, add the case to `ParsedCommand`:

```swift
    case recordMark(sessionID: String, label: String?)
```

and inside `parse`'s `"record"` branch, alongside `"start"` and `"stop"`:

```swift
            case "mark":
                guard let session = args.first else {
                    return .failure(ParseFailure(
                        "`record mark` needs a session id. Run `snitt status` to find it."))
                }
                var label: String?
                if args.count > 1 {
                    guard args[1] == "--label", args.count > 2 else {
                        return .failure(ParseFailure("Unknown option after the session id. "
                                                   + "Use `--label <text>`."))
                    }
                    label = args[2]
                }
                return .success(.recordMark(sessionID: session, label: label))
```

In `Sources/snitt-cli/main.swift`, map the command and render the response. Add to the
body switch:

```swift
case .recordMark(let session, let label): body = .mark(sessionID: session, label: label)
```

and to the response switch:

```swift
    case .marked(let seconds):
        emit(["markedAtSeconds": seconds])
        note(String(format: "Marker at %.1fs", seconds))
```

Add to the help text, under `record stop`:

```
  snitt record mark <session-id> [--label <text>]   drop a marker
```

In `Sources/SnittAutomation/MCPBridge.swift`, add a fifth tool definition:

```swift
            ToolDefinition(
                name: "snitt_add_marker",
                description: "Drop a labelled marker into the running recording, so a "
                           + "reviewer can jump to this moment. Narrate what you just did.",
                inputSchemaJSON: #"""
                {"type":"object",
                 "properties":{
                   "sessionId":{"type":"string"},
                   "label":{"type":"string",
                     "description":"What is happening at this moment"}},
                 "required":["sessionId"]}
                """#),
```

and the mapping arm:

```swift
        case "snitt_add_marker":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_add_marker requires sessionId"))
            }
            return .success(.mark(sessionID: session, arguments["label"] as? String))
```

Add `describe`'s arm in `Sources/snitt-mcp/main.swift`:

```swift
    case .marked(let seconds):
        return String(format: "Marker recorded at %.1fs", seconds)
```

- [ ] **Step 7: Add the frontend-parity tests**

Add to `Tests/SnittAutomationTests/CommandLineParserTests.swift`:

```swift
@Test("record mark parses a session and an optional label")
func parsesRecordMark() {
    #expect(CommandLineParser.parse(["record", "mark", "abc"])
            == .success(.recordMark(sessionID: "abc", label: nil)))
    #expect(CommandLineParser.parse(["record", "mark", "abc", "--label", "ran tests"])
            == .success(.recordMark(sessionID: "abc", label: "ran tests")))
}

@Test("record mark without a session id is refused")
func recordMarkNeedsSession() {
    #expect(CommandLineParser.parse(["record", "mark"]).isFailure)
}
```

Add to `Tests/SnittAutomationTests/MCPBridgeTests.swift`:

```swift
@Test("Both frontends express a marker identically")
func frontendsAgreeOnMarkers() {
    // §4.8: the CLI and the MCP server must be incapable of diverging.
    guard case .success(.recordMark(let cliSession, let cliLabel)) =
        CommandLineParser.parse(["record", "mark", "s1", "--label", "step two"]) else {
        Issue.record("CLI could not express a marker"); return
    }
    guard case .success(.mark(let mcpSession, let mcpLabel)) = MCPBridge.request(
        forTool: "snitt_add_marker",
        arguments: ["sessionId": "s1", "label": "step two"]) else {
        Issue.record("MCP could not express a marker"); return
    }
    #expect(cliSession == mcpSession)
    #expect(cliLabel == mcpLabel)
}
```

Note `toolNamesAreStable` in that file asserts the exact tool-name set — update it to
include `snitt_add_marker`, or it will fail.

- [ ] **Step 8: Run the suite**

Run: `swift test`
Expected: PASS — 152 total (146 + 3 marker log + 2 parser + 1 parity).

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 9: Commit**

```bash
git add Sources/SnittCapture/MarkerLog.swift Sources/SnittCapture/Recorder.swift \
        Sources/SnittApp Sources/SnittAutomation Sources/snitt-cli Sources/snitt-mcp \
        Tests/SnittCaptureTests/MarkerLogTests.swift Tests/SnittAutomationTests
git commit -m "feat(markers): drop timestamped bookmarks while recording

Ownership is checked inside the coordinator actor in the same critical section
as the mark, for the reason stopForAgent does it: a marker landing in a human's
recording via a stale session id is the same class of leak as handing over
their bundle path."
```

---

## Task 4: A marker hotkey for humans

**Files:**
- Modify: `Sources/SnittApp/HotkeyMonitor.swift`
- Modify: `Sources/SnittApp/main.swift`
- Modify: `Tests/SnittAppTests/HotkeyMonitorTests.swift`

**Interfaces:**
- Consumes: `HotkeyCombination`, `HotkeyMonitor`
- Produces: `HotkeyCombination.markerCombination`; `HotkeyMonitor` routing by id

**THE BUG THIS TASK MUST FIX FIRST.** `HotkeyMonitor` cannot support a second hotkey as
written, and the failure is silent rather than a crash. Two problems in the current code:

1. `EventHotKeyID(signature: OSType(0x534E_5454), id: 1)` hard-codes `id: 1`, so two
   monitors register the same identifier.
2. The Carbon callback never inspects **which** hotkey fired — it calls its own monitor's
   `onFire()` unconditionally. Two monitors install two handlers on the same application
   event target, so **pressing either hotkey fires both callbacks**.

Left unfixed, pressing ⌥⌘5 would start a recording *and* drop a marker.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SnittAppTests/HotkeyMonitorTests.swift`:

```swift
@Test("Each registration gets a distinct hotkey id")
func registrationsGetDistinctIDs() {
    // Two monitors sharing an id is half of why a second hotkey fires both
    // callbacks; the other half is the handler not checking which id fired.
    let first = HotkeyMonitor.nextHotKeyID()
    let second = HotkeyMonitor.nextHotKeyID()
    #expect(first != second)
}

@Test("The marker combination differs from the record combination")
func markerCombinationIsDistinct() {
    #expect(HotkeyCombination.markerCombination != HotkeyCombination.defaultCombination)
}

@Test("A monitor only fires for its own hotkey id")
func monitorIgnoresOtherHotkeys() {
    var fired = 0
    let monitor = HotkeyMonitor(combination: .markerCombination) { fired += 1 }
    monitor.handle(hotKeyID: monitor.hotKeyID)
    #expect(fired == 1)
    monitor.handle(hotKeyID: monitor.hotKeyID &+ 1)
    #expect(fired == 1, "a monitor must ignore a hotkey it did not register")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotkeyMonitorTests`
Expected: FAIL — `nextHotKeyID`, `markerCombination`, `handle(hotKeyID:)` do not exist.

- [ ] **Step 3: Fix the routing**

In `Sources/SnittApp/HotkeyMonitor.swift`, add to `HotkeyCombination`:

```swift
    /// Option-Command-M — "mark". Distinct from the record combination so the
    /// two never collide (§4.12).
    public static let markerCombination = HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(optionKey | cmdKey)
    )
```

Add to `HotkeyMonitor`, replacing the hard-coded id:

```swift
    private static let idCounter = OSAllocatedUnfairLock(initialState: UInt32(0))

    /// Hands out a fresh hotkey id per registration.
    ///
    /// Previously every monitor used `id: 1`. Combined with a callback that
    /// never checked which hotkey fired, a second monitor made BOTH callbacks
    /// run on either keypress — so adding a marker hotkey would have started a
    /// recording too.
    public static func nextHotKeyID() -> UInt32 {
        idCounter.withLock { value in value += 1; return value }
    }

    public let hotKeyID: UInt32 = HotkeyMonitor.nextHotKeyID()

    /// Invoked by the Carbon callback with the id that actually fired.
    func handle(hotKeyID firedID: UInt32) {
        guard firedID == hotKeyID else { return }
        onFire()
    }
```

Add `import os` for `OSAllocatedUnfairLock`.

Change the callback to read the fired id from the event and route through `handle`:

```swift
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var firedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            let monitor = Unmanaged<HotkeyMonitor>
                .fromOpaque(userData).takeUnretainedValue()
            monitor.handle(hotKeyID: firedID.id)
            return noErr
        }
```

and use the instance id when registering:

```swift
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_5454), id: self.hotKeyID)
```

- [ ] **Step 4: Register the marker hotkey**

In `Sources/SnittApp/main.swift`'s `applicationDidFinishLaunching`, after the existing
hotkey is started, add:

```swift
        let markerHotkey = HotkeyMonitor(combination: .markerCombination) { [weak self] in
            self?.handleMarkerHotkey()
        }
        try? markerHotkey.start()
        self.markerHotkey = markerHotkey
```

with the stored property `private var markerHotkey: HotkeyMonitor?`, and the handler:

```swift
    /// ⌥⌘M drops a marker into whatever is recording — the human half of §4.12.
    ///
    /// Deliberately silent when nothing is recording: a marker hotkey that
    /// interrupts with an alert would be worse than one that does nothing.
    private func handleMarkerHotkey() {
        guard let coordinator else { return }
        Task { await coordinator.markCurrentRecording(label: nil) }
    }
```

In `RecordingCoordinator`, add the human-side entry point next to `markForAgent`:

```swift
    /// Marks whatever is recording, regardless of who started it (§4.12).
    @discardableResult
    public func markCurrentRecording(label: String?) -> Double? {
        active?.mark(label: label)
    }
```

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: PASS — 155 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests/HotkeyMonitorTests.swift
git commit -m "fix(hotkey): route by hotkey id so two hotkeys can coexist

HotkeyMonitor hard-coded id 1 and its Carbon callback never checked which
hotkey fired, so a second monitor made BOTH callbacks run on either keypress.
Adding the marker hotkey would have started a recording as well. Ids are now
per-registration and the handler ignores hotkeys it did not register."
```

---

## Task 5: Focus the target before capture starts

**Files:**
- Create: `Sources/SnittApp/WindowFocuser.swift`
- Modify: `Sources/SnittApp/RecordingCoordinator.swift`
- Create: `Tests/SnittAppTests/WindowFocuserTests.swift`

**Interfaces:**
- Consumes: `ResolvedTarget`, `CaptureTargetDescriptor`
- Produces:
  - `public struct WindowFocuser: Sendable` with
    `init(activate: @Sendable @escaping (pid_t) -> Bool)`, `static let system`
  - `public func focus(_ target: ResolvedTarget) -> Bool`

**A DELIBERATE LIMITATION, stated up front.** §4.13 says Snitt "brings the chosen window to
the front and activates its application". M3a does **only the second half**. Raising one
specific window among several requires `AXUIElement`, which needs the **Accessibility**
grant — a broader permission than anything in §4.10's ladder, and one this milestone is
explicitly not allowed to add. Activating the application is free.

So: the target's app comes forward; if it has several windows, the one macOS fronts may not
be the captured one. Recording still works — ScreenCaptureKit captures occluded windows
fine (§4.13) — but the "watchable" goal is only partly met. Raising the exact window is
deferred to whenever Accessibility is on the table, and this limitation must be written
into the code, not just this plan.

**Display captures never auto-focus; there is nothing to bring forward.** (§4.13)

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/WindowFocuserTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp
@testable import SnittCapture

private func descriptor(kind: String, pid: pid_t?) -> CaptureTargetDescriptor {
    CaptureTargetDescriptor(id: 1, kind: kind, title: "t",
                            applicationName: "App", width: 100, height: 100,
                            processID: pid)
}

@Test("A window target activates its owning application")
func windowTargetActivates() {
    var activated: [pid_t] = []
    let focuser = WindowFocuser { pid in activated.append(pid); return true }
    #expect(focuser.focus(descriptor: descriptor(kind: "window", pid: 42)) == true)
    #expect(activated == [42])
}

@Test("A display target is never focused — there is nothing to bring forward")
func displayTargetDoesNotActivate() {
    var activated: [pid_t] = []
    let focuser = WindowFocuser { pid in activated.append(pid); return true }
    #expect(focuser.focus(descriptor: descriptor(kind: "display", pid: nil)) == false)
    #expect(activated.isEmpty)
}

@Test("A window with no owning process is skipped rather than guessed at")
func missingProcessIsSkipped() {
    var activated: [pid_t] = []
    let focuser = WindowFocuser { pid in activated.append(pid); return true }
    #expect(focuser.focus(descriptor: descriptor(kind: "window", pid: nil)) == false)
    #expect(activated.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WindowFocuserTests`
Expected: FAIL — `WindowFocuser` does not exist, and `CaptureTargetDescriptor` has no
`processID`.

- [ ] **Step 3: Carry the process id on the descriptor**

In `Sources/SnittCapture/CaptureTarget.swift`, add to `CaptureTargetDescriptor`:

```swift
    /// The owning application's process id, for window targets. Needed to
    /// activate the app before capture starts (§4.13); nil for displays.
    public var processID: pid_t?
```

The existing initialiser is
`init(id:kind:title:applicationName:width:height:)` — six parameters, no default values.
Add `processID: pid_t? = nil` as a seventh, LAST, with a default, so the two existing call
sites in `descriptor` and the several in tests keep compiling unchanged. Then populate it
in the `.window` arm of `descriptor`:

```swift
                processID: window.owningApplication?.processID,
```

Leave the `.display` arm's `processID` unset.

- [ ] **Step 4: Write the focuser**

Create `Sources/SnittApp/WindowFocuser.swift`:

```swift
import AppKit
import Foundation
import SnittCapture

/// Brings the target's application forward before capture starts (§4.13).
///
/// **Limitation, deliberate.** §4.13 asks for the chosen *window* to be raised.
/// This raises only its *application*: fronting one specific window among
/// several requires `AXUIElement`, which needs the Accessibility grant — a
/// broader permission than anything in §4.10's ladder, and one M3a may not add.
/// Recording is unaffected either way, since ScreenCaptureKit captures occluded
/// windows correctly; only the "watchable first frames" goal is partly met.
///
/// Focus happens BEFORE `startCapture`, so the activation transition — a
/// dismissed menu, a moved focus ring — is not in the recording (§4.13).
public struct WindowFocuser: Sendable {
    private let activate: @Sendable (pid_t) -> Bool

    public init(activate: @Sendable @escaping (pid_t) -> Bool) {
        self.activate = activate
    }

    public static let system = WindowFocuser { pid in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    /// Returns whether anything was actually activated.
    public func focus(descriptor: CaptureTargetDescriptor) -> Bool {
        guard descriptor.kind == CaptureTargetDescriptor.Kind.window.rawValue else {
            return false   // displays have nothing to bring forward
        }
        guard let pid = descriptor.processID else { return false }
        return activate(pid)
    }
}
```

- [ ] **Step 5: Call it before capture starts**

In `Sources/SnittApp/RecordingCoordinator.swift`, add a stored property and init parameter:

```swift
    private let focuser: WindowFocuser
```
```swift
                focuser: WindowFocuser = .system,
```
```swift
        self.focuser = focuser
```

In `startRecording`, immediately **after** `resolver.resolve()` succeeds and **before**
`Recorder` is constructed, add:

```swift
        // Before capture starts, never after: activating a window can dismiss a
        // menu or move a focus ring, and that transition must not be in the
        // recording (§4.13). Suppressed when the caller asked for it — recording
        // a window precisely because it is in the background is a real case.
        if !suppressFocus {
            _ = focuser.focus(descriptor: target.descriptor)
        }
```

Add `suppressFocus: Bool = false` as a parameter of `startRecording(forcedResolver:)` and
thread it from `toggle()` and `startForAgent`.

- [ ] **Step 6: Add the suppression modifier**

In `Sources/SnittApp/main.swift`'s `handleHotkey`, read the modifier at press time:

```swift
        // §4.13: auto-focus is the default, not a rule. Holding Shift while
        // pressing the hotkey records the target where it sits.
        let suppress = NSEvent.modifierFlags.contains(.shift)
```

and pass it into `coordinator.toggle(suppressFocus: suppress)`, adding that parameter to
`toggle()` with a `false` default.

- [ ] **Step 7: Run the suite**

Run: `swift test`
Expected: PASS — 158 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 8: Commit**

```bash
git add Sources/SnittApp Sources/SnittCapture/CaptureTarget.swift Tests/SnittAppTests/WindowFocuserTests.swift
git commit -m "feat(capture): activate the target's app before recording starts

Focus happens before startCapture so the activation transition is not in the
recording, and Shift suppresses it for the real case of recording a window
precisely because it is in the background.

Raises the application, not the specific window: fronting one window among
several needs AXUIElement and therefore the Accessibility grant, which M3a is
not allowed to add. Recorded in the type's own doc comment."
```

---

## Task 6: Capture health sampling

**Files:**
- Create: `Sources/SnittCapture/HealthSampler.swift`
- Modify: `Sources/SnittCapture/AssetWriterSink.swift`
- Create: `Tests/SnittCaptureTests/HealthSamplerTests.swift`

**Interfaces:**
- Consumes: `TrackKind`, `CMSampleBuffer`
- Produces:
  - `public final class HealthSampler: @unchecked Sendable`
  - `public func observe(_ buffer: CMSampleBuffer, track: TrackKind)`
  - `public func result() -> CaptureHealth`
  - `public static func variance(ofLuma samples: [Double]) -> Double`
  - `public static func rms(ofFloatSamples samples: [Float]) -> Double`

**§12.1's reason for existing:** an agent is blind to its own output. A recording of the
wrong window, an occluded surface, or a dead microphone returns a valid path and exit 0
today, and the agent attaches a black or silent video to a pull request with complete
confidence.

**Health metrics are warnings, never failures**, and no threshold may gate anything until
tuned against real recordings (§12.1). This task computes and reports; it decides nothing.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/HealthSamplerTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittCapture

@Test("A constant image has zero variance — the frozen/black case")
func constantImageHasZeroVariance() {
    #expect(HealthSampler.variance(ofLuma: [40, 40, 40, 40]) == 0)
}

@Test("A varied image has non-zero variance")
func variedImageHasVariance() {
    #expect(HealthSampler.variance(ofLuma: [0, 255, 0, 255]) > 1000)
}

@Test("Variance of fewer than two samples is zero, not a divide by zero")
func varianceOfTooFewSamples() {
    #expect(HealthSampler.variance(ofLuma: []) == 0)
    #expect(HealthSampler.variance(ofLuma: [42]) == 0)
}

@Test("Silence has zero RMS — the dead-microphone case")
func silenceHasZeroRMS() {
    #expect(HealthSampler.rms(ofFloatSamples: [0, 0, 0, 0]) == 0)
}

@Test("A full-scale square wave has RMS 1")
func fullScaleHasRMSOne() {
    // RMS of ±1 is exactly 1. A sampler that averaged amplitudes instead of
    // their squares would also return 1 here, so the next test separates them.
    #expect(abs(HealthSampler.rms(ofFloatSamples: [1, -1, 1, -1]) - 1.0) < 0.0001)
}

@Test("RMS is root-mean-SQUARE, not mean amplitude")
func rmsIsNotMeanAmplitude() {
    // mean(|x|) of [1, 0] is 0.5; RMS is sqrt(0.5) ≈ 0.7071. A sampler that
    // averaged amplitudes would report 0.5 and pass every other test here.
    #expect(abs(HealthSampler.rms(ofFloatSamples: [1, 0]) - 0.70710678) < 0.0001)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HealthSamplerTests`
Expected: FAIL — `cannot find 'HealthSampler' in scope`.

- [ ] **Step 3: Write the sampler**

Create `Sources/SnittCapture/HealthSampler.swift`:

```swift
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SnittDocument

/// Cheap health metrics gathered during the existing writer pass (§12.1).
///
/// Exists because an agent is blind to its own output: a recording of the wrong
/// window, an occluded surface, or a dead microphone returns a valid path and
/// exit 0 today. These are WARNINGS, never failures — a legitimately static UI
/// demo will trip low frame variance, so no threshold gates anything until it
/// has been tuned against real recordings.
///
/// Sampling is deliberately sparse: every Nth frame, and a grid within it. The
/// cost has to stay far below the encode it rides along with, or it would
/// change the thing it is measuring.
public final class HealthSampler: @unchecked Sendable {
    /// Every Nth video frame is inspected.
    public static let frameStride = 30
    /// Pixels are sampled on a grid this many rows/columns apart.
    public static let pixelStride = 64

    private let lock = NSLock()
    private var frameIndex = 0
    private var frameVariances: [Double] = []
    private var micSumOfSquares = 0.0, micSampleCount = 0
    private var systemSumOfSquares = 0.0, systemSampleCount = 0

    public init() {}

    public static func variance(ofLuma samples: [Double]) -> Double {
        guard samples.count > 1 else { return 0 }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let sum = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sum / Double(samples.count)
    }

    public static func rms(ofFloatSamples samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    public func observe(_ buffer: CMSampleBuffer, track: TrackKind) {
        switch track {
        case .video: observeVideo(buffer)
        case .microphone, .systemAudio: observeAudio(buffer, track: track)
        }
    }

    private func observeVideo(_ buffer: CMSampleBuffer) {
        lock.lock()
        let index = frameIndex
        frameIndex += 1
        lock.unlock()
        guard index % Self.frameStride == 0 else { return }

        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let width = CVPixelBufferGetWidth(pixels)

        // BGRA: take the green channel as a luma proxy. Cheap, and green
        // carries most of perceived luminance.
        var samples: [Double] = []
        for row in stride(from: 0, to: height, by: Self.pixelStride) {
            for column in stride(from: 0, to: width, by: Self.pixelStride) {
                let offset = row * rowBytes + column * 4 + 1
                guard offset < rowBytes * height else { continue }
                samples.append(Double(bytes[offset]))
            }
        }
        let variance = Self.variance(ofLuma: samples)
        lock.lock(); frameVariances.append(variance); lock.unlock()
    }

    private func observeAudio(_ buffer: CMSampleBuffer, track: TrackKind) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            return   // only Float32 PCM is measured; anything else is skipped
        }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return }

        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let pointer = data.assumingMemoryBound(to: Float.self)
        var sum = 0.0
        for index in 0..<count {
            let sample = Double(pointer[index])
            sum += sample * sample
        }

        lock.lock()
        switch track {
        case .microphone: micSumOfSquares += sum; micSampleCount += count
        case .systemAudio: systemSumOfSquares += sum; systemSampleCount += count
        case .video: break
        }
        lock.unlock()
    }

    public func result() -> CaptureHealth {
        lock.lock(); defer { lock.unlock() }
        let meanVariance = frameVariances.isEmpty
            ? nil
            : frameVariances.reduce(0, +) / Double(frameVariances.count)
        let mic = micSampleCount > 0
            ? (micSumOfSquares / Double(micSampleCount)).squareRoot() : nil
        let system = systemSampleCount > 0
            ? (systemSumOfSquares / Double(systemSampleCount)).squareRoot() : nil
        return CaptureHealth(meanFrameVariance: meanVariance,
                             micRMS: mic, systemAudioRMS: system)
    }
}
```

- [ ] **Step 4: Feed it from the writer pass**

In `Sources/SnittCapture/AssetWriterSink.swift`, add a stored property:

```swift
    /// §12.1: sampling rides the existing pass — there is no second decode.
    public let health = HealthSampler()
```

and at the top of `append(_:to:)`, before the existing body:

```swift
        health.observe(buffer, track: track)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter HealthSamplerTests`
Expected: PASS — 6 new tests, 164 total.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittCapture/HealthSampler.swift Sources/SnittCapture/AssetWriterSink.swift \
        Tests/SnittCaptureTests/HealthSamplerTests.swift
git commit -m "feat(capture): sample frame variance and audio RMS during the writer pass

Section 12.1 exists because an agent is blind to its own output: a black video
or a dead mic returns exit 0 today. These are warnings only — a static UI demo
legitimately trips low variance, so nothing is gated until the thresholds are
tuned against real recordings."
```

---

## Task 7: Health, git context, and bundle naming in the document

**Files:**
- Create: `Sources/SnittCapture/BundleNaming.swift`
- Modify: `Sources/SnittCapture/Recorder.swift`
- Modify: `Sources/SnittCapture/CaptureSession.swift`
- Modify: `Sources/SnittApp/AutomationHost.swift`
- Modify: `Sources/SnittApp/RecordingCoordinator.swift`
- Modify: `Sources/snitt-cli/main.swift`
- Create: `Tests/SnittCaptureTests/BundleNamingTests.swift`

**Interfaces:**
- Consumes: `CaptureHealth`, `GitContext`, `GitContextResolver`, `HealthSampler`
- Produces:
  - `public enum BundleNaming` with `static func filename(git: GitContext?, timestamp: Int) -> String`
  - `Recorder.init(..., git: GitContext?)`
  - `AutomationResponse.stopped` gains health in the CLI's rendered output

**§7's naming rule:** "a demo arrives as `feature-branch-a1b2c3.snitt` rather than
`Screen Recording 2026-09-02.mov`."

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/BundleNamingTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittCapture
import SnittDocument

@Test("A branch and commit name the bundle")
func branchAndCommitNameTheBundle() {
    let name = BundleNaming.filename(
        git: GitContext(branch: "feature/markers", commit: "a1b2c3d"), timestamp: 100)
    #expect(name == "feature-markers-a1b2c3d.snitt")
}

@Test("A slash in a branch name never becomes a path separator")
func slashesAreReplaced() {
    // The name is appended to a directory URL. A branch called "feature/x"
    // would otherwise write into a "feature" SUBDIRECTORY that does not exist,
    // and the bundle creation would fail — with intermediate directories
    // deliberately disabled, this fails loudly rather than scattering files.
    let name = BundleNaming.filename(
        git: GitContext(branch: "a/b/c", commit: "d"), timestamp: 1)
    #expect(!name.contains("/"))
}

@Test("No git context falls back to the timestamped name")
func noGitFallsBackToTimestamp() {
    #expect(BundleNaming.filename(git: nil, timestamp: 1788464616)
            == "Snitt-1788464616.snitt")
}

@Test("A commit with no branch still names the bundle")
func commitOnlyNamesTheBundle() {
    #expect(BundleNaming.filename(git: GitContext(branch: nil, commit: "a1b2c3d"),
                                  timestamp: 1) == "a1b2c3d.snitt")
}

@Test("A branch with no commit still names the bundle")
func branchOnlyNamesTheBundle() {
    #expect(BundleNaming.filename(git: GitContext(branch: "main", commit: nil),
                                  timestamp: 1) == "main.snitt")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BundleNamingTests`
Expected: FAIL — `cannot find 'BundleNaming' in scope`.

- [ ] **Step 3: Write the namer**

Create `Sources/SnittCapture/BundleNaming.swift`:

```swift
import Foundation
import SnittDocument

/// Names a bundle after the work it documents (§7).
///
/// "A demo arrives as `feature-branch-a1b2c3.snitt` rather than
/// `Screen Recording 2026-09-02.mov`."
public enum BundleNaming {
    public static func filename(git: GitContext?, timestamp: Int) -> String {
        let parts = [git?.branch, git?.commit]
            .compactMap { $0 }
            .map(sanitize)
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return "Snitt-\(timestamp).snitt" }
        return parts.joined(separator: "-") + ".snitt"
    }

    /// Branch names legitimately contain "/" and ":". The result is appended to
    /// a directory URL, so an unsanitised slash would target a subdirectory that
    /// does not exist rather than naming the bundle.
    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
```

- [ ] **Step 4: Thread git context and health through the recorder**

In `Sources/SnittCapture/Recorder.swift`, add an init parameter `git: GitContext? = nil`
with a matching stored property. Note `initiator` deliberately has NO default — M2b removed
it so that an omitted argument is a compile error rather than a silently mislabelled
recording — so `git` goes after it in the parameter list. In `writeSidecars`, populate both
new fields:

```swift
        let metadata = RecordingMetadata(
            schemaVersion: 1,
            createdAt: startedAt ?? stoppedAt,
            initiator: initiator,
            durationSeconds: duration,
            git: git,
            health: session.health()
        )
```

Expose the sampler's result from `CaptureSession`. `CaptureSession` holds
`private let sink: SampleBufferSink`, so the sampler must be reachable through the
protocol. Three edits:

In `Sources/SnittCapture/SampleBufferSink.swift`, add to the protocol:

```swift
    /// §12.1's metrics, gathered while buffers pass through. On the protocol
    /// rather than the concrete sink because `CaptureSession` only ever sees
    /// the protocol.
    var health: HealthSampler { get }
```

`AssetWriterSink` already satisfies this via the `public let health = HealthSampler()`
added in Step 4 of Task 6.

In `Sources/SnittCapture/CaptureSession.swift`, add:

```swift
    /// §12.1's metrics, gathered by the sink during the writer pass.
    func health() -> CaptureHealth { sink.health.result() }
```

In `Tests/SnittCaptureTests/CaptureSessionTests.swift`, `SpySink` must gain the member —
a fresh sampler is correct, since nothing feeds it in those tests:

```swift
    let health = HealthSampler()
```

- [ ] **Step 5: Resolve git context at request time**

In `Sources/SnittApp/AutomationHost.swift`'s `start(_:)`, after consent passes and before
calling the coordinator:

```swift
        // Resolved here, not in the coordinator: only the CLIENT knows which
        // repository a recording is about (§7). Snitt.app's own cwd is "/".
        let git = options.workingDirectory
            .map { URL(fileURLWithPath: $0) }
            .flatMap { GitContextResolver.resolve(in: $0) }
```

and pass it into `startForAgent(reference:git:)`, adding that parameter through
`RecordingCoordinator.startForAgent` and `startRecording(forcedResolver:suppressFocus:git:)`
to the `Recorder` construction, where it also selects the name:

```swift
        let url = outputDirectory.appendingPathComponent(
            BundleNaming.filename(git: git, timestamp: Int(Date().timeIntervalSince1970)))
```

In `Sources/snitt-cli/main.swift`, fill the working directory on every start:

```swift
case .recordStart(var options):
    options.workingDirectory = FileManager.default.currentDirectoryPath
    body = .startRecording(options)
```

- [ ] **Step 6: Report health from `record stop`**

§12.1: "`snitt record stop` returns cheap health metrics alongside the bundle path." Add
them to the CLI's stopped output in `Sources/snitt-cli/main.swift`, reading them back from
the bundle that was just written:

```swift
    case .stopped(let path):
        var payload: [String: Any] = ["bundlePath": path]
        // `init(opening:)` throws if the bundle is not there — the health block
        // is best-effort reporting, so a failure to read it must not turn a
        // successful recording into a CLI error.
        if let bundle = try? SnittBundle(opening: URL(fileURLWithPath: path)),
           let meta = try? RecordingMetadata.read(from: bundle),
           let health = meta.health {
            var block: [String: Any] = [:]
            if let v = health.meanFrameVariance { block["meanFrameVariance"] = v }
            if let m = health.micRMS { block["micRMS"] = m }
            if let s = health.systemAudioRMS { block["systemAudioRMS"] = s }
            if !block.isEmpty { payload["health"] = block }
        }
        emitObject(payload)
        note("Saved \(path)")
```

Note the optionals are unwrapped rather than bridged with `as Any`: `nil as Any` becomes
`NSNull` through `JSONSerialization`, so an absent metric would serialise as
`"micRMS": null` — an agent branching on key presence would read a dead microphone as a
reported measurement. Absent means absent.

Add this helper alongside `emit` in the same file, and `import SnittDocument` to the CLI:

```swift
/// Emits a heterogeneous payload. `emit` takes an `Encodable`; the stop response
/// mixes a string path with optional numbers, so it goes through JSONSerialization.
func emitObject(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}
```

**Do not add a warning threshold.** §12.1 forbids gating on these until they are tuned
against real recordings; the CLI reports the numbers and says nothing about them.

- [ ] **Step 7: Run the suite**

Run: `swift test`
Expected: PASS — 169 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 8: Commit**

```bash
git add Sources/SnittCapture Sources/SnittApp Sources/snitt-cli Tests/SnittCaptureTests/BundleNamingTests.swift
git commit -m "feat(document): populate git context, health, and bundle names

Every one of these fields has existed in SnittDocument since M1 and been nil in
every bundle written since. Git context resolves from the CLIENT's working
directory because Snitt.app's own cwd is / — hotkey recordings correctly have
none. Health is reported, never gated: section 12.1 forbids thresholds until
they are tuned against real recordings."
```

---

## Task 8: Progressive permission onboarding

**Files:**
- Create: `Sources/SnittApp/PermissionOnboarding.swift`
- Modify: `Sources/SnittApp/ConsentExplainer.swift`
- Modify: `Sources/SnittApp/RecordingCoordinator.swift`
- Create: `Tests/SnittAppTests/PermissionOnboardingTests.swift`

**Interfaces:**
- Consumes: `ScreenRecordingAccess`, `UserDefaults`
- Produces:
  - `public enum PermissionOnboarding` with
    `static func shouldPreExplain(_ service: Service, defaults: UserDefaults) -> Bool`,
    `static func markPreExplained(_ service: Service, defaults: UserDefaults)`,
    `static func settingsURL(for service: Service) -> URL`
  - `public enum PermissionOnboarding.Service: String, CaseIterable { case screenRecording, microphone }`

**§4.10's rule:** "Snitt shows its own brief sheet — what it needs, why, and that macOS will
ask next — *before* triggering the system dialog. A prompt the user is expecting reads as
normal software; one that appears unannounced reads as an app grabbing at their machine."

**Also fix a copy defect this task inherits.** `ConsentExplainer`'s current text says:

> "To start recording instantly from a keystroke, Snitt reuses your last chosen window
> rather than asking you to pick one every time."

That stopped being true when the hotkey moved to presenting the picker on every press
(§4.11, D42). It is shipping copy that describes behaviour the app no longer has, and it
must be rewritten in this task.

**And handle the already-denied case.** Once a user denies a TCC prompt, macOS never shows
it again — `CGRequestScreenCaptureAccess()` returns `false` immediately with no dialog. An
app that keeps "requesting" looks broken. When preflight fails *and* the user has been
prompted before, Snitt must deep-link to the right Settings pane instead.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/PermissionOnboardingTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.onboarding.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("A service is pre-explained the first time and never again")
func preExplainHappensOnce() {
    // §4.10: the sheet exists so the system dialog is expected. Showing it on
    // every recording would be nagging, which is the thing it prevents.
    let defaults = emptyDefaults()
    #expect(PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults))
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(!PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults))
}

@Test("Services are tracked independently")
func servicesAreIndependent() {
    // Marking screen recording explained must not silently consume the
    // microphone's first-run explanation — that is the second rung of §4.10's
    // ladder and the user has not seen it yet.
    let defaults = emptyDefaults()
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(PermissionOnboarding.shouldPreExplain(.microphone, defaults: defaults))
}

@Test("Every service deep-links to a distinct Settings pane")
func everyServiceHasADistinctSettingsPane() {
    let urls = PermissionOnboarding.Service.allCases.map {
        PermissionOnboarding.settingsURL(for: $0).absoluteString
    }
    #expect(urls.allSatisfy { $0.hasPrefix("x-apple.systempreferences:") })
    #expect(Set(urls).count == urls.count, "a shared pane would send users to the wrong list")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PermissionOnboardingTests`
Expected: FAIL — `cannot find 'PermissionOnboarding' in scope`.

- [ ] **Step 3: Write the onboarding policy**

Create `Sources/SnittApp/PermissionOnboarding.swift`:

```swift
import AppKit
import Foundation

/// The pre-explain step of §4.10's permission ladder.
///
/// macOS TCC dialogs cannot be merged, so the only thing Snitt controls is
/// whether one is EXPECTED. A prompt the user was told about reads as normal
/// software; one that appears unannounced reads as an app grabbing at their
/// machine. The sheet is shown once per service, never again.
public enum PermissionOnboarding {
    public enum Service: String, CaseIterable, Sendable {
        case screenRecording
        case microphone

        var displayName: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            }
        }

        var why: String {
            switch self {
            case .screenRecording:
                return "Snitt records the window you choose, plus its audio. "
                     + "macOS covers both under one permission."
            case .microphone:
                return "You turned on voiceover, so Snitt needs the microphone. "
                     + "Recordings without voiceover never use it."
            }
        }
    }

    private static func key(_ service: Service) -> String {
        "com.impressiver.snitt.preExplained.\(service.rawValue)"
    }

    public static func shouldPreExplain(_ service: Service,
                                        defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: key(service))
    }

    public static func markPreExplained(_ service: Service,
                                        defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(service))
    }

    /// Deep link to the exact Settings pane for a service.
    ///
    /// Needed because macOS shows a TCC prompt only ONCE. After a denial,
    /// requesting again returns false with no dialog, so an app that keeps
    /// "requesting" looks broken. Sending the user to the right list is the
    /// only remaining action.
    public static func settingsURL(for service: Service) -> URL {
        switch service {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security"
                             + "?Privacy_ScreenCapture")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security"
                             + "?Privacy_Microphone")!
        }
    }

    /// Shows the pre-explain sheet, returning whether the user chose to continue.
    @MainActor
    public static func preExplain(_ service: Service,
                                  defaults: UserDefaults = .standard) -> Bool {
        guard shouldPreExplain(service, defaults: defaults) else { return true }
        markPreExplained(service, defaults: defaults)

        let alert = NSAlert()
        alert.messageText = "Snitt needs \(service.displayName)"
        alert.informativeText = service.why + "\n\nmacOS will ask next."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Explains that the grant was already denied and offers the Settings pane.
    @MainActor
    public static func showAlreadyDenied(_ service: Service) {
        let alert = NSAlert()
        alert.messageText = "\(service.displayName) is turned off for Snitt"
        alert.informativeText =
            "macOS only asks once. Turn Snitt on in System Settings, then relaunch it — "
          + "the grant takes effect on the next launch, not immediately."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settingsURL(for: service))
        }
    }
}
```

The "relaunch, not immediately" wording is not a guess: spike S5 observed
`CGRequestScreenCaptureAccess()` returning `false` while the user was granting permission,
with the grant taking effect only on the next launch.

- [ ] **Step 4: Use it before requesting**

In `Sources/SnittApp/RecordingCoordinator.swift`'s `startRecording`, replace the direct
`ScreenRecordingAccess.ensureGranted()` call with a pre-explained version:

```swift
        let granted = await MainActor.run { () -> Bool in
            // Nothing is requested at launch; this is first use (§4.10).
            if CGPreflightScreenCaptureAccess() { return true }
            guard PermissionOnboarding.preExplain(.screenRecording) else { return false }
            let result = ScreenRecordingAccess.ensureGranted()
            if !result { PermissionOnboarding.showAlreadyDenied(.screenRecording) }
            return result
        }
```

Note this keeps `ScreenRecordingAccess.ensureGranted()` as the only place Request is
called, so the access-conformance guard still passes.

- [ ] **Step 5: Fix the stale ConsentExplainer copy**

In `Sources/SnittApp/ConsentExplainer.swift`, replace `informativeText` with text that
matches what the app actually does now:

```swift
        alert.informativeText = """
        Snitt asks you to pick a window each time you record, and macOS \
        re-confirms screen-recording access periodically — about once a month.

        That prompt is macOS asking, not Snitt. Approving it keeps recording \
        working.
        """
```

Update the type's doc comment too: it currently explains the prompt as the cost of reusing
a cached target, which is no longer the reason.

- [ ] **Step 6: Run the suite**

Run: `swift test`
Expected: PASS — 172 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests/PermissionOnboardingTests.swift
git commit -m "feat(app): pre-explain permissions, and deep-link when already denied

macOS shows a TCC prompt once; after a denial, requesting again returns false
with no dialog, so an app that keeps requesting looks broken. Sending the user
to the right Settings pane is the only remaining action.

Also fixes shipping copy that told users Snitt reuses their last chosen window
— untrue since the hotkey moved to presenting the picker every press."
```

---

## Definition of done for M3a

- [ ] `swift test` passes — 172 tests, 0 failures
- [ ] `swift build -Xswiftc -strict-concurrency=complete` emits zero source warnings
- [ ] The access-conformance test still passes; no frontend links a capture framework
- [ ] **No new TCC dialog appears anywhere in M3a** — §4.10's ladder is unchanged
- [ ] `snitt record start` from inside a repository produces a bundle named after the
      branch and commit, e.g. `feat-m3a-capture-context-a1b2c3d.snitt`
- [ ] That bundle's `meta.json` contains a populated `git` object **and** a `health` object
      with three numbers — all of which are `nil` in every bundle written before M3a
- [ ] `snitt record mark <session> --label "x"` returns the offset, and the marker appears
      in `events.json` with `"kind": "marker"`
- [ ] ⌥⌘M during a recording adds a marker; ⌥⌘5 still starts/stops and does **not** also
      add one — the hotkey-routing fix
- [ ] Starting a recording brings the target's application forward; holding Shift while
      pressing ⌥⌘5 does not
- [ ] `snitt-mcp` advertises five tools including `snitt_add_marker`
- [ ] A recording of a static window reports low `meanFrameVariance` and is **not** failed
      or warned about — §12.1's metrics are data, not a gate

## What M3a deliberately does not build

Event logging and its Input Monitoring grant, `--auto-trim`, WebVTT chapters, `--max-size`,
and `snitt inspect` + export manifest are **M3b**. The EDL and timeline are M4.
`--auto-trim-gaps` remains unscheduled pending the v0 gate.

**Three limitations to carry forward rather than discover:**

1. **Auto-focus raises the application, not the window** (Task 5). Fronting one window
   among several needs `AXUIElement` and therefore Accessibility, which M3a may not add.
2. **Hotkey recordings have no git context** (Task 7). Only the client knows which
   repository a recording is about, and pressing a key has no client. This is correct, not
   a gap — but it means the bundle-naming improvement is agent-only for now.
3. **Health thresholds are deliberately absent** (Task 6). §12.1 requires tuning against
   real recordings before any number is allowed to gate anything, so M3a reports and says
   nothing.
