import Testing
import Foundation
import SnittCapture
import SnittDocument
@testable import SnittApp

@Test("With no cached target the picker is used")
func firstRunUsesPicker() {
    #expect(RecordingCoordinator.resolverChoice(hasCachedTarget: false) == .picker)
}

@Test("The picker is used EVEN WHEN a target is cached — every press asks")
func cachedTargetIsNotReusedForTheHotkey() {
    // Falsifiable on purpose: this is the exact input the previous design
    // answered with `.cache`, so a regression to target-reuse fails here.
    #expect(RecordingCoordinator.resolverChoice(hasCachedTarget: true) == .picker,
            "silently re-recording the last window is surprising; the user picks each time")
}

@Test("Outcomes distinguish cancellation from failure")
func outcomesAreDistinguishable() {
    #expect(CoordinatorOutcome.cancelled != CoordinatorOutcome.failed("x", reason: .internalError))
    #expect(CoordinatorOutcome.failed("a", reason: .internalError)
            != CoordinatorOutcome.failed("b", reason: .internalError))
    #expect(CoordinatorOutcome.failed("a", reason: .permissionDenied)
            != CoordinatorOutcome.failed("a", reason: .alreadyRecording),
            "the reason is part of the outcome — an agent branches on it")
}

@Test("A stopped outcome reports whether the copy succeeded")
func stoppedReportsCopyResult() {
    let url = URL(fileURLWithPath: "/tmp/x.snitt")
    #expect(CoordinatorOutcome.stopped(url, copied: true)
            != CoordinatorOutcome.stopped(url, copied: false),
            "the user must be told if the clipboard copy failed")
}

/// A resolver that blocks until released, so a toggle can be held mid-transition.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

final class SlowResolver: TargetResolver, @unchecked Sendable {
    let gate: Gate
    init(gate: Gate) { self.gate = gate }

    func resolve() async throws -> ResolvedTarget {
        await gate.wait()
        // Never actually produces a target — the test only needs the suspension.
        throw TargetResolutionError.cancelled
    }
}

@Test("A press arriving mid-transition is ignored rather than starting a second recording")
func concurrentTogglesDoNotDoubleStart() async throws {
    let gate = Gate()
    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    let coordinator = RecordingCoordinator(
        pickerResolver: SlowResolver(gate: gate),
        cachedResolverFactory: { _ in SlowResolver(gate: gate) },
        store: store,
        outputDirectorySettings: { OutputDirectorySettings(directory: FileManager.default.temporaryDirectory) },
        // Granted, deterministically. Otherwise these tests assert their
        // property only on a machine that happens to have the grant and pass
        // vacuously everywhere else.
        ensureAccess: { true }
    )

    // First toggle suspends inside resolve(), holding the transition.
    async let first = coordinator.toggle()
    // Give it a moment to actually enter and claim.
    try await Task.sleep(for: .milliseconds(50))
    // Second toggle must be refused rather than starting its own recording.
    let second = await coordinator.toggle()

    #expect(second == .ignored,
            "a press during an in-flight transition must not start a second recording")

    await gate.open()
    _ = await first
}

/// Distinguishes "the forced resolver actually ran" from every other outcome,
/// including the pre-fix bug's `.failed("The cached target could not be
/// read.")` — which fired from the `.cache` switch arm's `guard let stored`
/// before a forced resolver was ever consulted.
private struct MarkerError: Error, Equatable {}

final class MarkerResolver: TargetResolver, @unchecked Sendable {
    func resolve() async throws -> ResolvedTarget {
        throw MarkerError()
    }
}

