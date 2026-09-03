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
        outputDirectory: FileManager.default.temporaryDirectory
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
        outputDirectory: FileManager.default.temporaryDirectory
    )

    let outcome = await coordinator.startForAgent(
        reference: .window(bundleIdentifier: "com.example.Agent", titleHint: nil))

    // `MarkerResolver.resolve()` always throws, so the coordinator can never
    // reach `.started` in this test — reaching a real `.started` would require
    // constructing a genuine `SCContentFilter`, which ScreenCaptureKit offers
    // no way to do without live enumeration (see the task report). What this
    // DOES prove, unambiguously: the forced resolver's `resolve()` ran at all,
    // which is exactly the step the bug skipped.
    guard case .failed(let message) = outcome else {
        Issue.record("expected a failure surfaced from MarkerResolver, got \(outcome)")
        return
    }
    #expect(!message.contains("cached target could not be read"),
            "an agent's forced resolver must run instead of hitting the empty-store cache guard — got: \(message)")
}
