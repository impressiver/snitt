# M5a — Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When someone says "the recording is broken", there is something to look at — structured logs with distinguishable error categories, an audit trail for every agent session, and `snitt diagnostics export` producing one file a support thread can read.

**Architecture:** One logging module owns the subsystem-per-target convention and the §12 error categories, so a category is a value rather than a string typed at each call site. The audit trail is a pure, testable record written on the same paths that already write bundles. Diagnostics is assembled **in the app** and returned over the socket, because `OSLogStore` only reads the calling process (spike S8).

**Tech Stack:** Swift 6, `OSLog`/`OSLogStore`, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §12 (logging and diagnostics), §4.9 (the thin client), §5.3 and §4.8 (agent sessions), §11 (error handling).

**Spike:** `docs/superpowers/spikes/S8-log-readback.md` — read it. It decides where diagnostics runs.

**Scope note.** §13's M5 is "Packaging: notarization, Sparkle, diagnostics (§12)". This plan is **diagnostics only** — everything testable in this repo without external credentials. Notarization and Sparkle are **M5b**: they need an Apple Developer account, a signing identity beyond the existing one, and a decision about where updates are hosted. Those are the user's to provide, and guessing at them would produce scripts nobody can run.

## Global Constraints

- Swift 6, strict concurrency, **zero warnings from `Sources/`** under `swift build -Xswiftc -strict-concurrency=complete`. Verify from a **clean** build.
- macOS 15 minimum (§4.6).
- `SnittDocument` imports only Foundation. `SnittExport` → `SnittDocument` only. **`SnittAutomation` never → `SnittExport`**, and `snitt-cli`/`snitt-mcp` must not link AVFoundation or ScreenCaptureKit (§4.9) — verify with `otool -L`.
- **Baseline: 413 tests** at `7de9b4a` from a full unfiltered run on a clean build.
- **Never block a thread from an async context** — no `DispatchSemaphore.wait()`, no `group.wait()`, no `sleep` as synchronisation.
- Every test names a plausible wrong implementation and is verified to fail against it.

## Verification traps — every one of these has bitten this project

- **`swift test` exits 0 when the test bundle segfaults.** The crash is one inline `error: … signal code 11` line among hundreds of passing ones, and the run has **no summary line**. Verify with `swift test 2>&1 | grep -E "Test run with|signal code|error:"` and **treat a missing summary as failure**.
- Piping to `grep` returns grep's exit status, so exit codes prove nothing.
- `.serialized` serialises **within** a suite, not across suites.
- **When mutating to check a test discriminates: assert the target string was found before writing, and grep the mutated file before running.** A mutation that does not fail is as likely to be a bad mutation as a bad test.
- **A test proving a rule correct proves nothing about whether it is installed.** If a fix belongs at a call site, the discriminating test must live at that call site — M4b shipped a threshold whose arithmetic was pinned while its wiring was free, and all 401 tests passed against the ruled-wrong constant.

## Spike results — measured, do not re-derive

1. `OSLogStore(scope: .currentProcessIdentifier)` works with **no entitlement**. Entries expose `subsystem`, `category`, `level`, `composedMessage`.
2. `position(date:)` + `getEntries(at:)` gives the time-bounded window "recent logs" needs.
3. **That scope sees only the calling process.** `snitt diagnostics export` runs in the CLI, so a CLI-side implementation would bundle the CLI's own log lines and none of the app's — a feature that looks like it works and contains nothing useful. **Diagnostics is assembled in the app and returned over the socket.**
4. `OSLogStore(scope: .system)` also succeeded, from a developer-launched test binary. **Do not build on it** — a notarized, sandboxed or hardened-runtime app is a different security context, and filtering the whole system log for our own entries is more work than reading our own process.

## File structure