@Test("An agent recording works on a machine where the hotkey path has never run")
func agentStartsWithAnEmptyStore() async throws {
    // A genuinely empty store — nothing has ever been written to this path,
    // which is the ordinary state on a fresh install: agent recording needs
    // no prior hotkey use. The pre-fix bug routed every agent request through
    // the `.cache` switch arm regardless, which read this same empty store and
    // failed with "The cached target could not be read." before the forced
    // resolver (the agent's own, explicit target) was ever reached.
    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    let coordinator = RecordingCoordinator(
        pickerResolver: MarkerResolver(),   // must never be used by an agent request
        cachedResolverFactory: { _ in MarkerResolver() },
        store: store,
        outputDirectorySettings: { OutputDirectorySettings(directory: FileManager.default.temporaryDirectory) },
        // Granted, deterministically. Otherwise these tests assert their
        // property only on a machine that happens to have the grant and pass
        // vacuously everywhere else.
        ensureAccess: { true }
    )

    let outcome = await coordinator.startForAgent(
        sessionID: "session-1",
        reference: .window(bundleIdentifier: "com.example.Agent", titleHint: nil),
        git: nil,
        options: CaptureOptions())

    // `MarkerResolver.resolve()` always throws, so the coordinator can never
    // reach `.started` in this test — reaching a real `.started` would require
    // constructing a genuine `SCContentFilter`, which ScreenCaptureKit offers
    // no way to do without live enumeration (see the task report). What this
    // DOES prove, unambiguously: the forced resolver's `resolve()` ran at all,
    // which is exactly the step the bug skipped.
    //
    // Asserted POSITIVELY, on MarkerResolver's own error. The previous version
    // only checked that the message did NOT contain "cached target could not
    // be read" — which an unrelated permission-denied message also satisfies,
    // so on an ungranted machine it passed against the exact bug it names.
    guard case .failed(let message, let reason) = outcome else {
        Issue.record("expected a failure surfaced from MarkerResolver, got \(outcome)")
        return
    }
    #expect(message.contains("MarkerError"),
            "the failure must be the forced resolver's OWN — got: \(message)")
    #expect(reason == .internalError)
    #expect(!message.contains("cached target could not be read"))
}

@Test("A coordinator that never started an agent session refuses to stop one")
func stopForAgentRefusesUnknownSession() async {
    // The cheap half of Important 4's guarantee that IS reachable in a test.
    // `.started` is not: it needs a real `SCContentFilter`, which
    // ScreenCaptureKit will not construct without live screen enumeration. So
    // the positive path (start as agent, human stops, agent's id goes stale) is
    // covered against a modelled coordinator in `AutomationHostTests`; what is
    // provable here is that ownership is checked at all.
    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    let coordinator = RecordingCoordinator(
        pickerResolver: MarkerResolver(),
        cachedResolverFactory: { _ in MarkerResolver() },
        store: store,
        outputDirectorySettings: { OutputDirectorySettings(directory: FileManager.default.temporaryDirectory) },
        // Granted, deterministically. Otherwise these tests assert their
        // property only on a machine that happens to have the grant and pass
        // vacuously everywhere else.
        ensureAccess: { true }
    )
    let result = await coordinator.stopForAgent(sessionID: "never-started")
    #expect(result == .notCurrentSession,
            "an agent must not be able to stop a recording it does not own")
}

@Test("An agent recording is stamped as agent-initiated, not human")
func agentRecordingsCarryAgentProvenance() {
    // Every recording was stamped `.human`: `Recorder.init` defaults to it and
    // `startRecording` never passed one on either path, so `.agent` had zero
    // references outside its own declaration. Provenance is the one metadata
    // field whose entire purpose is telling the two apart.
    //
    // The call site itself cannot be tested — reaching `Recorder.init` needs a
    // real `SCContentFilter`, which ScreenCaptureKit will not construct without
    // live screen enumeration. This pins the mapping; the wiring is by
    // inspection.
    #expect(RecordingCoordinator.initiator(isAgent: true) == .agent)
    #expect(RecordingCoordinator.initiator(isAgent: false) == .human)
}

