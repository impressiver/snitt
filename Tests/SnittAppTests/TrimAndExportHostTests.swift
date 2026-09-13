// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
        .trim(bundlePath: bundle.url.path, start: 2, end: 8, auto: false), caller: nil)

    guard case .trimmed(let summary) = response else {
        Issue.record("expected trimmed, got \(response)"); return
    }
    #expect(summary.cuts.count == 2)
    let written = try EditDecisionList.read(from: bundle)
    #expect(written.cuts.map(\.range) == summary.cuts)
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
        .trim(bundlePath: bundle.url.path, start: nil, end: nil, auto: true), caller: nil)

    guard case .failure(let error) = response else {
        Issue.record("auto-trim must refuse an empty input log"); return
    }
    #expect(error.hint != nil, "an agent needs to know why and what to do instead")
    let untouched = try EditDecisionList.read(from: bundle)
    #expect(untouched.cuts.isEmpty, "a refused trim must not have written anything")
}

@Test("Auto-trim preserves a manually made interior cut instead of replacing the whole cuts array")
func autoTrimPreservesManualInteriorCuts() async throws {
    // Decision (D60, auto-trim half): `--auto-trim` is NOT a wholesale
    // "replace all cuts" operation. `EditDecisionList.autoTrimRange` only
    // ever computes new head/tail bookends from event timestamps — exactly
    // what a manual `--start`/`--end` trim computes from typed numbers — so
    // `AutomationHost.trim` routes BOTH branches through the same
    // `existing.trimmed(keeping:duration:)` merge. Before this fix, the
    // auto branch wrote `EditDecisionList.autoTrimCuts(...)`'s result
    // straight over `updated.cuts`, discarding whatever interior cuts the
    // GUI (or an earlier manual trim) had already made — the identical
    // D60 bug, on the `auto` branch of the same `if` in
    // `AutomationHost.trim` that the manual branch had.
    let events = [
        LoggedEvent(timeSeconds: 5, kind: .keystroke, label: nil),
        LoggedEvent(timeSeconds: 20, kind: .keystroke, label: nil),
    ]
    let bundle = try await bundleWithMetadata(duration: 30, events: events)
    // Overwrite the fresh full-range EDL `bundleWithMetadata` wrote with one
    // that already carries a manual interior cut, as if made in the GUI.
    let guiMade = Cut(range: TimeRange(start: 10, end: 12))
    try EditDecisionList(cuts: [guiMade]).write(to: bundle)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: nil, end: nil, auto: true), caller: nil)

    guard case .trimmed(let summary) = response else {
        Issue.record("expected trimmed, got \(response)"); return
    }
    #expect(summary.cuts.contains(TimeRange(start: 10, end: 12)),
            "the manual interior cut must survive an auto-trim, got \(summary.cuts)")
    let written = try EditDecisionList.read(from: bundle)
    #expect(written.cuts.map(\.range) == summary.cuts, "the written edit.json must match what was reported")
    // §4.8/§6: the CLI and the GUI drive ONE shared model, not two — a cut
    // the GUI created and the CLI never touched (it never overlapped either
    // auto-trim bookend) must come back through the CLI's own write with
    // the SAME id it went in with, not one the CLI minted along the way.
    #expect(written.cuts.contains { $0.id == guiMade.id },
            "a CLI trim must preserve the id of a cut it did not itself create, got \(written.cuts)")
}

@Test("A bad bundle path fails with an actionable error rather than crashing")
func trimOnMissingBundleFails() async {
    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: "/nope/missing.snitt", start: 0, end: 1, auto: false), caller: nil)
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
        .trim(bundlePath: bundle.url.path, start: 1, end: 5, auto: false), caller: nil)

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
        .trim(bundlePath: bundle.url.path, start: 1, end: nil, auto: false), caller: nil)
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
        .export(bundlePath: bundle.url.path, format: "mp4", outputPath: output.path, scale: 1.0, chapters: false, subtitles: false, maxSizeBytes: nil, resolution: .source, clicks: false), caller: nil)
    guard case .exported(let manifest) = exportResponse else {
        Issue.record("expected exported, got \(exportResponse)"); return
    }

    // The agent-facing claim (`keptSeconds`) and the file it actually gets
    // (`manifest.durationSeconds`) must describe the same recording.
    // Pre-fix this was 3.25 vs 3.0 — reproducing the review's own numbers.
    #expect(abs(summary.keptSeconds - manifest.durationSeconds) < 0.1,
            "trim reported \(summary.keptSeconds)s kept, but the exported file is \(manifest.durationSeconds)s — the agent was told a number the file does not have")
}

@Test("A corrupt edit.json fails export explicitly rather than silently exporting the full range")
func exportWithCorruptEDLFailsExplicitly() async throws {
    // Guards finding #6 of the M3d fix wave: `AutomationHost.export` used to
    // read the EDL with `(try? EditDecisionList.read(from: bundle)) ??
    // .fullRange()`, which collapses "no edit.json" (legitimate — nothing
    // has trimmed this recording yet) and "edit.json exists but is corrupt"
    // (a real failure) into the same "export the whole recording" outcome.
    // The same collapse `MovieExporter.readBundleEvents` was fixed to avoid
    // for `events.json`, two files away. A corrupt EDL exporting the full
    // recording and reporting success would silently discard whatever trim
    // the recording actually had.
    let bundle = try await bundleWithMetadata(duration: 4, events: [])
    // Overwrite the well-formed edit.json `bundleWithMetadata` wrote with
    // something that is present but not valid EditDecisionList JSON.
    try Data("{ not valid json".utf8).write(to: bundle.editURL)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .export(bundlePath: bundle.url.path, format: "mp4", outputPath: output.path, scale: 1.0, chapters: false, subtitles: false, maxSizeBytes: nil, resolution: .source, clicks: false), caller: nil)

    guard case .failure(let error) = response else {
        Issue.record("export with a corrupt edit.json must fail, not silently export the full range"); return
    }
    #expect(error.hint != nil, "an agent needs to know why, and that its trim was not silently discarded")
    #expect(!FileManager.default.fileExists(atPath: output.path),
            "a refused export must not have written a file")
}

