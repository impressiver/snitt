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
        outputDirectory: FileManager.default.temporaryDirectory,
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
        outputDirectory: FileManager.default.temporaryDirectory,
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
        outputDirectory: FileManager.default.temporaryDirectory,
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
        outputDirectory: FileManager.default.temporaryDirectory,
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
        outputDirectory: FileManager.default.temporaryDirectory,
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