@Test("usedCache means the human path actually chose the cache — not merely that a resolver was forced")
func usedCacheReflectsTheHumanPathsOwnChoiceOnly() {
    // Before this, an agent's forced-resolver branch set a `ResolverChoice`
    // of `.cache` purely so `usedCache: choice == .cache` came out true —
    // `usedCache` on that path meant "used an explicit resolver," not "hit
    // the hotkey cache," two different concepts wearing one name. An agent's
    // forced resolver now carries no `ResolverChoice` at all (`nil`), and
    // `usedCache` must read false for it regardless of what the human path's
    // own choice happens to be.
    #expect(RecordingCoordinator.usedCache(choice: nil) == false)
    // The human path's actual signal still works: `.cache` reads true...
    #expect(RecordingCoordinator.usedCache(choice: .cache) == true)
    // ...and `.picker` — the only value `resolverChoice` produces today —
    // reads false, matching §5's requirement that `ConsentExplainer` behave
    // exactly as it does now: never shown, because the human path's own
    // `.cache` arm is unreachable.
    #expect(RecordingCoordinator.usedCache(choice: .picker) == false)
}

@Test("The -3801 error reports permission_denied, not an internal error")
func reasonMapsScreenCaptureDenial() {
    // Finding 3's most important case, and it had no test at all.
    // ScreenCaptureKit reports a missing Screen Recording grant as -3801. If
    // this said `.internalError`, an agent would get exit 16 and no idea that
    // granting permission and relaunching Snitt is the entire fix — while
    // `explain(_:)` printed a message that says exactly that. The two must not
    // be able to disagree.
    let denial = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                         code: -3801)
    #expect(RecordingCoordinator.reason(for: denial) == .permissionDenied)
    #expect(RecordingCoordinator.explain(denial).contains("does not have permission"),
            "the human text and the machine code must describe the same failure")

    // Anything else is internal: a different SCStream code, and a foreign domain
    // that happens to share the number.
    #expect(RecordingCoordinator.reason(for: NSError(
        domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
        code: -3802)) == .internalError)
    #expect(RecordingCoordinator.reason(for: NSError(
        domain: "com.example.Other", code: -3801)) == .internalError)
}

/// Resolves nothing: reports the target as gone, exactly as
/// `CachedTargetResolver` does when the app has no windows on screen.
final class GoneResolver: TargetResolver, @unchecked Sendable {
    func resolve() async throws -> ResolvedTarget {
        throw TargetResolutionError.targetGone("com.example.Gone")
    }
}

private func storedSafari() -> StoredTargetReference {
    StoredTargetReference(kind: .window, bundleIdentifier: "com.apple.Safari",
                          titleHint: "Inbox", displayID: nil)
}

@Test("An agent's failed start does not erase the human's cached target")
func agentFailureLeavesTheHumanStoreIntact() async throws {
    // Minor 8. The `targetGone` arm cleared the store unguarded, while the WRITE
    // side thirteen lines below was correctly guarded — an agent naming a window
    // that is not open says nothing about the human's last hotkey choice.
    //
    // Reachable without a real SCContentFilter because the throw happens before
    // `Recorder.init` is ever called.
    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    try store.save(storedSafari())

    let coordinator = RecordingCoordinator(
        pickerResolver: GoneResolver(),
        cachedResolverFactory: { _ in GoneResolver() },
        store: store,
        outputDirectorySettings: { OutputDirectorySettings(directory: FileManager.default.temporaryDirectory) },
        // Granted, deterministically. Otherwise these tests assert their
        // property only on a machine that happens to have the grant and pass
        // vacuously everywhere else.
        ensureAccess: { true }
    )

    _ = await coordinator.startForAgent(
        sessionID: "s1",
        reference: .window(bundleIdentifier: "com.example.Gone", titleHint: nil),
        git: nil,
        options: CaptureOptions())

    #expect(store.load() == storedSafari(),
            "an agent must not be able to erase the human's cached target")
}

