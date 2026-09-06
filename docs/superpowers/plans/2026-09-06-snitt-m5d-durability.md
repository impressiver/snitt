# M5d: Durability — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make §11's failure-mode promises real, and add the guard that stops a spec promise going unimplemented again.

**Architecture:** Three of the four gaps converge on one existing path — `Recorder.stop()` → `writeSidecars` — so the work is mostly *reaching* that path from failure modes that currently bypass it. An `SCStreamDelegate` routes stream death into it, a disk-space check routes exhaustion into it, and a launch scan finds bundles that never got there. The fourth is a retention policy for where bundles accumulate. D47's conformance guard sits alongside as a test.

**Tech Stack:** ScreenCaptureKit (`SCStreamDelegate`), AVFoundation (`AVAssetWriter`), AppKit, Swift 6 strict concurrency, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §11 (error handling) is the direct authority; §12 (diagnostics), §5 (consent), D47 (the conformance guard) constrain it.

## Why this milestone exists

An adversarial refinement pass found that §11 promises behaviours nothing implements. A code check then found a **fourth** five minutes after the list was called complete. The pattern — not the individual gaps — is what D47 names.

| §11 promise | State on `main` |
|---|---|
| "Disk full mid-recording: finalize the partial file; never discard it" | no `ENOSPC` handling anywhere |
| "Display disconnected or captured window closed: stop the stream and finalize cleanly" | `SCStream(delegate: nil)` — no delegate exists |
| "Unfinalized bundle found at launch: offer recovery" | no launch scan |
| bundles accumulate in `~/Desktop` | hardcoded, no retention |

## Global Constraints

- **Never discard a partial recording.** §11's phrasing is deliberate: a short video is recoverable, a deleted one is not. Every failure path finalizes what exists.
- **§4.11 preserved.** The hotkey starts recording with no window. D48: a human *stop* opens the editor; an agent stop opens nothing.
- **§5 consent unchanged.** Nothing here may add a prompt to the recording path.
- **Swift 6, strict concurrency, zero warnings** from `Sources/` under `swift build -Xswiftc -strict-concurrency=complete`.
- **Privacy in logging.** This project has leaked user data through `os_log` twice — an interpolated filename, and `String(describing:)` on an `NSError` (which serialises `userInfo` including `NSFilePath`). `privacy: .public` on `domain`, `code`, `localizedDescription` only. **Bundle filenames derive from the git branch via `BundleNaming`**, so one can name a customer or an unreleased feature. Use `SnittLog.logger(_:target:)`, never a raw `Logger(subsystem:)`.
- **Agent-initiated recordings never block on a GUI.** §11 is explicit: a structured error and a non-zero exit, never an invisible modal.

### Verification traps (apply to every task)

- `swift test` **exits 0 when the test bundle segfaults** — an inline `error: … signal code 11`, then **no summary line**. Piping to `grep` returns grep's status. **Only `Test run with N tests … passed/failed` is trustworthy; a run with no summary line is a crash.**
- `timeout` does not exist on macOS.
- **`NSApp` is nil in a test bundle** until `NSApplication.shared` is touched — use `@Suite(.serialized)` with `init() { _ = NSApplication.shared }`.
- **`.serialized` serialises within a suite only, not across suites.** `EditorWindowTestGate` is the global mutex for window-opening tests; use it if you open a window. `AppShellTests` mutating global `NSApplication` state while gated suites ran windows is the leading hypothesis for a 1-in-19 flake.
- No test may mutate the process-global cwd, or write to the real preference domain — verify via the **mtime** of `~/Library/Preferences/com.impressiver.snitt.plist`.
- **Do not set `SNITT_SIGN_IDENTITY`** — leave `build/Snitt.app` on `Snitt Development` or the maintainer's Screen Recording grant is revoked.
- `Scripts/make-app.sh`'s Info.plist heredoc is **unquoted**, so backticks in it execute. Two tests pin this.

### Testing standard

Every test names a plausible wrong implementation and is **verified to fail against it**. **Assert the target string was found before mutating, grep the mutated file before running, restore the tree afterwards** — that rule has caught three distinct failures in this project: a mutation matching nothing and reporting `passed`, a prescribed mutation that discriminated nothing, and a `git checkout` that silently discarded uncommitted work.