| File | Responsibility |
|---|---|
| `Sources/SnittDocument/DiagnosticCategory.swift` (new) | The §12 error categories as a type. Pure, no OSLog. |
| `Sources/SnittDocument/AuditRecord.swift` (new) | One agent session's audit entry, and its JSONL store. Pure. |
| `Sources/SnittCapture/SnittLog.swift` (new) | Subsystem-per-target loggers and the category convention. |
| `Sources/SnittApp/DiagnosticsBundle.swift` (new) | Reads recent logs, versions, permission states, recent sessions; writes one file. |
| `Sources/SnittApp/AutomationHost.swift` (modify) | Handle `.diagnostics`; write an audit record on agent session start and stop. |
| `Sources/SnittAutomation/Protocol.swift` (modify) | `.diagnostics(outputPath:)` request and `.diagnosticsWritten` response. |
| `Sources/SnittAutomation/CommandLineParser.swift` (modify) | `snitt diagnostics export --out PATH`. |
| `Sources/SnittAutomation/MCPBridge.swift` (modify) | The matching MCP tool. |

---

### Task 1: Error categories as a type

**Files:**
- Create: `Sources/SnittDocument/DiagnosticCategory.swift`
- Test: `Tests/SnittDocumentTests/DiagnosticCategoryTests.swift`

**Interfaces:**
- Produces: `public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable { case permission, disk, capture, compositor, automation }` plus `public var isUserActionable: Bool`.

**Why.** §12: *"Error categories are distinguishable in logs: permission fault vs disk fault vs compositor fault. 'It failed' is not a diagnosable report."* A category typed as a raw string at each call site drifts — `"permission"`, `"permissions"`, `"perm"` — and a support engineer greps for the one spelling nobody used. As a type, the compiler enumerates them and `CaseIterable` lets a test assert the set.

`isUserActionable` distinguishes "the user can fix this" (permission denied, disk full) from "report this to us" (compositor fault). §11 already makes that distinction operationally; naming it here keeps the two consistent.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Every category has a stable wire name")
func categoriesHaveStableNames() {
    // These strings end up in exported diagnostics that a human greps.
    // Renaming one silently breaks every saved bundle and every runbook
    // that mentions it, so the mapping is pinned here deliberately.
    #expect(DiagnosticCategory.permission.rawValue == "permission")
    #expect(DiagnosticCategory.disk.rawValue == "disk")
    #expect(DiagnosticCategory.capture.rawValue == "capture")
    #expect(DiagnosticCategory.compositor.rawValue == "compositor")
    #expect(DiagnosticCategory.automation.rawValue == "automation")
}

@Test("§12's three named faults all exist")
func specNamedFaultsExist() {
    // §12 names permission, disk and compositor explicitly. If a future
    // edit removes one, this fails rather than the omission being noticed
    // when someone needs the category during an incident.
    let names = Set(DiagnosticCategory.allCases.map(\.rawValue))
    #expect(names.isSuperset(of: ["permission", "disk", "compositor"]))
}