@Test("A human's own failed start DOES clear the stale cache")
func humanFailureClearsTheStore() async throws {
    // The other direction: the guard must not have disabled the behaviour it
    // was narrowing. A human whose cached app is gone should get the picker on
    // the next press rather than the same failure again.
    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    try store.save(storedSafari())

    let coordinator = RecordingCoordinator(
        pickerResolver: GoneResolver(),
        cachedResolverFactory: { _ in GoneResolver() },
        store: store,
        outputDirectorySettings: { OutputDirectorySettings(directory: FileManager.default.temporaryDirectory) },
        // Granted, deterministically. Otherwise these tests assert their
        // property only on a machine that happens to have the grant and pass
        // vacuously everywhere else.
        ensureAccess: { true }
    )

    let outcome = await coordinator.toggle()
    // Asserted, not guarded past. This used to be
    // `guard case ... else { return }` — a silent pass on any other outcome,
    // including the permission-denied one an ungranted machine produces.
    guard case .failed(_, .targetUnavailable) = outcome else {
        Issue.record("expected the resolver's targetGone to surface, got \(outcome)")
        return
    }
    #expect(store.load() == nil,
            "a stale cache must be cleared so the next press offers the picker")
}

// MARK: - The human/hotkey path's microphone wiring

/// The gap this fixes: the human hotkey path built `CaptureOptions()` and
/// set only `logInputEvents`, so `captureMicrophone` stayed at
/// `CaptureOptions`'s own `false` default no matter what
/// `MicrophoneSettings` held — a ticked "Record voiceover" box that could
/// never actually reach a recording. Only `startForAgent` (fed by the CLI's
/// `--mic`) ever threaded a caller-supplied `captureMicrophone` through.
///
/// Reaching `toggle()`'s own call into `startRecording` needs a real
/// `SCContentFilter`, which no test can construct (see the other tests in
/// this file making the same point) — so this exercises `humanCaptureOptions`
/// directly, the exact function `toggle()` calls to build its options.
///
/// Verified to fail against the bug: deleting
/// `options.captureMicrophone = microphone.enabled` from
/// `humanCaptureOptions` leaves `options.captureMicrophone` at `false`
/// regardless of the `microphone` argument, and the first `#expect` below
/// fails. A test that only round-trips `MicrophoneSettings` through
/// `UserDefaults` would pass against that exact same bug — this one does
/// not, because it exercises the code path that actually builds
/// `CaptureOptions`.
@Test("The hotkey path threads captureMicrophone from MicrophoneSettings")
func humanPathThreadsMicrophoneSetting() {
    let options = RecordingCoordinator.humanCaptureOptions(
        eventLogging: EventLoggingSettings(enabled: false),
        microphone: MicrophoneSettings(enabled: true))
    #expect(options.captureMicrophone == true,
            "a ticked microphone setting must reach CaptureOptions, not stop at UserDefaults")
}

@Test("The hotkey path leaves the microphone off unless the setting says otherwise")
func humanPathMicrophoneOffByDefault() {
    // §4.10 rung 2: the microphone prompt is paid only when someone
    // deliberately enables it — mirrors AutomationHostTests's
    // "microphoneIsOffByDefault" for the agent path.
    let options = RecordingCoordinator.humanCaptureOptions(
        eventLogging: EventLoggingSettings(enabled: false),
        microphone: MicrophoneSettings(enabled: false))
    #expect(options.captureMicrophone == false)
}

@Test("logInputEvents keeps threading through alongside the microphone setting")
func humanPathStillThreadsEventLogging() {
    // The precedent this function generalizes: `logInputEvents` must keep
    // working exactly as it did before this fix, not be crowded out by the
    // new setting.
    let options = RecordingCoordinator.humanCaptureOptions(
        eventLogging: EventLoggingSettings(enabled: true),
        microphone: MicrophoneSettings(enabled: false))
    #expect(options.logInputEvents == true)
    #expect(options.captureSystemAudio == true, "system audio stays the hotkey's fixed default")
}

// MARK: - Configurable output directory (M5f)

