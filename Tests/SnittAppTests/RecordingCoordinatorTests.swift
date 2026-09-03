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