@Test("A missing edit.json still exports cleanly at the full range")
func exportWithNoEDLFileExportsFullRange() async throws {
    // The companion case to the corrupt-EDL test above: "no edit.json at
    // all" is legitimate (a fresh recording nobody has trimmed yet) and
    // must not be treated as a failure — the same "absent is not corrupt"
    // distinction `MovieExporter`'s events.json handling draws.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2)
    try RecordingMetadata(createdAt: Date(), initiator: .agent,
                          durationSeconds: 2).write(to: bundle)
    // Deliberately no `EditDecisionList.write(to:)` call — edit.json does
    // not exist on disk.
    #expect(!FileManager.default.fileExists(atPath: bundle.editURL.path))
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .export(bundlePath: bundle.url.path, format: "mp4", outputPath: output.path, scale: 1.0, chapters: false, subtitles: false, maxSizeBytes: nil, resolution: .source, clicks: false), caller: nil)

    guard case .exported(let manifest) = response else {
        Issue.record("expected exported, got \(response)"); return
    }
    #expect(abs(manifest.durationSeconds - 2.0) < 0.2)
}

@Test("A corrupt edit.json fails trim explicitly rather than silently trimming from a fresh full range")
func trimWithCorruptEDLFailsExplicitly() async throws {
    // Same class of bug as `exportWithCorruptEDLFailsExplicitly` above, at
    // the sibling call site the whole-branch review did not name — `trim`
    // had the identical `(try? EditDecisionList.read(from: bundle)) ??
    // .fullRange()` line as `export`. Arguably worse here: a corrupt EDL at
    // export merely renders the wrong range once, but trim WRITES the
    // reconstructed-from-scratch range back to edit.json, permanently
    // discarding whatever real trim state the file had.
    let bundle = try await bundleWithMetadata(duration: 10, events: [])
    try Data("{ not valid json".utf8).write(to: bundle.editURL)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: 2, end: 8, auto: false), caller: nil)

    guard case .failure(let error) = response else {
        Issue.record("trim with a corrupt edit.json must fail, not silently trim from a fresh full range"); return
    }
    #expect(error.hint != nil, "an agent needs to know why, and that its existing trim state was not silently discarded")

    // The strongest form of the assertion: the corrupt file must be left
    // exactly as it was, byte for byte — not overwritten with a
    // reconstructed-from-.fullRange() result.
    let onDisk = try String(contentsOf: bundle.editURL, encoding: .utf8)
    #expect(onDisk == "{ not valid json",
            "a refused trim must not have touched the corrupt edit.json it could not read")
}

@Test("A corrupt events.json fails auto-trim explicitly rather than refusing as if the log were merely empty")
func autoTrimWithCorruptEventsFailsExplicitly() async throws {
    // Same class again, at the third and last site in this file: auto-trim
    // used to fold a corrupt `events.json` into "zero events" via `(try?
    // EventLog.read(from: bundle))?.events ?? []`, which `autoTrimCuts`
    // then reports as `AutoTrimError.noInputEvents` — a plausible-sounding
    // but WRONG explanation ("this recording has no input") for what is
    // actually "this recording's event log is damaged". Discriminates
    // against the `try? ... ?? []` form, which passes this bundle through
    // to the noInputEvents refusal instead of surfacing the read failure.
    let bundle = try await bundleWithMetadata(duration: 10, events: [])
    try Data("{ not valid json".utf8).write(to: bundle.eventsURL)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(
        .trim(bundlePath: bundle.url.path, start: nil, end: nil, auto: true), caller: nil)

    guard case .failure(let error) = response else {
        Issue.record("auto-trim with a corrupt events.json must fail, not report a misleading 'no input events'"); return
    }
    #expect(error.message != "This recording logged no input events, so there is nothing "
                            + "to auto-trim against.",
            "a corrupt log must not be reported as an empty one — those are different failures with different fixes")
    #expect(error.hint != nil)
}

@Test("snitt inspect on a future-schemaVersion events.json fails explicitly rather than reporting zero markers")
func inspectWithFutureSchemaEventsFailsExplicitly() async throws {
    // D60/M5f Task 7, end to end through the same seam `AutomationHost`
    // exposes to the CLI/MCP frontends (§8): `InspectReport.report(for:)`
    // used to fold a future-schemaVersion events.json into "zero events"
    // via `(try? EventLog.read(from: bundle))?.events ?? []` — the same
    // collapsing class this file already pins for auto-trim, one call site
    // over. An agent asking `snitt inspect` about a recording a NEWER
    // Snitt build had already marked up would be told "no markers" instead
    // of "your build cannot read this recording's markers" — a wrong
    // answer that looks like a right one. Verified to fail against that
    // exact collapsing form: it would return `.inspected` with
    // `markerCount == 0` instead of `.failure`.
    let bundle = try await bundleWithMetadata(duration: 10, events: [])
    try Data(#"{"schemaVersion":99,"events":[]}"#.utf8).write(to: bundle.eventsURL)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let host = AutomationHost.forTesting()
    let response = await host.handle(.inspect(bundlePath: bundle.url.path), caller: nil)

    guard case .failure(let error) = response else {
        Issue.record("inspect on a future-schemaVersion events.json must fail, not report an empty marker list"); return
    }
    #expect(error.hint != nil, "an agent needs to know why, not just that it failed")
}