@Test("User-actionable faults are separated from ones to report")
func actionabilityIsSplit() {
    // A permission denial is something the user fixes in System Settings;
    // a compositor fault is something they can only report. Telling a user
    // to fix the second, or silently swallowing the first, are both bad.
    #expect(DiagnosticCategory.permission.isUserActionable)
    #expect(DiagnosticCategory.disk.isUserActionable)
    #expect(!DiagnosticCategory.compositor.isUserActionable)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DiagnosticCategory`
Expected: FAIL — `cannot find 'DiagnosticCategory' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// §12's error categories, as a type rather than a string typed at each
/// call site.
///
/// "Error categories are distinguishable in logs: permission fault vs disk
/// fault vs compositor fault. 'It failed' is not a diagnosable report."
/// Spelled by hand at each site, these drift — `permission`, `permissions`,
/// `perm` — and a support engineer greps for the one spelling nobody used.
///
/// The raw values reach exported diagnostics that humans read and grep, so
/// they are a wire format: renaming one breaks every bundle already saved
/// and every runbook that mentions it.
public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable {
    case permission
    case disk
    case capture
    case compositor
    case automation

    /// Whether the person in front of the machine can do something about
    /// it. A permission denial has a System Settings pane; a compositor
    /// fault has only a bug report. §11 already draws this line
    /// operationally — naming it keeps the two consistent.
    public var isUserActionable: Bool {
        switch self {
        case .permission, .disk: return true
        case .capture, .compositor, .automation: return false
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 416.

- [ ] **Step 5: Verify the tests discriminate**

Change one raw value (say `disk` to `diskFault`) and confirm `categoriesHaveStableNames` fails. Make `isUserActionable` return `true` for every case and confirm `actionabilityIsSplit` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittDocument/DiagnosticCategory.swift Tests/SnittDocumentTests/DiagnosticCategoryTests.swift
git commit -m "feat(diagnostics): error categories as a type, not a string per call site"
```

---

### Task 2: The agent audit trail

**Files:**
- Create: `Sources/SnittDocument/AuditRecord.swift`
- Test: `Tests/SnittDocumentTests/AuditRecordTests.swift`

**Interfaces:**
- Consumes: `DiagnosticCategory`.
- Produces:
```swift
public struct AuditRecord: Codable, Sendable, Equatable {
    public let sessionID: String
    public let target: String
    public let initiator: String
    public let startedAt: Date
    public var endedAt: Date?
    public var outcome: String?
    public var durationSeconds: Double? { get }
}
public struct AuditLog {
    public static func append(_ record: AuditRecord, to url: URL) throws
    public static func read(from url: URL) throws -> [AuditRecord]
    public static func recent(_ count: Int, from url: URL) throws -> [AuditRecord]
}
```

**Why.** §12: *"Every agent-initiated session is audit-logged — session id, target, duration, initiator, outcome — so an agent-side incident can be reconstructed even though no human watched it happen. This serves §5 as much as it serves support."*

That last sentence is the point. §5.3's whole premise is that agent recordings happen with nobody present; the audit trail is how anyone reconstructs what a background process recorded and why.

**JSONL, one record per line, appended.** A single JSON array would need rewriting on every append and would be corrupted by a crash mid-write — precisely when the audit matters most. A truncated final line in JSONL costs one record, not the file.

**A malformed line must not lose the whole log.** This project has fixed the same swallow-vs-fail confusion four times: `read` should skip an unparseable line and keep the rest, but it must not silently return an empty array for an unreadable *file*. Distinguish absent (no sessions yet — legitimate) from unreadable (a real fault).

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A session round-trips through the log")
func recordRoundTrips() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let record = AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                             startedAt: Date(timeIntervalSince1970: 1000))
    try AuditLog.append(record, to: url)

    let read = try AuditLog.read(from: url)
    #expect(read.count == 1)
    #expect(read[0].sessionID == "S1")
    #expect(read[0].target == "Safari")
    #expect(read[0].initiator == "agent")
}

@Test("Appending does not rewrite earlier records")
func appendIsIncremental() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    for i in 1...3 {
        try AuditLog.append(AuditRecord(sessionID: "S\(i)", target: "T", initiator: "agent",
                                        startedAt: Date(timeIntervalSince1970: Double(i))), to: url)
    }
    // Discriminating against an implementation that decodes the whole file,
    // appends in memory and rewrites: that also passes a round-trip test,
    // and loses everything if the process dies mid-write.
    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 3)
    #expect(try AuditLog.read(from: url).map(\.sessionID) == ["S1", "S2", "S3"])
}

@Test("A truncated final line costs one record, not the log")
func truncatedLineLosesOnlyItself() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "T", initiator: "agent",
                                    startedAt: Date()), to: url)
    // Simulate a crash mid-append.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"sessionID":"S2","tar"#.utf8))
    try handle.close()

    // The whole point of JSONL: the audit matters most exactly when the
    // process died, so one bad line must not take the file with it.
    let read = try AuditLog.read(from: url)
    #expect(read.count == 1)
    #expect(read[0].sessionID == "S1")
}

