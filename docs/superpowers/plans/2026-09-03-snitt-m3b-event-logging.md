# Snitt M3b: Event Logging and Inspection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Log *that* input happened during a recording — never *what* — and let an agent read back what it captured without a GUI.

**Architecture:** A `CGEventTap` on its own run-loop thread feeds timestamped events into the same sidecar log markers already use, on the same media clock. Event logging is off by default and costs the third TCC dialog, so it is requested at first use behind a pre-explain sheet. `snitt inspect` goes **over the socket** — the app reads the bundle, because the CLI cannot.

**Tech Stack:** Swift 6, SPM, CoreGraphics event taps, CFRunLoop, AVFoundation.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md`

**Scope:** M3b only. `snitt trim`, `--auto-trim`, `snitt export` (formats, `--scale`, `--max-size`, `--chapters`), the export manifest and WebVTT chapters are **M3c** — they need an export pipeline that does not exist yet (`SnittExport` today contains only `ClipboardDestination`). Overlay *rendering* stays deferred past v0 and gated on M6 (§4.2, §13).

**Branch:** `feat/m3b-events-and-export`, stacked on `feat/m3a-capture-context` (PR #3, unmerged).

## Global Constraints

Copied from the spec. Every task's requirements implicitly include these.

- **Events are logged, never drawn.** Rendering is deferred past v0 and gated on evidence. The sidecar split is what makes that possible: events recorded today can be drawn by a renderer written a year from now. (§4.2, §4.5)
- **Log timing and kind ONLY — never key identity, never click coordinates.** See the ruling below; this is the single most important constraint in this plan.
- **§4.10's ladder is 1 dialog for screen + system audio, 2 with voiceover, 3 with keystroke capture.** M3b adds the third rung and no more. **Nothing is requested at launch** — each permission is requested at first use of the feature that needs it, behind a pre-explain sheet.
- **`CGEventTap`, not `NSEvent`.** Spike S1 measured global `NSEvent` keyDown at **zero even with Input Monitoring granted**, because AppKit global key monitors are gated by **Accessibility** — a broader grant. `CGEventTap` uses Input Monitoring (`kTCCServiceListenEvent`). Do not switch APIs.
- **The CLI must never call ScreenCaptureKit**, and — new in this plan — **must not read bundles off disk**. A conformance test enforces the first; the second is a lesson, see Task 5.
- **An agent must never block on a dialog it cannot see.** (§11)
- Swift 6, strict concurrency, **zero source warnings**. macOS 15 minimum.
- 203 tests pass at the branch point. Every task keeps them passing.

## THE RULING THIS PLAN ENCODES: log the fact, not the content

`LoggedEvent` carries `timeSeconds`, `kind`, `label`. **It has no field for a key code or a click position, and this plan does not add one.**

Three reasons, in order of weight:

1. **The spec's own precedent.** §5.1 makes window-scoping the universal default *because* a "Mail Password Required" notification appeared in frame during a routine M1 recording — and concludes "Snitt's users are precisely the people with customer data and staging credentials on screen." Writing actual keystrokes into `events.json` is strictly worse than that leak: it is plaintext, it travels with the bundle, and it survives every share. A user recording a demo who types a password would ship it to Slack.
2. **The only current consumer needs timing alone.** `--auto-trim` (M3c) clips dead air before the first and after the last logged event. It never asks which key.
3. **The consumer that would need more may never exist.** Overlay rendering is M7, conditional on M6's desirability probe. Building a keylog now for a feature that may not ship is exactly the speculative generality this project's plan-refinement pass exists to remove.

If overlays ship and need key identity or click position, that is a **separate, deliberate decision** with its own privacy design — not something inherited by default from a milestone that had no use for it.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SnittCapture/SessionEventLog.swift` | Renamed from `MarkerLog`; now holds markers **and** input events |
| `Sources/SnittCapture/InputMonitoringAccess.swift` | Preflight + request for Input Monitoring, mirroring `ScreenRecordingAccess` |
| `Sources/SnittCapture/InputEventMonitor.swift` | The `CGEventTap`, on its own run-loop thread |
| `Sources/SnittApp/EventLoggingSettings.swift` | The opt-in, persisted, default off |
| `Sources/SnittAutomation/InspectReport.swift` | What `snitt inspect` returns |
| `Sources/snitt-cli/main.swift` | `snitt inspect <bundle>` |

**Why `MarkerLog` gets renamed:** once it holds clicks and keystrokes, the name is actively misleading — a future reader looking for "where input events are stored" would not find it. The rename is small and it is the last cheap moment to do it.

---

## Task 1: Generalise the event log to hold input events

**Files:**
- Rename: `Sources/SnittCapture/MarkerLog.swift` → `Sources/SnittCapture/SessionEventLog.swift`
- Modify: `Sources/SnittCapture/Recorder.swift`
- Rename: `Tests/SnittCaptureTests/MarkerLogTests.swift` → `Tests/SnittCaptureTests/SessionEventLogTests.swift`

**Interfaces:**
- Consumes: `LoggedEvent`, `EventKind` (existing: `.click`, `.keystroke`, `.marker`)
- Produces:
  - `public actor SessionEventLog`
  - `public func add(at timeSeconds: Double, kind: EventKind, label: String?)`
  - `public func snapshot() -> [LoggedEvent]`
  - `public func counts() -> (markers: Int, inputEvents: Int)`

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/SessionEventLogTests.swift` (delete the old `MarkerLogTests.swift`):

```swift
import Testing
import Foundation
@testable import SnittCapture
import SnittDocument