@Test("A new recording's bundle lands inside the CONFIGURED directory, not a hardcoded one")
func bundleURLUsesConfiguredDirectory() {
    // Verified to fail against the bug this whole feature replaces: a
    // `bundleURL` that ignores `directory` and always returns a path under
    // `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")`
    // (main.swift's old hardcoded value) would put this URL under Desktop
    // regardless of what `custom` is here, failing the assertion below.
    let custom = URL(fileURLWithPath: "/Volumes/External/MyRecordings")
    let url = RecordingCoordinator.bundleURL(directory: custom, git: nil, timestamp: 100)
    // Compared by `.path` rather than raw `URL` equality — see
    // `OutputDirectorySettings.load`'s own doc comment on why two URLs
    // naming the same folder can otherwise compare unequal.
    #expect(url.deletingLastPathComponent().path == custom.path)
}

@Test("A missing output directory is created rather than failing the recording")
func prepareOutputDirectoryCreatesAMissingFolder() throws {
    // §"the directory no longer exists" case, and also the ordinary first-run
    // state now that the default (`~/Documents/Snitt`) will not exist on a
    // fresh machine. Verified to fail against a wrong implementation that
    // refuses whenever `fileExists` is false instead of creating the folder:
    // that would make `prepareOutputDirectory` return a `.failed` outcome
    // here, failing the first `#expect` below.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-output-dir-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    let outcome = RecordingCoordinator.prepareOutputDirectory(directory)
    #expect(outcome == nil, "a missing directory must be created, not treated as a failure")

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
    #expect(exists && isDirectory.boolValue, "the directory must actually exist on disk afterward")
}

@Test("An already-existing, writable directory passes through untouched")
func prepareOutputDirectoryAcceptsAnExistingWritableFolder() {
    // Sanity check: the common case (a directory that already exists, e.g.
    // every recording after the first) must not be treated as a failure.
    let outcome = RecordingCoordinator.prepareOutputDirectory(FileManager.default.temporaryDirectory)
    #expect(outcome == nil)
}

@Test("A configured path that is a FILE, not a folder, refuses rather than writing into it")
func prepareOutputDirectoryRefusesAFile() throws {
    // Verified to fail against an implementation that only calls
    // `createDirectory(withIntermediateDirectories: true)` unconditionally
    // and treats any thrown error as the only failure signal: on some
    // filesystems that call no-ops (or throws a confusing low-level error)
    // when the path already exists as a plain file, so the coordinator
    // could sail past this check and only discover the mistake much later,
    // trying to write a bundle "inside" a file.
    let filePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-output-dir-test-file-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: filePath)
    defer { try? FileManager.default.removeItem(at: filePath) }

    guard case .failed(let message, let reason) = RecordingCoordinator.prepareOutputDirectory(filePath) else {
        Issue.record("expected a failure — the configured path is a file, not a folder")
        return
    }
    #expect(reason == .internalError)
    #expect(message.contains(filePath.path), "the message must name the folder that could not be used")
}

@Test("An unwritable output directory refuses to start rather than failing at finalize")
func prepareOutputDirectoryRefusesAnUnwritableFolder() throws {
    // §"the directory is not writable" case. Checked and reported HERE,
    // before a recording starts, rather than discovered only when
    // `stopRecording()` tries to finalize the bundle — by which point the
    // capture itself, not just the save, would be lost.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-output-dir-test-unwritable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    #expect(!FileManager.default.isWritableFile(atPath: directory.path),
            "the fixture itself must actually be unwritable, or this test proves nothing")

    guard case .failed(_, let reason) = RecordingCoordinator.prepareOutputDirectory(directory) else {
        Issue.record("expected a failure — the configured folder is not writable")
        return
    }
    #expect(reason == .internalError)
}

/// Fails the test if `resolve()` ever runs — for proving directory
/// preparation happens BEFORE the picker (or the cached-target resolver),
/// not after it.
final class NeverCalledResolver: TargetResolver, @unchecked Sendable {
    func resolve() async throws -> ResolvedTarget {
        Issue.record("resolve() must not run when the output directory could not be prepared")
        throw MarkerError()
    }
}