@Test("No log yet is not an error, but an unreadable one is")
func absentAndUnreadableDiffer() throws {
    let missing = tempURL()
    // A machine that has never run an agent session has no log. That is
    // normal and must not fail an export.
    #expect(try AuditLog.read(from: missing).isEmpty)

    let unreadable = tempURL()
    defer { try? FileManager.default.removeItem(at: unreadable) }
    try Data([0xFF, 0xFE, 0xFD]).write(to: unreadable)
    // Invalid UTF-8 is a real fault. Returning [] here would report "no
    // agent sessions" for a machine that has run hundreds — the confidently
    // wrong answer §8 exists to prevent, in a new place.
    #expect(throws: (any Error).self) { _ = try AuditLog.read(from: unreadable) }
}

@Test("Duration comes from the two timestamps, and is nil while running")
func durationDerivesFromTimestamps() {
    var record = AuditRecord(sessionID: "S1", target: "T", initiator: "agent",
                             startedAt: Date(timeIntervalSince1970: 100))
    // A session still running has no duration. Reporting 0 would read as
    // "finished instantly" in an incident review.
    #expect(record.durationSeconds == nil)
    record.endedAt = Date(timeIntervalSince1970: 142)
    #expect(record.durationSeconds == 42)
}

@Test("Only the most recent N are returned, newest last")
func recentReturnsTheTail() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    for i in 1...5 {
        try AuditLog.append(AuditRecord(sessionID: "S\(i)", target: "T", initiator: "agent",
                                        startedAt: Date(timeIntervalSince1970: Double(i))), to: url)
    }
    // A diagnostics bundle wants the recent tail, not a year of history.
    // Discriminating against an implementation returning the first N.
    #expect(try AuditLog.recent(2, from: url).map(\.sessionID) == ["S4", "S5"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AuditRecord`
Expected: FAIL — `cannot find 'AuditRecord' in scope`.

- [ ] **Step 3: Implement**

JSONL with an appending `FileHandle`, creating the file when absent. `read` returns `[]` for a missing file, throws for an unreadable one, and skips lines that fail to decode. `durationSeconds` is `endedAt.map { $0.timeIntervalSince(startedAt) }`.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 422.

- [ ] **Step 5: Verify the tests discriminate**

Rewrite the whole file on append and confirm `appendIsIncremental` still passes but `truncatedLineLosesOnlyItself` fails — then explain in your report which property each test actually pins. Make `read` return `[]` on any error and confirm `absentAndUnreadableDiffer` fails. Return the first N from `recent` and confirm `recentReturnsTheTail` fails. Restore each.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittDocument/AuditRecord.swift Tests/SnittDocumentTests/AuditRecordTests.swift
git commit -m "feat(diagnostics): an append-only audit trail for agent sessions"
```

---

### Task 3: Subsystem-per-target logging

**Files:**
- Create: `Sources/SnittCapture/SnittLog.swift`
- Modify: `Sources/SnittCapture/Recorder.swift`, `Sources/SnittApp/RecordingCoordinator.swift`
- Test: `Tests/SnittCaptureTests/SnittLogTests.swift`

**Interfaces:**
- Consumes: `DiagnosticCategory`.
- Produces: `public enum SnittLog { public static func logger(_ category: DiagnosticCategory, target: String) -> Logger; public static let subsystem = "com.impressiver.snitt" }`.

**Why.** §12 asks for *"structured `os_log` logging per module, with a subsystem per target"*. Today exactly two files construct a `Logger`, both with the subsystem spelled by hand. Every other module logs nothing at all, so an incident in export or automation leaves no trace.

Spike S8 measured that `OSLogStore` exposes `subsystem` and `category`, so those two fields are what a diagnostics bundle filters on — which makes them a contract, not decoration.

**Do not convert every call site in this task.** Introduce the module, move the two existing loggers onto it, and let later tasks adopt it where they add logging. A sweeping mechanical edit across every file would bury the interesting part of this diff.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Loggers carry the target as subsystem suffix and the category")
func loggerNamesAreStructured() {
    // These two fields are what a diagnostics bundle FILTERS on (S8), so
    // they are a contract rather than cosmetics.
    #expect(SnittLog.subsystemName(for: "SnittCapture") == "com.impressiver.snitt.SnittCapture")
    #expect(SnittLog.subsystemName(for: "SnittExport") == "com.impressiver.snitt.SnittExport")
}

@Test("Every subsystem shares the prefix a diagnostics filter matches")
func subsystemsSharePrefix() {
    // DiagnosticsBundle selects entries by prefix; a target that invented
    // its own root would vanish from every exported bundle while looking
    // fine in the console.
    for target in ["SnittCapture", "SnittExport", "SnittApp", "SnittAutomation"] {
        #expect(SnittLog.subsystemName(for: target).hasPrefix(SnittLog.subsystem))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SnittLog`