@Test("Markers and input events accumulate in one log, in arrival order")
func markersAndEventsShareOneLog() async {
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "start")
    await log.add(at: 2.0, kind: .keystroke, label: nil)
    await log.add(at: 3.0, kind: .click, label: nil)

    let events = await log.snapshot()
    #expect(events.map(\.kind) == [.marker, .keystroke, .click])
    #expect(events.map(\.timeSeconds) == [1.0, 2.0, 3.0])
}

@Test("Input events never carry a label")
func inputEventsCarryNoLabel() async {
    // The ruling: log the FACT of input, never its content. A label on a
    // keystroke is where a key name would end up, and events.json travels
    // with the bundle in plaintext (§5.1's password-notification argument).
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .keystroke, label: "should be dropped")
    await log.add(at: 2.0, kind: .click, label: "also dropped")

    let events = await log.snapshot()
    #expect(events.allSatisfy { $0.label == nil },
            "an input event must never carry content, even if a caller passes some")
}

@Test("Markers keep their labels")
func markersKeepLabels() async {
    // A marker's label is authored by a human or an agent describing its own
    // action — deliberate, not captured. It stays.
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "ran the tests")
    #expect(await log.snapshot().first?.label == "ran the tests")
}

@Test("Counts separate markers from input events")
func countsSeparateKinds() async {
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "a")
    await log.add(at: 2.0, kind: .keystroke, label: nil)
    await log.add(at: 3.0, kind: .click, label: nil)

    let counts = await log.counts()
    #expect(counts.markers == 1)
    #expect(counts.inputEvents == 2)
}

@Test("A snapshot is a copy — later additions do not mutate it")
func snapshotIsACopy() async {
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "a")
    let first = await log.snapshot()
    await log.add(at: 2.0, kind: .click, label: nil)
    #expect(first.count == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionEventLogTests`
Expected: FAIL — `cannot find 'SessionEventLog' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/SessionEventLog.swift`, deleting `MarkerLog.swift`:

```swift
import Foundation
import SnittDocument

/// Everything timestamped that happens during a recording: markers a human or
/// agent deliberately drops (§4.12), and the fact that input occurred (§4.2).
///
/// An actor because entries arrive from the automation socket's connection
/// threads, from the main actor's hotkey, and from the event tap's own run-loop
/// thread, while the writer reads them at stop.
///
/// Renamed from `MarkerLog` when input events joined it — the old name would
/// have sent anyone looking for "where input events are stored" to the wrong
/// place.
public actor SessionEventLog {
    private var events: [LoggedEvent] = []

    public init() {}

    public func add(at timeSeconds: Double, kind: EventKind, label: String?) {
        // Input events are stripped of any label at the boundary rather than
        // trusting callers. A label is the only place key identity or click
        // content could reach the file, and events.json travels with the
        // bundle in plaintext — see this plan's ruling and §5.1.
        let safeLabel = (kind == .marker) ? label : nil
        events.append(LoggedEvent(timeSeconds: timeSeconds, kind: kind, label: safeLabel))
    }

    public func snapshot() -> [LoggedEvent] { events }

    public func counts() -> (markers: Int, inputEvents: Int) {
        let markers = events.filter { $0.kind == .marker }.count
        return (markers: markers, inputEvents: events.count - markers)
    }
}
```

- [ ] **Step 4: Update the recorder**

In `Sources/SnittCapture/Recorder.swift`, rename the stored property and pass the kind:

```swift
    private let eventLog = SessionEventLog()
```

`mark(label:)`'s body becomes `await eventLog.add(at: offset, kind: .marker, label: label)`, and `stop()`'s snapshot line becomes `let collectedEvents = await eventLog.snapshot()`. Rename `writeSidecars`'s parameter from `collectedMarkers` to `collectedEvents` so the name stays honest.

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: PASS — 5 tests replace the previous 3, so 205 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittCapture Tests/SnittCaptureTests
git commit -m "refactor(capture): one session log for markers and input events

Input events are stripped of any label at the boundary rather than trusting
callers: a label is the only place key identity could reach events.json, which
travels with the bundle in plaintext. Renamed from MarkerLog because the old
name would have hidden where input events live."
```

---

## Task 2: Input Monitoring access

**Files:**
- Create: `Sources/SnittCapture/InputMonitoringAccess.swift`
- Create: `Tests/SnittCaptureTests/InputMonitoringAccessTests.swift`

**Interfaces:**
- Consumes: CoreGraphics
- Produces:
  - `public enum InputMonitoringAccess`
  - `public static func isGranted() -> Bool`
  - `@discardableResult public static func ensureGranted() -> Bool`

**This must mirror `ScreenRecordingAccess` exactly**, because the existing conformance guard already polices this service. `Tests/SnittCaptureTests/AccessConformanceTests.swift`'s `noPreflightWithoutRequest` scans for both `"ScreenCapture"` and **`"ListenEvent"`** — so a file that calls `CGPreflightListenEventAccess` without `CGRequestListenEventAccess` fails the build automatically. Verify that is true before you finish: it is the guard doing its job on a service that had no callers until now.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/InputMonitoringAccessTests.swift`:

```swift
import Testing
@testable import SnittCapture

@Test("Both TCC entry points live on this type, so the conformance guard is satisfiable")
func accessTypeExposesBothEntryPoints() {
    // The guard requires any file that PREFLIGHTS a service to also REQUEST it.
    // Keeping both here means no caller ever needs to touch CoreGraphics
    // directly — the same arrangement ScreenRecordingAccess uses.
    #expect(InputMonitoringAccess.isGranted() == InputMonitoringAccess.isGranted(),
            "isGranted must be a pure read with no side effect — calling it twice "
          + "must not prompt or change state")
}
```