@Test("A recording that cannot possibly be saved never reaches the picker")
func unpreparableDirectoryIsCheckedBeforeThePicker() async throws {
    // A doomed recording — one whose configured folder cannot be created or
    // written to — must fail BEFORE asking a human which window to record,
    // not after. `NeverCalledResolver` above fails this test outright if
    // `toggle()` ever reaches target resolution.
    let filePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-output-dir-test-blocker-\(UUID().uuidString)")
    try Data("blocks a directory from being created here".utf8).write(to: filePath)
    defer { try? FileManager.default.removeItem(at: filePath) }
    // `directory` names a path INSIDE a file — `createDirectory` cannot
    // create it, deterministically, without needing any special permissions.
    let unpreparable = filePath.appendingPathComponent("Recordings")

    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    let coordinator = RecordingCoordinator(
        pickerResolver: NeverCalledResolver(),
        cachedResolverFactory: { _ in NeverCalledResolver() },
        store: store,
        outputDirectorySettings: { OutputDirectorySettings(directory: unpreparable) },
        ensureAccess: { true }
    )

    let outcome = await coordinator.toggle()
    guard case .failed(_, let reason) = outcome else {
        Issue.record("expected the unpreparable directory to fail the recording, got \(outcome)")
        return
    }
    #expect(reason == .internalError)
}

@Test("The output directory is read FRESH on every recording, not cached from the coordinator's init")
func outputDirectoryIsReadFreshEachRecording() async throws {
    // Mirrors `humanCaptureOptions`'s own precedent for
    // `EventLoggingSettings`/`MicrophoneSettings`: changing the setting
    // between two recordings, with no new `RecordingCoordinator` built in
    // between, must change what the SECOND recording does. A coordinator
    // that captured `OutputDirectorySettings.load()` once at `init` would
    // use the FIRST directory both times, and the second `#expect` below
    // would fail — the blocked path would never be attempted.
    final class Box: @unchecked Sendable {
        var directory: URL
        init(_ directory: URL) { self.directory = directory }
    }

    let filePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-output-dir-test-fresh-\(UUID().uuidString)")
    try Data("blocks a directory from being created here".utf8).write(to: filePath)
    defer { try? FileManager.default.removeItem(at: filePath) }
    let blockedDirectory = filePath.appendingPathComponent("Recordings")

    let box = Box(FileManager.default.temporaryDirectory)
    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    let coordinator = RecordingCoordinator(
        pickerResolver: MarkerResolver(),
        cachedResolverFactory: { _ in MarkerResolver() },
        store: store,
        outputDirectorySettings: { OutputDirectorySettings(directory: box.directory) },
        ensureAccess: { true }
    )

    // First press: a good, writable directory. Directory preparation
    // succeeds, so this reaches `MarkerResolver`'s own thrown error.
    let first = await coordinator.toggle()
    guard case .failed(let firstMessage, _) = first else {
        Issue.record("expected MarkerResolver's own failure, got \(first)")
        return
    }
    #expect(firstMessage.contains("MarkerError"))

    // Change the setting, with no new coordinator — exactly what happens
    // when someone edits it in the Settings window between two hotkey
    // presses.
    box.directory = blockedDirectory
    let second = await coordinator.toggle()
    guard case .failed(_, let secondReason) = second else {
        Issue.record("expected the NEW directory's failure, got \(second)")
        return
    }
    #expect(secondReason == .internalError,
            "a coordinator that cached the first directory would reach MarkerResolver again here")
}

// Task 5's editor-on-stop tests live in `EditorWindowControllerTests.swift`,
// as an extension of that file's `@Suite(.serialized)` struct, not here.
// They construct real editor windows and read `EditorWindowController`'s
// process-global `openWindowCount`/activation-policy state — the exact state
// that suite already exists to serialize access to. A second, independent
// `@Suite(.serialized)` in THIS file would serialize its own tests against
// each other but not against that one; Swift Testing runs different suites
// concurrently by default, and the two suites did race in practice (observed
// via a failing `swift test` run before this comment was written) until the
// tests were merged into one suite.