Expected: FAIL — `cannot find 'SnittLog' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import OSLog
import SnittDocument

/// The one place that knows how Snitt names its loggers.
///
/// §12 asks for a subsystem per target and distinguishable error
/// categories. Spike S8 measured that `OSLogStore` exposes exactly
/// `subsystem` and `category`, which is what a diagnostics bundle filters
/// on — so these names are a wire contract, not cosmetics. A module that
/// invents its own root vanishes from every exported bundle while still
/// looking correct in the console.
public enum SnittLog {
    public static let subsystem = "com.impressiver.snitt"

    public static func subsystemName(for target: String) -> String {
        "\(subsystem).\(target)"
    }

    public static func logger(_ category: DiagnosticCategory, target: String) -> Logger {
        Logger(subsystem: subsystemName(for: target), category: category.rawValue)
    }
}
```

Then move `Recorder`'s and `RecordingCoordinator`'s existing loggers onto it, keeping their current categories' meaning.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 424.

- [ ] **Step 5: Verify the tests discriminate**

Change `subsystemName` to return the bare target and confirm both tests fail. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittCapture/SnittLog.swift Sources/SnittCapture/Recorder.swift Sources/SnittApp/RecordingCoordinator.swift Tests/SnittCaptureTests/SnittLogTests.swift
git commit -m "feat(diagnostics): one place that names Snitt's loggers"
```

---

### Task 4: The diagnostics bundle

**Files:**
- Create: `Sources/SnittApp/DiagnosticsBundle.swift`
- Test: `Tests/SnittAppTests/DiagnosticsBundleTests.swift`

**Interfaces:**
- Consumes: `SnittLog`, `AuditLog`, `DiagnosticCategory`.
- Produces:
```swift
public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public let appVersion: String
    public let protocolVersion: Int
    public let generatedAt: Date
    public let permissions: [String: String]
    public let recentSessions: [AuditRecord]
    public let logLines: [String]
}
@MainActor public enum DiagnosticsBundle {
    public static func write(to url: URL, auditLogURL: URL, sinceMinutes: Int) throws -> DiagnosticsReport
}
```

**Why it runs in the app.** Spike S8: `OSLogStore(scope: .currentProcessIdentifier)` reads **only the calling process**. A CLI-side implementation would bundle the CLI's own handful of lines and none of the app's — a feature that looks like it works and contains nothing. This is the same thin-client rule §4.9 states for capture, arriving for a different reason: there TCC, here process scope.

**What it must contain**, per §12: recent logs, app and CLI versions, permission states, recent session metadata.

**What it must not contain.** §5's privacy framing applies: this file gets attached to support threads. It must carry **no window titles, no file contents, no keystroke or click detail**. Log lines are already redacted by `os_log` privacy rules unless marked `.public` — say in the doc comment that anything logged `.public` will end up in a support bundle, because that is the decision point a future call site needs to know about.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test("The report carries versions, permissions and recent sessions")
func reportHasTheSpecifiedSections() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                                    startedAt: Date()), to: auditURL)
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }

    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    #expect(!report.appVersion.isEmpty)
    #expect(report.protocolVersion > 0)
    #expect(report.recentSessions.count == 1)
    #expect(report.recentSessions[0].sessionID == "S1")
    #expect(!report.permissions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@MainActor
@Test("The bundle captures log lines this process just wrote")
func bundleCapturesOurOwnLogs() throws {
    let marker = UUID().uuidString
    SnittLog.logger(.automation, target: "SnittApp")
        .error("diagnostics probe \(marker, privacy: .public)")

    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    // The discriminating assertion. An implementation that writes versions
    // and permissions but no logs passes every other test here, and is
    // exactly the "looks like it works, contains nothing useful" outcome
    // S8 warns about.
    #expect(report.logLines.contains { $0.contains(marker) })
}

@MainActor
@Test("A machine with no agent sessions still exports")
func noSessionsStillExports() throws {
    let auditURL = tempURL()   // never created
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    // Support bundles are requested most often by people who have never run
    // an agent session. Failing here would deny diagnostics to exactly the
    // users most likely to need them.
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)
    #expect(report.recentSessions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@MainActor
@Test("The written file is the report, and parses back")
func writtenFileParsesBack() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    // A support engineer has to read this. A file that exists but is not
    // parseable is a worse outcome than no file, because it looks like
    // evidence.
    let decoded = try JSONDecoder().decode(DiagnosticsReport.self,
                                           from: Data(contentsOf: out))
    #expect(decoded.appVersion == report.appVersion)
    #expect(decoded.recentSessions.count == report.recentSessions.count)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DiagnosticsBundle`
