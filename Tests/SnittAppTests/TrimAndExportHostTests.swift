import Testing
import Foundation
@testable import SnittApp
@testable import SnittAutomation
import SnittDocument

private func bundleWithMetadata(duration: Double, events: [LoggedEvent]) throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try RecordingMetadata(createdAt: Date(), initiator: .agent,
                          durationSeconds: duration).write(to: bundle)
    try EventLog(events: events).write(to: bundle)
    try EditDecisionList.fullRange().write(to: bundle)
    return bundle
}

@Test("Trimming to a range writes cuts into edit.json and leaves capture.mov alone")
func trimWritesTheEDL() async throws {
    let bundle = try bundleWithMetadata(duration: 30, events: [])
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: 5, end: 25, auto: false))

    guard case .trimmed(let summary) = response else {
        Issue.record("expected trimmed, got \(response)"); return
    }
    #expect(summary.cuts.count == 2)
    let written = try EditDecisionList.read(from: bundle)
    #expect(written.cuts == summary.cuts)
}

@Test("Auto-trim on a log with no input events is REFUSED, not applied")
func autoTrimRefusesWithoutInput() async throws {
    // §8: an agent's recording has no OS-level input, so its log holds only
    // markers. Trimming on that basis would delete the whole recording.
    let bundle = try bundleWithMetadata(
        duration: 30, events: [LoggedEvent(timeSeconds: 1, kind: .marker, label: "m")])
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: nil, end: nil, auto: true))

    guard case .failure(let error) = response else {
        Issue.record("auto-trim must refuse an empty input log"); return
    }
    #expect(error.hint != nil, "an agent needs to know why and what to do instead")
    let untouched = try EditDecisionList.read(from: bundle)
    #expect(untouched.cuts.isEmpty, "a refused trim must not have written anything")
}

@Test("A bad bundle path fails with an actionable error rather than crashing")
func trimOnMissingBundleFails() async {
    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: "/nope/missing.snitt", start: 0, end: 1, auto: false))
    guard case .failure(let error) = response else {
        Issue.record("expected a failure"); return
    }
    #expect(error.hint != nil)
}