Note this test is deliberately modest: `CGPreflightListenEventAccess` returns a machine-dependent value, so nothing can assert a specific result. What it *can* pin is that reading is side-effect free, which is the property that matters — a preflight that prompted would break §4.10's "nothing is requested at launch".

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InputMonitoringAccessTests`
Expected: FAIL — `cannot find 'InputMonitoringAccess' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/InputMonitoringAccess.swift`:

```swift
import CoreGraphics

/// The one place Snitt asks for Input Monitoring (§4.10's third rung).
///
/// Mirrors `ScreenRecordingAccess` deliberately: preflight READS the grant,
/// request RAISES the dialog. Code that only preflights silently measures
/// nothing — a mistake made three times in this project before each service
/// was given a single home and a conformance test.
///
/// Spike S1 established that this is the grant `CGEventTap` needs
/// (`kTCCServiceListenEvent`), and that `NSEvent.addGlobalMonitorForEvents`
/// is gated by **Accessibility** instead — a broader grant, and one users
/// refuse more often. S1 measured global NSEvent keyDown at ZERO even with
/// Input Monitoring granted, which is why this API is not optional.
///
/// As with Screen Recording, a request returns `false` the first time even
/// when the user grants it; the grant takes effect on the next launch.
public enum InputMonitoringAccess {
    /// Whether the grant is already held, without prompting.
    public static func isGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func ensureGranted() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter InputMonitoringAccessTests`
Expected: PASS — 206 total.

Run: `swift test --filter AccessConformance`
Expected: PASS — confirm the guard accepts this file. If it fails, the file is preflighting without requesting and the guard has caught you.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittCapture/InputMonitoringAccess.swift Tests/SnittCaptureTests/InputMonitoringAccessTests.swift
git commit -m "feat(capture): add Input Monitoring access, mirroring screen recording

Spike S1 established CGEventTap needs kTCCServiceListenEvent while NSEvent
global key monitors need Accessibility — it measured NSEvent keyDown at zero
even with Input Monitoring granted. The existing conformance guard already
scans for this service; this is its first caller."
```

---

## Task 3: The event tap

**Files:**
- Create: `Sources/SnittCapture/InputEventMonitor.swift`
- Create: `Tests/SnittCaptureTests/InputEventMonitorTests.swift`

**Interfaces:**
- Consumes: `EventKind`, `InputMonitoringAccess`
- Produces:
  - `public final class InputEventMonitor: @unchecked Sendable`
  - `public init(onEvent: @escaping @Sendable (EventKind) -> Void)`
  - `public func start() -> Bool` — false when the tap could not be created
  - `public func stop()`
  - `public static func kind(for type: CGEventType) -> EventKind?`

**Runs on its own thread, deliberately.** A `CGEventTap` needs a `CFRunLoop`. Attaching to the main run loop would couple capture to the app's UI thread and stall the tap whenever a modal sheet is up — which M3a proved is a real state. A dedicated thread keeps event capture independent of whatever the app is doing.

**Handle `tapDisabledByTimeout`.** macOS disables a tap that takes too long in its callback, and silently — the tap stops delivering and nothing says so. The callback must re-enable it. S1's probe did not cover this because it ran for 15 seconds; a recording runs for minutes.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittCaptureTests/InputEventMonitorTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SnittCapture
import SnittDocument

@Test("Key and mouse events map to the kinds the log stores")
func eventTypesMapToKinds() {
    #expect(InputEventMonitor.kind(for: .keyDown) == .keystroke)
    #expect(InputEventMonitor.kind(for: .leftMouseDown) == .click)
    #expect(InputEventMonitor.kind(for: .rightMouseDown) == .click)
}

@Test("Key UP is not logged — one keystroke must not count as two")
func keyUpIsIgnored() {
    // Down and up both arrive. Logging both would double every keystroke,
    // which matters because M3c's --auto-trim reasons about event density.
    #expect(InputEventMonitor.kind(for: .keyUp) == nil)
    #expect(InputEventMonitor.kind(for: .leftMouseUp) == nil)
}

@Test("Tap-disabled notifications are not logged as input")
func tapDisabledIsNotAnEvent() {
    // macOS sends these THROUGH the tap callback. Treating them as input
    // would put phantom events in the log at the moment the tap broke.
    #expect(InputEventMonitor.kind(for: .tapDisabledByTimeout) == nil)
    #expect(InputEventMonitor.kind(for: .tapDisabledByUserInput) == nil)
}

@Test("The event mask covers exactly the types that map to a kind")
func maskMatchesTheMappedTypes() {
    // A mask that requested types we then drop would wake the callback for
    // nothing on every keypress; a mask missing a mapped type would silently
    // never log it.
    let mapped: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
    for type in mapped {
        #expect(InputEventMonitor.eventMask & (1 << type.rawValue) != 0,
                "\(type) maps to a kind but is not in the mask")
    }
    let unmapped: [CGEventType] = [.keyUp, .leftMouseUp, .mouseMoved]
    for type in unmapped {
        #expect(InputEventMonitor.eventMask & (1 << type.rawValue) == 0,
                "\(type) is in the mask but maps to no kind")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InputEventMonitorTests`
Expected: FAIL — `cannot find 'InputEventMonitor' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SnittCapture/InputEventMonitor.swift`:

```swift
import CoreGraphics
import Foundation
import SnittDocument

/// Logs THAT input happened, never what (§4.2, and this milestone's ruling).
///
/// Uses `CGEventTap` in listen-only mode. Spike S1 established this is the API
/// gated by Input Monitoring; `NSEvent.addGlobalMonitorForEvents` needs
/// Accessibility and measured zero keyDown events even when Input Monitoring
/// was granted.
///
/// Runs its run loop on a dedicated thread rather than the main one: attaching
/// to the main run loop would stall event capture whenever the app shows a
/// modal sheet, which the permission-onboarding flow legitimately does.
public final class InputEventMonitor: @unchecked Sendable {
    /// The types worth waking the callback for. Kept in lockstep with
    /// `kind(for:)` — a mask wider than the mapping wakes us for nothing on
    /// every keypress, and a mask narrower than it silently drops events.
    public static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.leftMouseDown.rawValue)
      | (1 << CGEventType.rightMouseDown.rawValue)