This project has found **twenty-six** instances of a test verifying a property *adjacent* to the one that mattered. For this milestone the shape to watch is: **asserting an error was raised is not asserting the partial file survived.** Every task here is about what remains on disk afterwards.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SnittCapture/StreamInterruption.swift` *(new)* | The reason a stream ended, and whether it was expected. |
| `Sources/SnittCapture/CaptureSession.swift` | Adopt `SCStreamDelegate`; route stream death outward. |
| `Sources/SnittCapture/Recorder.swift` | Finalize on interruption, not only on `stop()`. |
| `Sources/SnittCapture/DiskSpace.swift` *(new)* | Free-space probe and the low-space threshold. |
| `Sources/SnittCapture/AssetWriterSink.swift` | Detect write failure and stop cleanly rather than looping. |
| `Sources/SnittDocument/BundleRecovery.swift` *(new)* | Find bundles with `capture.mov` and no `meta.json`; finalize or discard on request. |
| `Sources/SnittApp/RecoveryPrompt.swift` *(new)* | The launch-time offer. |
| `Sources/SnittApp/RetentionSettings.swift` *(new)* | Output location and retention policy. |
| `Tests/SnittConformanceTests/SpecPromiseTests.swift` *(new)* | D47's guard. |

---

## Task 1: The stream can die without us noticing

**Files:**
- Create: `Sources/SnittCapture/StreamInterruption.swift`
- Modify: `Sources/SnittCapture/CaptureSession.swift:96-98`, `Sources/SnittCapture/Recorder.swift`
- Test: `Tests/SnittCaptureTests/StreamInterruptionTests.swift`

**Interfaces:**
- Produces: `enum StreamInterruption: Sendable { case windowClosed, displayDisconnected, other(NSError) }` and a callback on `CaptureSession` the `Recorder` installs.

**Why this task exists:** `CaptureSession.swift:98` passes **`delegate: nil`**. There is no `SCStreamDelegate` in the codebase, so `stream(_:didStopWithError:)` never arrives. §11 promises *"display disconnected or captured window closed: stop the stream and finalize cleanly"* — and closing the window you are recording is an **ordinary action**, not an edge case. Today the stream dies and the recording keeps thinking it is running.

- [ ] **Step 1: Write the failing test**

```swift
@Test("A stream that stops on its own finalizes the bundle")
func interruptedStreamFinalizes() async throws {
    let recorder = try makeRecorder()           // existing fixture helper — read the suite first
    try await recorder.start()
    try await recorder.simulateStreamInterruption(.windowClosed)

    // The property that matters is what is ON DISK. Asserting that an error
    // was raised, or that a callback fired, passes against an implementation
    // that notices the interruption and still loses the recording.
    let bundle = try #require(recorder.bundleForTesting)
    #expect(FileManager.default.fileExists(atPath: bundle.metaURL.path),
            "meta.json is what makes a bundle openable — an interrupted recording must still get one")
    let meta = try RecordingMetadata.read(from: bundle)
    #expect(meta.durationSeconds != nil)
}