Expected: FAIL — `cannot find 'DiagnosticsBundle' in scope`.

- [ ] **Step 3: Implement**

Read logs via `OSLogStore(scope: .currentProcessIdentifier)`, `position(date:)` at `now - sinceMinutes`, keeping entries whose `subsystem` has `SnittLog.subsystem` as a prefix, formatted as `"[subsystem/category] message"`. Permission states come from the existing preflight readers (`ScreenRecordingAccess`, `InputMonitoringAccess`) — **read them, never request**, since a support export must not raise a system prompt. Encode `DiagnosticsReport` as pretty JSON.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 428.

- [ ] **Step 5: Verify the tests discriminate**

Return an empty `logLines` array and confirm `bundleCapturesOurOwnLogs` fails while the others pass — that asymmetry is the point. Make the audit read throw on a missing file and confirm `noSessionsStillExports` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp/DiagnosticsBundle.swift Tests/SnittAppTests/DiagnosticsBundleTests.swift
git commit -m "feat(diagnostics): assemble the support bundle in the app"
```

---

### Task 5: Write the audit trail on the paths that already exist

**Files:**
- Modify: `Sources/SnittApp/AutomationHost.swift`
- Test: `Tests/SnittAppTests/AutomationHostTests.swift`

**Interfaces:**
- Consumes: `AuditRecord`, `AuditLog`.
- Produces: no new public API — agent session start and stop now append audit records.

**Why.** §12 requires *every* agent-initiated session to be audit-logged with session id, target, duration, initiator and outcome. §5.3's premise is that these happen unobserved.

**Only agent sessions.** A human recording is watched by the person making it; §12 scopes the audit to agent-initiated work, and logging every human recording would bury the agent entries the audit exists to surface.

**Outcome must distinguish how a session ended**: completed normally, stopped by the max-duration cap, or failed. A cap-terminated session and a clean stop look identical in a bundle that records only "ended", and the cap is §5's safety mechanism — the one thing an incident review most needs to see.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("An agent session is audited from start to stop")
func agentSessionIsAudited() async throws { /* start, stop, read the log, assert one record with both timestamps, the target, initiator "agent", and a duration */ }

@Test("A human recording writes no audit record")
func humanRecordingIsNotAudited() async throws { /* §12 scopes this to agent sessions; auditing every human recording buries the ones that matter */ }

@Test("A capped session records that the cap ended it")
func cappedSessionRecordsTheCap() async throws {
    // The max-duration cap is §5's safety mechanism for an orphaned agent
    // session. A bundle that records only "ended" makes a cap-terminated
    // session indistinguishable from a clean stop — which is the single
    // fact an incident review most needs.
}
```