    /// Nil for anything that must not become a log entry.
    ///
    /// Key UP is excluded so one keystroke is one event — M3c's `--auto-trim`
    /// reasons about event density. The tap-disabled notifications arrive
    /// through this same callback and are control messages, not input.
    public static func kind(for type: CGEventType) -> EventKind? {
        switch type {
        case .keyDown: return .keystroke
        case .leftMouseDown, .rightMouseDown: return .click
        default: return nil
        }
    }

    private let onEvent: @Sendable (EventKind) -> Void
    private var thread: Thread?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    public init(onEvent: @escaping @Sendable (EventKind) -> Void) {
        self.onEvent = onEvent
    }

    /// Returns false if the tap could not be created — which is what a missing
    /// Input Monitoring grant looks like from here.
    public func start() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputEventMonitor>
                .fromOpaque(userInfo).takeUnretainedValue()

            // macOS disables a tap whose callback runs long, and says so only
            // through this callback. Without re-enabling, the tap goes quiet
            // for the rest of the recording and nothing reports it.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            if let kind = InputEventMonitor.kind(for: type) {
                monitor.onEvent(kind)
            }
            // Listen-only: the event is always passed through untouched.
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false   // no Input Monitoring grant
        }
        self.tap = tap

        let thread = Thread { [weak self] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.impressiver.snitt.input-events"
        thread.start()
        self.thread = thread

        // Wait for the run loop to exist so a stop() immediately after start()
        // has something to stop.
        _ = ready.wait(timeout: .now() + .seconds(2))
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    deinit { stop() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter InputEventMonitorTests`
Expected: PASS — 4 new tests, 210 total.

**Note what these tests do and do not cover.** They pin the mapping and the mask — the parts that are pure and where the density bugs live. They do **not** prove a real tap delivers events; that needs Input Monitoring granted and a human typing, and it is on the manual checklist. Say so in your report rather than implying coverage you do not have.

- [ ] **Step 5: Commit**

```bash
git add Sources/SnittCapture/InputEventMonitor.swift Tests/SnittCaptureTests/InputEventMonitorTests.swift
git commit -m "feat(capture): log input events via a listen-only CGEventTap

Runs its run loop on a dedicated thread: the main loop stalls whenever the app
shows a modal sheet, which permission onboarding legitimately does. Re-enables
the tap on tapDisabledByTimeout, which macOS reports only through the callback
and which would otherwise silence capture for the rest of a recording."
```

---

## Task 4: Wire event logging into recording, behind an opt-in

**Files:**
- Create: `Sources/SnittApp/EventLoggingSettings.swift`
- Modify: `Sources/SnittCapture/Recorder.swift`
- Modify: `Sources/SnittCapture/CaptureOptions` (in `CaptureSession.swift`)
- Modify: `Sources/SnittApp/RecordingCoordinator.swift`
- Modify: `Sources/SnittApp/StatusItemController.swift`
- Modify: `Sources/SnittApp/main.swift`
- Modify: `Sources/SnittApp/PermissionOnboarding.swift`
- Create: `Tests/SnittAppTests/EventLoggingSettingsTests.swift`

**Interfaces:**
- Consumes: `InputEventMonitor`, `InputMonitoringAccess`, `SessionEventLog`, `PermissionOnboarding`
- Produces:
  - `public struct EventLoggingSettings: Sendable, Equatable` with `var enabled: Bool`, `static func load(_:) -> EventLoggingSettings`, `func save(to:)`
  - `CaptureOptions.logInputEvents: Bool` (default **false**)
  - `PermissionOnboarding.Service.inputMonitoring`

**Off by default, and that is the safety rule, not a preference.** §4.10's ladder tops out at three dialogs *only when a user asks for keystroke capture*. A default-on event log would charge every user the third dialog for a feature whose only consumer ships in a later milestone.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAppTests/EventLoggingSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.events.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Event logging is OFF for defaults that have never been written")
func eventLoggingDefaultsOff() {
    // §4.10's ladder reaches three dialogs only when a user asks for keystroke
    // capture. A default-on log would charge every user that prompt for a
    // feature whose only consumer ships in a later milestone.
    #expect(EventLoggingSettings.load(emptyDefaults()).enabled == false)
}

@Test("The setting survives a save and reload")
func settingRoundTrips() {
    let defaults = emptyDefaults()
    var settings = EventLoggingSettings.load(defaults)
    settings.enabled = true
    settings.save(to: defaults)
    #expect(EventLoggingSettings.load(defaults).enabled == true)
}

@Test("Input Monitoring has its own pre-explain state, independent of the others")
func inputMonitoringIsItsOwnRung() {
    // Marking screen recording explained must not consume the Input Monitoring
    // explanation — it is a different rung the user has not reached.
    let defaults = emptyDefaults()
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(PermissionOnboarding.shouldPreExplain(.inputMonitoring, defaults: defaults))
}

@Test("Every service still deep-links to a distinct Settings pane")
func inputMonitoringHasItsOwnPane() {
    let urls = PermissionOnboarding.Service.allCases.map {
        PermissionOnboarding.settingsURL(for: $0).absoluteString
    }
    #expect(Set(urls).count == urls.count,
            "a shared pane would send users to the wrong list")
    #expect(PermissionOnboarding.settingsURL(for: .inputMonitoring)
        .absoluteString.contains("ListenEvent"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EventLoggingSettingsTests`
Expected: FAIL — `EventLoggingSettings` and `Service.inputMonitoring` do not exist.

- [ ] **Step 3: Add the settings type**

Create `Sources/SnittApp/EventLoggingSettings.swift`:

```swift
import Foundation

/// The opt-in for logging input events (§4.2, §4.10 rung 3).
///
/// Defaults to FALSE for defaults that have never been written. That is the
/// safety rule rather than a preference: enabling it costs the user a third
/// TCC dialog, and the only consumer of the log ships in a later milestone.
public struct EventLoggingSettings: Sendable, Equatable {
    public var enabled: Bool

    private static let enabledKey = "com.impressiver.snitt.eventLoggingEnabled"

    public init(enabled: Bool = false) { self.enabled = enabled }

    public static func load(_ defaults: UserDefaults = .standard) -> EventLoggingSettings {
        EventLoggingSettings(enabled: defaults.bool(forKey: enabledKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
```

- [ ] **Step 4: Add the third rung to onboarding**

In `Sources/SnittApp/PermissionOnboarding.swift`, add `case inputMonitoring` to `Service`, and its arms:

```swift
            case .inputMonitoring: return "Input Monitoring"
```
```swift
            case .inputMonitoring:
                return "You turned on input logging, so Snitt can record WHEN "
                     + "you click and type — never which keys. Recordings mark "
                     + "the moments activity happened, so dead air can be "
                     + "trimmed later."
```
```swift
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security"
                             + "?Privacy_ListenEvent")!
```

The "never which keys" phrasing is load-bearing, not marketing: it is the one place a user is told what the log contains, and it must stay true. If a later milestone adds key identity, this copy changes with it.

- [ ] **Step 5: Thread the option through capture**

In `Sources/SnittCapture/CaptureSession.swift`, add to `CaptureOptions`:

```swift
    /// Log the fact of clicks and keystrokes (§4.2). Off by default: it costs
    /// the user a third TCC dialog (§4.10).
    public var logInputEvents: Bool
```

with the initialiser parameter defaulted `false`, placed last so existing call sites keep compiling.

In `Sources/SnittCapture/Recorder.swift`, hold a monitor and start it with the recording.

**Note `Recorder` does NOT currently store its options** — it passes them straight to
`CaptureSession` and discards them, so `options.logInputEvents` is not reachable from
`start()`. Store just the flag you need rather than the whole struct, so nothing else
starts depending on options after construction:

```swift
    private let logInputEvents: Bool
    private var inputEvents: InputEventMonitor?
```

with `self.logInputEvents = options.logInputEvents` in **both** initialisers — `Recorder`
has a real one and a `forTesting` one, and missing the second is a compile error you want
to hit now rather than at the end of the task.

In `start()`, after capture starts successfully:

```swift
        // Started only when asked, and only after capture is running, so a
        // failed recording never leaves a tap installed.
        if logInputEvents {
            let monitor = InputEventMonitor { [weak self] kind in
                guard let self else { return }
                Task { await self.recordInputEvent(kind) }
            }
            _ = monitor.start()
            inputEvents = monitor
        }
```

and the actor-isolated recorder for it:

```swift
    /// Records that input happened, on the same media clock markers use.
    private func recordInputEvent(_ kind: EventKind) async {
        let wallClock = startedAt.map { Date().timeIntervalSince($0) }
        let offset = CaptureSession.plausibleOffset(
            media: session.mediaOffsetNow(), wallClock: wallClock) ?? wallClock ?? 0
        await eventLog.add(at: offset, kind: kind, label: nil)
    }
```

In `stop()`, before finalising, tear the tap down:

```swift
        inputEvents?.stop()
        inputEvents = nil
```

- [ ] **Step 6: Add the menu toggle and the permission flow**

In `Sources/SnittApp/StatusItemController.swift`, add a second checkbox item beside "Allow agent recording", following that item's exact pattern:

```swift
        let eventsItem = NSMenuItem(title: "Log input events",
                                    action: #selector(toggleEventLogging),
                                    keyEquivalent: "")
        eventsItem.target = self
        eventsItem.state = eventLoggingEnabled ? .on : .off
        menu.addItem(eventsItem)
```

with `var eventLoggingEnabled = false`, `var onToggleEventLogging: ((Bool) -> Void)?`, and an `@objc private func toggleEventLogging()` calling `onToggleEventLogging?(!eventLoggingEnabled)`.

In `Sources/SnittApp/main.swift`, wire it exactly as `onToggleAgentRecording` is wired, and **request the permission at the moment the user enables it** — this is first use, and §4.10 requires the pre-explain sheet first:

```swift
        statusItem.onToggleEventLogging = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                // First use of the feature that needs it — never at launch.
                guard PermissionOnboarding.preExplain(.inputMonitoring) else { return }
                if !InputMonitoringAccess.ensureGranted() {
                    // Same shape as Screen Recording: a request returns false
                    // even while the user is granting, so this is "relaunch",
                    // not "denied".
                    PermissionOnboarding.showAlreadyDenied(.inputMonitoring)
                }
            }
            var settings = EventLoggingSettings.load()
            settings.enabled = enabled
            settings.save()
            self.statusItem.eventLoggingEnabled = enabled
        }
```

Then pass it into recording. **`RecordingCoordinator` already builds a `CaptureOptions`
and passes it as `options:` to `Recorder`** — M3a plumbed the audio flags through it — so
do NOT construct a fresh one, which would silently drop `--mic`. Set the new field on the
options the coordinator already has, on **both** the hotkey and the agent path:

```swift
        var options = /* the CaptureOptions this path already builds */
        // Read at record time rather than cached at launch, so toggling the
        // menu item takes effect on the next recording without a relaunch.
        options.logInputEvents = EventLoggingSettings.load().enabled
```

Verify afterwards that an agent's `--mic` still reaches `CaptureOptions` — there is an
existing test named `"--mic reaches the capture options instead of stopping at the wire"`
that will catch it if you replaced the struct instead of amending it.

- [ ] **Step 7: Run the suite**

Run: `swift test`
Expected: PASS — 4 new tests, 214 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

Run: `swift test --filter AccessConformance`
Expected: PASS — `main.swift` now calls `InputMonitoringAccess.ensureGranted()` rather than CoreGraphics directly, so the per-file rule still holds.

- [ ] **Step 8: Commit**

```bash
git add Sources/SnittApp Sources/SnittCapture Tests/SnittAppTests/EventLoggingSettingsTests.swift
git commit -m "feat(app): log input events behind an opt-in and a pre-explain sheet

Off by default: enabling it costs the third TCC dialog, and the only consumer
of the log ships in a later milestone. The permission is requested at the
moment the user turns the feature on — never at launch — and a false return is
reported as 'relaunch', not 'denied', per spike S5's finding."
```

---

## Task 5: `snitt inspect` over the socket

**Files:**
- Create: `Sources/SnittAutomation/InspectReport.swift`
- Modify: `Sources/SnittAutomation/Protocol.swift`
- Modify: `Sources/SnittApp/AutomationHost.swift`
- Create: `Tests/SnittAutomationTests/InspectReportTests.swift`

**Interfaces:**
- Consumes: `RecordingMetadata`, `EventLog`, `SnittBundle`, `AutomationRequest.Body`
- Produces:
  - `public struct InspectReport: Codable, Sendable, Equatable`
  - `AutomationRequest.Body.inspect(bundlePath: String)`
  - `AutomationResponse.inspected(InspectReport)`
  - `public static func report(for bundle: SnittBundle) throws -> InspectReport`

**THE DESIGN POINT, learned the hard way in M3a: `inspect` runs in the APP, not the CLI.**

M3a shipped a version of `record stop` that read health metrics back from the bundle it had just created. It silently returned nothing on every real machine, because the default output directory is `~/Desktop`, which is gated by the Files-and-Folders TCC service — `SnittBundle(opening:)` (a stat) succeeded while `RecordingMetadata.read` (a real read) failed and `try?` swallowed it. Every test passed because tests create bundles in temp directories they can read.

`snitt inspect` reads a bundle by definition, so it would hit that wall on its first real use. The CLI therefore sends a path over the socket and the app — which wrote the file and can read it — returns the report. That also keeps §4.9's thin-client rule intact.

**Amend protocol v2 rather than bumping to 3.** v2 has never shipped: `main` has no `SnittAutomation` at all, and both PRs are unmerged. Bumping would imply a compatibility break with a version nobody has. Record that reasoning in the version comment.

- [ ] **Step 1: Write the failing test**

Create `Tests/SnittAutomationTests/InspectReportTests.swift`:

```swift
import Testing
import Foundation
@testable import SnittAutomation
import SnittDocument

private func makeBundle() throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    return try SnittBundle(creatingAt: url)
}

@Test("A report carries what an agent needs to describe a recording it cannot watch")
func reportCarriesTheEssentials() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    try RecordingMetadata(
        createdAt: Date(timeIntervalSince1970: 1000),
        initiator: .agent,
        durationSeconds: 42.0,
        git: GitContext(branch: "feature/x", commit: "a1b2c3d"),
        health: CaptureHealth(meanFrameVariance: 500, micRMS: nil, systemAudioRMS: 0)
    ).write(to: bundle)

    try EventLog(events: [
        LoggedEvent(timeSeconds: 1, kind: .marker, label: "step one"),
        LoggedEvent(timeSeconds: 2, kind: .keystroke, label: nil),
        LoggedEvent(timeSeconds: 3, kind: .click, label: nil),
    ]).write(to: bundle)

    let report = try InspectReport.report(for: bundle)

    #expect(report.durationSeconds == 42.0)
    #expect(report.initiator == "agent")
    #expect(report.markerCount == 1)
    #expect(report.inputEventCount == 2)
    #expect(report.git?.branch == "feature/x")
    #expect(report.health?.meanFrameVariance == 500)
}

@Test("Marker labels are reported so an agent can name what it recorded")
func markerLabelsAreReported() throws {
    // §8: inspect exists so an agent can write something factually true —
    // "42s demo, chapters: repro / fix / verify" — rather than narrating a
    // video it has never seen.
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .agent).write(to: bundle)
    try EventLog(events: [
        LoggedEvent(timeSeconds: 1, kind: .marker, label: "repro"),
        LoggedEvent(timeSeconds: 9, kind: .marker, label: "fix"),
    ]).write(to: bundle)

    let report = try InspectReport.report(for: bundle)
    #expect(report.markers.map(\.label) == ["repro", "fix"])
    #expect(report.markers.map(\.timeSeconds) == [1, 9])
}

@Test("Input events contribute counts but never content")
func inputEventsAreCountedNotListed() throws {
    // The ruling: the log records that input happened, never what. A report
    // that listed input events individually would be the same disclosure by
    // another route.
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
    try EventLog(events: (0..<5).map {
        LoggedEvent(timeSeconds: Double($0), kind: .keystroke, label: nil)
    }).write(to: bundle)

    let report = try InspectReport.report(for: bundle)
    #expect(report.inputEventCount == 5)
    #expect(report.markers.isEmpty, "only markers are listed individually")
}

@Test("A bundle with no sidecars still reports rather than throwing")
func missingSidecarsStillReport() throws {
    // An interrupted recording leaves a partial bundle. An agent asking about
    // it deserves an answer, not an error it cannot act on.
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

    let report = try InspectReport.report(for: bundle)
    #expect(report.markerCount == 0)
    #expect(report.inputEventCount == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InspectReportTests`
Expected: FAIL — `cannot find 'InspectReport' in scope`.

- [ ] **Step 3: Write the report type**

Create `Sources/SnittAutomation/InspectReport.swift`:

```swift
import Foundation
import SnittDocument

/// What `snitt inspect` returns (§8).
///
/// Exists because an agent cannot watch the video it just made. Every value
/// here is already computed elsewhere in the pipeline; this assembles them so
/// an agent can write something factually true in a pull request instead of
/// narrating a recording it has never seen.
public struct InspectReport: Codable, Sendable, Equatable {
    public struct Marker: Codable, Sendable, Equatable {
        public var timeSeconds: Double
        public var label: String?
    }

    public var bundlePath: String
    public var createdAt: Date
    public var initiator: String
    public var durationSeconds: Double?
    public var git: GitContext?
    public var health: CaptureHealth?
    /// Markers are listed; input events are only counted — the log records
    /// that input happened, never what, and listing it would be the same
    /// disclosure by another route.
    public var markers: [Marker]
    public var markerCount: Int
    public var inputEventCount: Int

    public static func report(for bundle: SnittBundle) throws -> InspectReport {
        let meta = try RecordingMetadata.read(from: bundle)
        // A partial bundle from an interrupted recording still deserves an
        // answer rather than an error the agent cannot act on.
        let events = (try? EventLog.read(from: bundle))?.events ?? []
        let markers = events.filter { $0.kind == .marker }

        return InspectReport(
            bundlePath: bundle.url.path,
            createdAt: meta.createdAt,
            initiator: meta.initiator.rawValue,
            durationSeconds: meta.durationSeconds,
            git: meta.git,
            health: meta.health,
            markers: markers.map { Marker(timeSeconds: $0.timeSeconds, label: $0.label) },
            markerCount: markers.count,
            inputEventCount: events.count - markers.count
        )
    }
}
```

`GitContext` and `CaptureHealth` are already `Codable` in `SnittDocument`; `SnittAutomation` gained that dependency in M3a, so no `Package.swift` change is needed. Verify that before assuming it.

- [ ] **Step 4: Add the protocol case and the host handler**

In `Sources/SnittAutomation/Protocol.swift`, add to `AutomationRequest.Body`:

```swift
        case inspect(bundlePath: String)
```

and to `AutomationResponse`:

```swift
        case inspected(InspectReport)
```

Extend the version comment to record that v2 was amended again rather than bumped, and why.

In `Sources/SnittApp/AutomationHost.swift`, add the arm:

```swift
        case .inspect(let path):
            return inspect(bundlePath: path)
```

and the method:

```swift
    /// Reads the bundle IN THE APP, not the client.
    ///
    /// The CLI cannot read `~/Desktop` — it is gated by the Files-and-Folders
    /// TCC service, which is exactly how M3a's health block silently reported
    /// nothing on every real machine. The app wrote the file and can read it.
    private func inspect(bundlePath: String) -> AutomationResponse {
        do {
            let bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
            return .inspected(try InspectReport.report(for: bundle))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Check the path from `snitt record stop`. It must be a "
                    + ".snitt bundle written by this app."))
        }
    }
```

Note `inspect` is deliberately NOT gated by `ConsentPolicy`: reading a bundle the agent was handed the path to discloses nothing it did not already have, and gating it would make an agent unable to describe its own recording.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter InspectReportTests`
Expected: PASS — 4 new tests, 218 total.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittAutomation Sources/SnittApp/AutomationHost.swift Tests/SnittAutomationTests/InspectReportTests.swift
git commit -m "feat(automation): inspect a bundle over the socket

The app reads the file, not the client. M3a shipped a health block the CLI read
back from disk, which silently returned nothing on every real machine because
~/Desktop is gated by the Files-and-Folders TCC service. inspect reads a bundle
by definition, so it would have hit the same wall on first use."
```

---

## Task 6: The `snitt inspect` frontends

**Files:**
- Modify: `Sources/SnittAutomation/CommandLineParser.swift`
- Modify: `Sources/snitt-cli/main.swift`
- Modify: `Sources/SnittAutomation/MCPBridge.swift`
- Modify: `Sources/snitt-mcp/main.swift`
- Modify: `Tests/SnittAutomationTests/CommandLineParserTests.swift`
- Modify: `Tests/SnittAutomationTests/MCPBridgeTests.swift`

**Interfaces:**
- Consumes: `AutomationRequest.Body.inspect`, `InspectReport`
- Produces: `ParsedCommand.inspect(bundlePath: String)`; MCP tool `snitt_inspect`

**Both frontends must stay identical (§4.8).** The parity test in `MCPBridgeTests` is the mechanism; extend it rather than adding a second, weaker one.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SnittAutomationTests/CommandLineParserTests.swift`:

```swift
@Test("inspect parses a bundle path")
func parsesInspect() {
    #expect(CommandLineParser.parse(["inspect", "/tmp/x.snitt"])
            == .success(.inspect(bundlePath: "/tmp/x.snitt")))
}

@Test("inspect without a path is refused")
func inspectNeedsAPath() {
    #expect(CommandLineParser.parse(["inspect"]).isFailure)
}
```

Add to `Tests/SnittAutomationTests/MCPBridgeTests.swift`:

```swift
@Test("Both frontends express an inspect identically")
func frontendsAgreeOnInspect() {
    // §4.8: the CLI and the MCP server must be incapable of diverging.
    guard case .success(.inspect(let cliPath)) =
        CommandLineParser.parse(["inspect", "/tmp/demo.snitt"]) else {
        Issue.record("CLI could not express an inspect"); return
    }
    guard case .success(.inspect(let mcpPath)) = MCPBridge.request(
        forTool: "snitt_inspect", arguments: ["bundlePath": "/tmp/demo.snitt"]) else {
        Issue.record("MCP could not express an inspect"); return
    }
    #expect(cliPath == mcpPath)
}
```

`toolNamesAreStable` asserts the exact tool-name set — add `snitt_inspect` to it or it will fail.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandLineParserTests`
Expected: FAIL — `.inspect` is not a `ParsedCommand` case.

- [ ] **Step 3: Add the CLI surface**

In `Sources/SnittAutomation/CommandLineParser.swift`, add `case inspect(bundlePath: String)` to `ParsedCommand` and a branch in `parse`:

```swift
        case "inspect":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`inspect` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            return .success(.inspect(bundlePath: path))
```

In `Sources/snitt-cli/main.swift`, map it and render the report:

```swift
case .inspect(let path): body = .inspect(bundlePath: path)
```
```swift
    case .inspected(let report):
        emit(report)
        note("\(Int(report.durationSeconds ?? 0))s · \(report.markerCount) markers "
           + "· \(report.inputEventCount) input events")
```

Add to the help text, under `record stop`:

```
  snitt inspect <bundle>                 metadata as JSON, no GUI
```

- [ ] **Step 4: Add the MCP tool**

In `Sources/SnittAutomation/MCPBridge.swift`, add a sixth definition:

```swift
            ToolDefinition(
                name: "snitt_inspect",
                description: "Read a recording's metadata — duration, markers, capture "
                           + "health, git context — without watching it. Use this to "
                           + "describe a demo you made.",
                inputSchemaJSON: #"""
                {"type":"object",
                 "properties":{"bundlePath":{"type":"string",
                   "description":"Path printed by snitt_stop_recording"}},
                 "required":["bundlePath"]}
                """#),
```

and the mapping arm:

```swift
        case "snitt_inspect":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_inspect requires bundlePath"))
            }
            return .success(.inspect(bundlePath: path))
```

In `Sources/snitt-mcp/main.swift`, add `describe`'s arm — an MCP client reads text, so render the report rather than dumping JSON:

```swift
    case .inspected(let report):
        let chapters = report.markers
            .map { String(format: "%.0fs %@", $0.timeSeconds, $0.label ?? "(unlabelled)") }
            .joined(separator: ", ")
        return "\(Int(report.durationSeconds ?? 0))s recording, "
             + "\(report.markerCount) markers, \(report.inputEventCount) input events"
             + (chapters.isEmpty ? "" : " — \(chapters)")
```

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: PASS — 3 new tests, 221 total.

Run: `swift build -Xswiftc -strict-concurrency=complete`
Expected: zero source warnings.

- [ ] **Step 6: Verify both frontends by hand**

Run:

```bash
swift build --product snitt-cli --product snitt-mcp
./.build/debug/snitt-cli help                       # inspect appears in the help
./.build/debug/snitt-cli inspect                    # exits 2, message on stderr
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | ./.build/debug/snitt-mcp                        # six tools, including snitt_inspect
```

Do NOT launch `Snitt.app` — a real inspect needs a recorded bundle and belongs on the manual checklist.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittAutomation Sources/snitt-cli Sources/snitt-mcp Tests/SnittAutomationTests
git commit -m "feat(cli): add snitt inspect to both frontends

Both construct the same request body and travel through the same client, so
they cannot diverge; the parity test covers inspect alongside markers and
targets."
```

---

## Definition of done for M3b

- [ ] `swift test` passes — 221 tests, 0 failures
- [ ] `swift build -Xswiftc -strict-concurrency=complete` emits zero source warnings
- [ ] The access-conformance and thin-client guards still pass
- [ ] **With event logging OFF (the default), no Input Monitoring dialog ever appears**, and a recording's `events.json` contains only markers
- [ ] Enabling "Log input events" from the menu shows the pre-explain sheet **before** the system dialog, and the sheet says Snitt records *when* you type, never *which keys*
- [ ] With it enabled and granted, a recording's `events.json` contains `keystroke` and `click` entries with **`label: null`** and plausible offsets inside `durationSeconds`
- [ ] **No `events.json` entry ever contains a key name, character, or coordinate** — inspect the file directly
- [ ] `snitt inspect <bundle>` returns JSON for a bundle on the **Desktop** — the path the CLI cannot read itself
- [ ] `snitt inspect` reports marker labels but only a count for input events
- [ ] `snitt-mcp` advertises six tools including `snitt_inspect`
- [ ] Toggling event logging off and recording again produces a bundle with no input events, without relaunching

## What M3b deliberately does not build

`snitt trim`, `--auto-trim`, `snitt export` with its formats, `--scale`, `--max-size` and `--chapters`, the export manifest, and WebVTT chapters are **M3c**. Overlay *rendering* remains deferred past v0 and gated on M6 (§4.2, §13). `--auto-trim-gaps` stays unscheduled.

**Three limitations to carry forward:**

1. **The event log records timing only.** If overlays ship, key identity and click position become a separate deliberate decision with its own privacy design — not an inheritance from this milestone.
2. **A real tap is untested by CI.** `InputEventMonitor`'s mapping and mask are unit-tested; that a granted tap actually delivers events needs Input Monitoring and a human typing, and is on the manual checklist.
3. **Agent-driven recordings produce no input events at all** (§8). An agent driving an app through a CLI or HTTP generates no OS-level input, so its `events.json` will hold only markers. M3c's `--auto-trim` must refuse to run on an empty event log rather than trimming the entire recording.
