import Testing
import Foundation
@testable import SnittApp
@testable import SnittAutomation
import SnittDocument

private func bundleWithMetadata(duration: Double, events: [LoggedEvent],
                                movieSeconds: Double? = nil) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    // A real capture.mov, not just meta.json: `AutomationHost.trim` now
    // computes duration from the asset, the same clock `export` uses (see
    // `wallAndMediaDurationsDisagreeButTrimAndExportMustAgree` below), so a
    // trim test with no movie at all can no longer exercise the real path.
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: movieSeconds ?? duration)
    try RecordingMetadata(createdAt: Date(), initiator: .agent,
                          durationSeconds: duration).write(to: bundle)
    try EventLog(events: events).write(to: bundle)
    try EditDecisionList.fullRange().write(to: bundle)
    return bundle
}

@Test("Trimming to a range writes cuts into edit.json and leaves capture.mov alone")
func trimWritesTheEDL() async throws {
    let bundle = try await bundleWithMetadata(duration: 10, events: [])
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: 2, end: 8, auto: false))

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
    let bundle = try await bundleWithMetadata(
        duration: 10, events: [LoggedEvent(timeSeconds: 1, kind: .marker, label: "m")])
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

@Test("A bundle with no capture.mov fails trim explicitly rather than reporting a wall-clock number as media time")
func trimOnMetadataOnlyBundleFailsExplicitly() async throws {
    // §8: an agent must never be confidently misinformed. Before this fix,
    // trim happily computed keptSeconds/cutSeconds from
    // meta.durationSeconds when capture.mov was absent — a number that
    // cannot possibly match anything an export would produce, since there
    // is no capture.mov to export from at all. The chosen behaviour is to
    // FAIL the trim, with a hint distinct from "bad path", rather than
    // silently fall back to the wall clock.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try RecordingMetadata(createdAt: Date(), initiator: .agent,
                          durationSeconds: 30).write(to: bundle)
    try EditDecisionList.fullRange().write(to: bundle)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: 1, end: 5, auto: false))

    guard case .failure(let error) = response else {
        Issue.record("trim without a readable capture.mov must fail, not report a wall-clock duration"); return
    }
    #expect(error.hint != nil)
    let untouched = try EditDecisionList.read(from: bundle)
    #expect(untouched.cuts.isEmpty, "a refused trim must not have written anything")
}

@Test("Trim's keptSeconds and export's durationSeconds agree on one bundle, even though meta.json's wall clock and capture.mov's media clock do not")
func wallAndMediaDurationsDisagreeButTrimAndExportMustAgree() async throws {
    // The whole-branch review finding: `AutomationHost.trim` used to compute
    // duration from `RecordingMetadata.durationSeconds` (WALL time, stamped
    // around the capture) while `CompositionBuilder.build` computes it from
    // `AVURLAsset.duration` (MEDIA time). The two are never equal on a real
    // recording — wall always overstates by the stream's startup latency.
    //
    // This is the join no per-task test performed: `TrimAndExportHostTests`
    // built metadata-only bundles (no capture.mov); `MovieExporterTests`
    // built movie-only bundles (no meta.json). Neither could see the two
    // clocks disagree. This bundle has BOTH, with durations that are
    // deliberately, verifiably different — a movie exactly 4.0s long, but a
    // meta.json wall-clock duration of 4.25s, matching the review's own
    // reproduction. If the two durations were left equal here, this test
    // would pass against the old, broken code too, and prove nothing.
    let movieSeconds = 4.0
    let wallSeconds = 4.25
    #expect(wallSeconds != movieSeconds, "this test is meaningless if the two clocks happen to agree")
    let bundle = try await bundleWithMetadata(
        duration: wallSeconds, events: [], movieSeconds: movieSeconds)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let trimResponse = await host.handle(
        .trim(bundlePath: bundle.url.path, start: 1, end: nil, auto: false))
    guard case .trimmed(let summary) = trimResponse else {
        Issue.record("expected trimmed, got \(trimResponse)"); return
    }

    // Before the fix: end defaults to the WALL duration (4.25), so
    // keptSeconds comes out to 3.25 — a number capture.mov cannot produce,
    // since it is only 4.0s long to begin with.
    #expect(abs(summary.keptSeconds - 3.0) < 0.05,
            "trim must default the open end to the MEDIA duration (4.0s), not the wall-clock one (4.25s)")

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    let exportResponse = await host.handle(
        .export(bundlePath: bundle.url.path, format: "mp4", outputPath: output.path,
               scale: 1.0, chapters: false))
    guard case .exported(let manifest) = exportResponse else {
        Issue.record("expected exported, got \(exportResponse)"); return
    }

    // The agent-facing claim (`keptSeconds`) and the file it actually gets
    // (`manifest.durationSeconds`) must describe the same recording.
    // Pre-fix this was 3.25 vs 3.0 — reproducing the review's own numbers.
    #expect(abs(summary.keptSeconds - manifest.durationSeconds) < 0.1,
            "trim reported \(summary.keptSeconds)s kept, but the exported file is \(manifest.durationSeconds)s — the agent was told a number the file does not have")
}