Fill these in against the real host; `AutomationHostTests` already has a `ManualClock`/`ManualWatchdog` harness from the M4b watchdog fix — use it rather than racing wall-clock time.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "agentSessionIsAudited|humanRecordingIsNotAudited|cappedSessionRecordsTheCap"`
Expected: FAIL — nothing writes audit records.

- [ ] **Step 3: Implement**

Append on agent session start; update the record's `endedAt` and `outcome` on stop. Since JSONL is append-only, "update" means appending a second record keyed by the same `sessionID` — say which shape you chose and why, and make sure `AuditLog.recent` still reads sensibly with it.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run at least 3 times; expect 431.

- [ ] **Step 5: Verify the tests discriminate**

Audit human recordings too and confirm `humanRecordingIsNotAudited` fails. Record a single generic outcome and confirm `cappedSessionRecordsTheCap` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp/AutomationHost.swift Tests/SnittAppTests/AutomationHostTests.swift
git commit -m "feat(diagnostics): audit every agent session, including how it ended"
```

---

### Task 6: `snitt diagnostics export`

**Files:**
- Modify: `Sources/SnittAutomation/Protocol.swift`, `CommandLineParser.swift`, `MCPBridge.swift`
- Modify: `Sources/SnittApp/AutomationHost.swift`, `Sources/snitt-cli/main.swift`
- Test: `Tests/SnittAutomationTests/CommandLineParserTests.swift`, `MCPBridgeTests.swift`, `Tests/SnittAppTests/AutomationHostTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsBundle`.
- Produces: `AutomationRequest.Body.diagnostics(outputPath: String)` and `AutomationResponse.diagnosticsWritten(DiagnosticsReport)`.

**Why the app does the work.** §4.9 and spike S8. The CLI resolves the path and asks; the app assembles and writes. `snitt-cli` and `snitt-mcp` must still link neither AVFoundation nor ScreenCaptureKit — verify with `otool -L`, not only the import-scanning test, which has been defeated three times in this project.

**Path handling.** `PathResolver.resolve` already exists and is tested — relative paths must be resolved **in the CLI**, against the caller's working directory, because the app's is different. That was M3c's finding #3.

**Protocol amendment.** `Protocol.swift` is v2 and has never shipped, so amend in place — but read the file's own version rules before editing rather than trusting this line.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("The CLI parses diagnostics export and carries the resolved path")
func diagnosticsExportParses() { /* assert the request body carries the value, not merely that parsing succeeded — M3c's trap */ }

@Test("A relative --out is resolved before it is sent")
func relativeOutIsResolved() { /* the app's working directory is not the caller's */ }

@Test("The MCP tool maps to the same request")
func mcpDiagnosticsMapsToTheSameRequest() { /* fixtures decoded from real JSON text, as MCPBridgeTests does throughout */ }