@Test("An interrupted recording is still openable")
func interruptedBundleOpens() async throws {
    // The end-to-end property: DocumentOpener must accept what the
    // interruption path produced. A bundle that finalizes but cannot be
    // opened is the same defect D45 named.
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
swift test --filter StreamInterruptionTests 2>&1 | grep -E "Test run with|error:"
```

- [ ] **Step 3: Adopt the delegate**

`SCStreamDelegate`'s `stream(_:didStopWithError:)` is the callback. Classify the error — ScreenCaptureKit reports a closed window and a disconnected display differently, and **verify the actual codes rather than guessing**; if you cannot determine them, map what you can and pass the rest through as `.other`, saying so in the report.

Route it to the `Recorder`, which finalizes through the **same** `writeSidecars` path `stop()` uses. Do not write a second finalize.

**An interruption is not a user stop.** Per D48 a human stop opens the editor; decide whether an interruption should, record the choice, and make it consistent for the agent path (which opens nothing).

- [ ] **Step 4: Verify, mutation-verify, commit**

Mutation: have the delegate log the interruption and return without finalizing. `interruptedStreamFinalizes` must fail. Restore.

```bash
git commit -m "fix(capture): finalize when the stream dies on its own"
```

---

## Task 2: Disk full must finalize, never discard

**Files:**
- Create: `Sources/SnittCapture/DiskSpace.swift`
- Modify: `Sources/SnittCapture/AssetWriterSink.swift:132`
- Test: `Tests/SnittCaptureTests/DiskSpaceTests.swift`

**Why this task exists:** zero `ENOSPC` handling exists. §11 promises *"finalize the partial file; never discard it."* The Operator persona ranked this the most likely failure to bite in month one, because it scales with **usage** rather than attention — and an agent recording unattended over MCP is exactly the pattern that fills a disk.

**The hard part is testing it.** You cannot fill the maintainer's disk. Options, in preference order:

1. A **sparse disk image** of a few MB, mounted, recorded into until it fills — real `ENOSPC` from the real writer. `hdiutil create -size 5m -fs APFS`.
2. An injected space probe returning a low value, driving the same guard.

**Prefer (1) if it works in your environment** — it exercises `AVAssetWriter`'s actual failure rather than your model of it. If you fall back to (2), **say so plainly** and name what the first real disk-full will confirm.

- [ ] **Step 1: Write the failing test**

```swift
@Test("A recording that runs out of disk keeps what it captured")
func diskFullFinalizesPartial() async throws {
    let volume = try SparseVolume(megabytes: 5)   // helper you write; unmounts in deinit
    defer { volume.unmount() }

    let recorder = try makeRecorder(outputDirectory: volume.url)
    try await recorder.start()
    await volume.fillUntilRecordingFails(recorder)

    let bundle = try #require(recorder.bundleForTesting)
    // NEVER DISCARD is the promise. A capture.mov of non-zero length that
    // plays is a success here; an empty directory is the failure §11 names.
    let size = try FileManager.default.attributesOfItem(atPath: bundle.captureURL.path)[.size] as? Int ?? 0
    #expect(size > 0, "the partial capture was discarded")
    #expect(FileManager.default.fileExists(atPath: bundle.metaURL.path))
}
```

- [ ] **Step 2–5:** run-fail; add a pre-flight space check at record start (refuse to *begin* with too little, which is a better failure than dying mid-take) and a mid-recording guard that stops and finalizes; verify; **mutation: make the guard discard the bundle instead of finalizing — the test must fail**; commit.

`AssetWriterSink.swift:132`'s `await writer.finishWriting()` already exists; the surrounding `writer.status == .failed` check at line 134 is where the disk-full path currently ends up silently.

---

## Task 3: Recover an unfinalized bundle at launch

**Files:**
- Create: `Sources/SnittDocument/BundleRecovery.swift`, `Sources/SnittApp/RecoveryPrompt.swift`
- Modify: `Sources/SnittApp/main.swift` (`applicationDidFinishLaunching`)
- Test: `Tests/SnittDocumentTests/BundleRecoveryTests.swift`

**Why this task exists:** §11 promises *"unfinalized bundle found at launch: offer recovery."* No launch scan exists, and this appeared nowhere on the roadmap before the refinement pass.

**The detection signal already exists — do not invent a marker file.** `Recorder.writeSidecars` writes `meta.json`, `events.json` and `edit.json` at finalize (`Recorder.swift:265-289`). So:

> **An unfinalized bundle is a directory ending `.snitt` containing `capture.mov` and no `meta.json`.**

`AssetWriterSink` writes a fragmented movie, so `capture.mov` is **playable even when the writer never finished** — this is "notice and offer to finish," not "repair video."

- [ ] **Step 1: Write the failing test**

```swift
@Test("A bundle with a capture but no metadata is offered for recovery")
func findsUnfinalizedBundle() throws {
    let dir = try makeTempDirectory()
    let finalized = try makeFinalizedBundle(in: dir)     // has meta.json
    let orphan = try makeUnfinalizedBundle(in: dir)      // capture.mov only

    let found = try BundleRecovery.unfinalizedBundles(in: dir)

    // Both halves matter. Finding the orphan proves detection; EXCLUDING the
    // finalized one proves it is detection rather than "every bundle".
    #expect(found.map(\.url) == [orphan])
}

@Test("Recovering an unfinalized bundle makes it openable")
func recoveryProducesAnOpenableBundle() async throws {
    let orphan = try makeUnfinalizedBundle(in: makeTempDirectory())
    try BundleRecovery.finalize(orphan)
    // The end-to-end property, not "meta.json exists": DocumentOpener must
    // accept it. Writing a meta.json the opener rejects is the D45 defect.
    _ = try await DocumentOpener.open(bundleURL: orphan.url)
}
```

- [ ] **Step 2–6:** run-fail; implement the scan over the configured output directory (Task 4 owns *which* directory); reconstruct metadata from what survives — duration from the movie's own tracks, not from a wall clock that no longer exists; offer the choice at launch **without blocking** (§4.11: no window at launch; this is a response to found data, so decide and record whether it opens a window or defers to the Dock/menu); verify; mutation: return every bundle rather than only unfinalized ones — `findsUnfinalizedBundle` must fail; commit.

**A crashed recording is exactly when a user is most anxious. Do not make recovery destructive** — offer, never auto-delete.

---

## Task 4: Where recordings go, and how many

**Files:**
- Create: `Sources/SnittApp/RetentionSettings.swift`
- Modify: `Sources/SnittApp/main.swift:41-42`, `Sources/SnittApp/SettingsWindowController.swift`
- Test: `Tests/SnittAppTests/RetentionSettingsTests.swift`

**Why this task exists:** `main.swift:41-42` hardcodes `~/Desktop`. Every recording — human and agent — lands there with no cleanup. An agent recording unattended produces exactly the accumulation pattern nobody notices until the disk is full, which is Task 2's failure arriving by a slower road.

- [ ] **Step 1: Write the failing tests** — a configurable output directory defaulting to today's `~/Desktop` (**do not change where existing users' recordings go**), and a retention policy that is **off by default**. Deleting a user's recordings is not a default; §5's posture is that Snitt does not act on your data unasked.

- [ ] **Step 2–6:** run-fail; implement; surface both in the Settings window Task M5c added, sharing storage with any status-item equivalent as `EventLoggingToggle` does; verify; **mutation: make retention default to on — the default test must fail**; commit.

---

## Task 5: D47's conformance guard

**Files:**
- Create: `Tests/SnittConformanceTests/SpecPromiseTests.swift`
- Modify: `docs/superpowers/specs/2026-09-02-snitt-design.md` (promise markers)

**Why this task exists — read this before designing it.** D47 was recorded because three spec promises turned out unimplemented. A fourth (`delegate: nil`) was found five minutes after the list was called complete, by grepping rather than reasoning. **We do not know the denominator.** That is what this guard is for.

It is also the task most likely to become theatre. A test asserting "the spec mentions X" proves nothing. Aim for:

> **Every normative promise in the spec carries a marker naming the test, the task, or an explicit deferral that covers it — and the guard fails when a marker names something that does not exist.**

- [ ] **Step 1:** Choose the marker syntax and apply it to §11's promises first — they are the known set. A promise with no marker is a failure; a marker naming a missing test is a failure.
- [ ] **Step 2:** Write the guard. It must fail today if you remove any marker you just added, **and** fail if a marker names a nonexistent symbol.
- [ ] **Step 3:** Extend to §4's decisions and §12's diagnostics bullets. **Report the count of promises with no covering test** — that number is this task's most valuable output, and it should go in the milestone report whatever it says.
- [ ] **Step 4:** Verify, mutation-verify, commit.

**If you conclude a mechanical guard cannot work here, say so with reasons rather than shipping one that passes vacuously.** An honest "this needs human review, here is the checklist" beats a green test that checks nothing — and this project has twenty-six findings arguing the second is worse than nothing.

---

## Definition of Done

- [ ] Closing a recorded window finalizes the bundle, and it opens.
- [ ] A recording that exhausts disk keeps a playable partial capture; nothing is discarded.
- [ ] An unfinalized bundle is found at launch and can be recovered into an openable document.
- [ ] Recordings go where the user chooses; retention is off by default.
- [ ] The conformance guard fails when a promise loses its marker, and the uncovered-promise count is reported.
- [ ] §4.11 and §5 unchanged; agent paths never block on a GUI.
- [ ] Full suite green twice with the trustworthy summary line; strict-concurrency clean; real preference domain untouched.

## Deliberately not in scope

- **The overlay compositor's render-failure path** (§11's last bullet) — it ships with M7, and there is no compositor to fail yet.
- **A general retention UI** beyond a location and an off-by-default policy.
- **Sweeping the pre-existing fixture-plist accumulation** (7,414 files) — real, tracked, and its own job.
