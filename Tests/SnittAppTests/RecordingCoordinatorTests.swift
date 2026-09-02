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