@Test("The host writes the file and returns the report")
func hostWritesDiagnostics() async throws { /* drive AutomationHost directly */ }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "diagnostics|Diagnostics"`
Expected: FAIL — no such command.

- [ ] **Step 3: Implement**

Add the protocol case, the CLI subcommand with `--out`, the MCP tool with its schema, and the host handler calling `DiagnosticsBundle.write`. Render the response so a human sees where the file went and roughly what is in it.

- [ ] **Step 4: Run to verify it passes**

`rm -rf .build`, then a full unfiltered run at least 3 times; expect 435. Then:

```bash
otool -L .build/debug/snitt-cli | grep -ciE "AVFoundation|ScreenCaptureKit|CoreMedia"   # expect 0
otool -L .build/debug/snitt-mcp | grep -ciE "AVFoundation|ScreenCaptureKit|CoreMedia"   # expect 0
```

and drive the real `snitt-mcp` over stdio with the new tool, pasting the observed output into your report. A green suite is not sufficient evidence for the frontends — M3c shipped two frontend bugs that only the running binary revealed.

- [ ] **Step 5: Verify the tests discriminate**

Send the raw `--out` without resolving and confirm `relativeOutIsResolved` fails. Return a success response without writing the file and confirm `hostWritesDiagnostics` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat(diagnostics): snitt diagnostics export, assembled in the app"
```

---

## Self-review

**Spec coverage.** §12's five bullets: structured `os_log` per module with a subsystem per target (Task 3); `snitt diagnostics export` bundling logs, versions, permission states and recent sessions (Tasks 4, 6); every agent session audit-logged with id, target, duration, initiator, outcome (Tasks 2, 5); error categories distinguishable (Task 1). §12.1's capture health shipped in M3.

**Deliberately excluded, and why:**

- **Opt-in crash reporting** (§12's third bullet). It needs a crash reporter, a server to receive reports, and a privacy decision about what leaves the machine — none of which exist yet, and the last is the user's call, not mine. The settings toggle without a reporter behind it would be a lie in the UI.
- **Notarization and Sparkle** — M5b. They require an Apple Developer account, a signing identity, and a hosting decision. Scripts written against guessed credentials cannot be run or verified, and this project's record is that unverifiable work ships broken.

**Known gaps a reviewer should weigh rather than assume:**

- **The audit "update on stop" shape is unresolved.** JSONL is append-only, so recording an outcome means a second record with the same `sessionID`. Task 5 leaves the choice to the implementer — a reviewer should check `AuditLog.recent` still reads sensibly, and that a reader can tell an in-flight session from a completed one.
- **`sinceMinutes` has no tuned value.** Too short and an incident is already out of the window; too long and the bundle is enormous. Pick something defensible, and expect it to be wrong until real support threads say otherwise.
- **Nothing tests that the bundle omits sensitive content.** The doc comment states the rule (nothing logged `.public` that names a window, a path, or input detail), but no test enforces it, and a future `.public` interpolation would leak silently. A test asserting no bundle line matches a set of known-sensitive patterns is possible and is not in this plan — a reviewer should say whether it should be.
- **`OSLogStore(scope: .system)` worked in the spike.** It is deliberately unused. If someone later "fixes" diagnostics to use it because it captures more, they will have built on a capability a notarized app may not have.

**Type consistency.** `DiagnosticCategory` in Tasks 1, 3, 4. `AuditRecord`/`AuditLog` in Tasks 2, 4, 5. `SnittLog.subsystem` in Tasks 3, 4. `DiagnosticsReport` in Tasks 4, 6. `DiagnosticsBundle.write(to:auditLogURL:sinceMinutes:)` in Tasks 4, 6.

## Manual verification (Definition of Done)

1. Run an agent recording over the CLI, stop it, then `snitt diagnostics export --out ~/Desktop/d.json`. Confirm the file exists and contains that session.
2. Open it and read it as a support engineer would: are the versions, permission states and log lines actually useful, or is it structurally correct and substantively empty?
3. Confirm **no window titles, file paths, or input detail** appear anywhere in it.
4. Deny Screen Recording, attempt a recording, then export. Confirm the permission fault is visible and categorised as `permission`.
5. Let an agent session hit the max-duration cap. Confirm the audit record says the cap ended it, not merely that it ended.
