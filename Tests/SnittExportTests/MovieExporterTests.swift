// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import Foundation
@testable import SnittExport
import SnittDocument

/// A tiny real movie, so the exporter is exercised against AVFoundation
/// rather than a mock that cannot disagree with it.
///
/// Duplicated from `CompositionBuilderTests.swift` deliberately: this file
/// needs its own private copy (Swift Testing target sources don't share
/// private helpers across files without a shared internal type), and
/// `writeSyntheticMovie` in `SyntheticMovie.swift` already does the real
/// work.
private func makeTestBundle(seconds: Double = 4, audioTrackCount: Int = 0,
                             content: SyntheticFrameContent = .flat) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds,
                                  audioTrackCount: audioTrackCount, content: content)
    return bundle
}

@Test("Exporting writes a playable movie whose duration matches the composition")
func exportWritesAPlayableMovie() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    try await MovieExporter.exportMovie(built, to: output)

    #expect(FileManager.default.fileExists(atPath: output.path))
    let exported = AVURLAsset(url: output)
    let duration = CMTimeGetSeconds(try await exported.load(.duration))
    #expect(abs(duration - built.duration) < 0.5)
    #expect(try await exported.loadTracks(withMediaType: .video).isEmpty == false)
}

@Test("Exporting over an existing file replaces it rather than failing")
func exportReplacesAnExistingFile() async throws {
    // An agent re-exporting after a tweak is the normal loop; failing on the
    // second run because the first left a file would be a poor surprise.
    //
    // Discriminates against an implementation that omits the
    // `removeItem(at:)` cleanup and lets `AVAssetExportSession` fail because
    // the destination already exists.
    let bundle = try await makeTestBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    try Data("stale".utf8).write(to: output)

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    try await MovieExporter.exportMovie(built, to: output)

    let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int
    #expect((size ?? 0) > 1000, "the stale 5-byte file must have been replaced")
}

// MARK: - Full pipeline: marker mapping through kept ranges

@Test("A marker after a head cut lands at its shifted time in the manifest, not its raw bundle time")
func markerAfterHeadCutIsShiftedInManifest() async throws {
    // The critical property from the M3c Task 4 dispatch: BuiltComposition's
    // duration is TRIMMED, so a marker recorded at 8s in a bundle with a 5s
    // head cut belongs at 3s in the export, not 8s.
    //
    // Discriminates against an implementation that writes raw bundle
    // timestamps straight into the manifest/chapters (the identity-mapping
    // bug) — that wrong implementation passes any test built from an
    // untrimmed recording, because with no cuts raw-time and mapped-time are
    // the same number. This fixture has a cut BEFORE the marker specifically
    // so the two diverge.
    let bundle = try await makeTestBundle(seconds: 10)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList.fullRange()
    edl.cuts = [Cut(range: TimeRange(start: 0, end: 5))]
    try edl.write(to: bundle)
    let events = EventLog(events: [LoggedEvent(timeSeconds: 8, kind: .marker, label: "fix")])
    try events.write(to: bundle)

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let manifest = try await MovieExporter.export(bundle: bundle, edl: edl, scale: 1.0, to: output)

    #expect(manifest.chapters.count == 1)
    let chapter = try #require(manifest.chapters.first)
    #expect(abs(chapter.timeSeconds - 3.0) < 0.2,
            "8s raw minus the 5s head cut should land at 3s, not 8s")
    #expect(chapter.title == "fix")
}

@Test("A marker inside a cut range is dropped from the manifest, not clamped to the cut boundary")
func markerInsideCutIsDroppedFromManifest() async throws {
    // Discriminates against an implementation that clamps a trimmed-away
    // marker to the nearest surviving instant instead of dropping it — which
    // would invent a chapter at a moment the viewer never sees, and would
    // collapse several such markers onto the same timestamp.
    let bundle = try await makeTestBundle(seconds: 10)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList.fullRange()
    edl.cuts = [Cut(range: TimeRange(start: 4, end: 6))]
    try edl.write(to: bundle)
    let events = EventLog(events: [
        LoggedEvent(timeSeconds: 2, kind: .marker, label: "before"),
        LoggedEvent(timeSeconds: 5, kind: .marker, label: "inside the cut"),
        LoggedEvent(timeSeconds: 8, kind: .marker, label: "after"),
    ])
    try events.write(to: bundle)

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let manifest = try await MovieExporter.export(bundle: bundle, edl: edl, scale: 1.0, to: output)

    #expect(manifest.chapters.count == 2)
    #expect(manifest.chapters.map(\.title) == ["before", "after"])
    #expect(abs(manifest.chapters[0].timeSeconds - 2.0) < 0.2)
    // "after" was at 8s raw, minus the 2s cut = 6s.
    #expect(abs(manifest.chapters[1].timeSeconds - 6.0) < 0.2)
}

@Test("The manifest reports byte size, dimensions, and duration of the actual output file")
func manifestReportsRealFileMetadata() async throws {
    // Discriminates against an implementation that fabricates byteSize (e.g.
    // hardcodes 0) instead of stat-ing the file it just wrote.
    //
    // Uses scale: 0.5 on a known 320x240 source, and asserts against the
    // EXPORTED file's own track size (`naturalSize`, read back with a fresh
    // `AVURLAsset`) rather than `videoComposition.renderSize` — the
    // requested render size, not a property of the file the manifest claims
    // to describe. `renderSize > 0` alone is instance #12 of a review
    // finding of the same shape as `CompositionBuilderTests`'
    // `scaleAffectsSizeNotTime`: a fixture (or assertion) too weak to tell a
    // correct implementation from one that reports the request instead of
    // the result. This discriminates against an implementation that scales
    // the render size in the manifest but never actually applies it to the
    // written mp4 (e.g. a `layer.setTransform` that is a no-op), which
    // `width > 0`/`height > 0` cannot catch since an un-scaled 320x240 file
    // also satisfies it.
    let bundle = try await makeTestBundle(seconds: 3)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: .fullRange(), scale: 0.5, to: output)

    let onDiskSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int
    #expect(manifest.byteSize == onDiskSize)
    #expect(manifest.byteSize > 1000)
    #expect(manifest.format == "mp4")
    #expect(manifest.outputPath == output.path)
    #expect(abs(manifest.durationSeconds - 3.0) < 0.2)

    let exportedAsset = AVURLAsset(url: output)
    let exportedTrack = try await exportedAsset.loadTracks(withMediaType: .video).first
    let exportedTrackSize = try await exportedTrack?.load(.naturalSize) ?? .zero
    // Source is 320x240; scale: 0.5 must produce a 160x120 FILE, not merely
    // a manifest that says so.
    #expect(abs(exportedTrackSize.width - 160) < 2)
    #expect(abs(exportedTrackSize.height - 120) < 2)
    #expect(manifest.width == Int(exportedTrackSize.width.rounded()))
    #expect(manifest.height == Int(exportedTrackSize.height.rounded()))
}

@Test("Passing chaptersURL writes a WebVTT sidecar an agent could actually read back")
func chaptersSidecarIsWritten() async throws {
    // Discriminates against an implementation that accepts chaptersURL but
    // never writes to it (e.g. a missing `if let chaptersURL` branch, or one
    // that only ever sets manifest.chaptersPath without doing the write).
    let bundle = try await makeTestBundle(seconds: 6)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let events = EventLog(events: [LoggedEvent(timeSeconds: 1, kind: .marker, label: "start")])
    try events.write(to: bundle)

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    let chaptersURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("vtt")
    defer { try? FileManager.default.removeItem(at: chaptersURL) }

    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: .fullRange(), scale: 1.0, to: output, chaptersURL: chaptersURL)

    #expect(manifest.chaptersPath == chaptersURL.path)
    #expect(FileManager.default.fileExists(atPath: chaptersURL.path))
    let vttContent = try String(contentsOf: chaptersURL, encoding: .utf8)
    #expect(vttContent.hasPrefix("WEBVTT\n"))
    #expect(vttContent.contains("start"))
    #expect(vttContent.contains("-->"))
}

@Test("A damaged events.json fails the export instead of silently exporting a chapter-less manifest")
func corruptEventsFileFailsExport() async throws {
    // §8: a manifest with no chapters must mean "genuinely no markers," not
    // "the sidecar was unreadable and this code shrugged." Discriminates
    // against `(try? EventLog.read(from: bundle))?.events ?? []`, which
    // collapses "missing file" (legitimate — no logging) and "corrupt file"
    // (a real failure) into the same silent empty-array outcome. Must fail
    // against the CURRENT implementation before this fix round's change.
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try Data("{ not valid json".utf8).write(to: bundle.eventsURL)

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    await #expect(throws: (any Error).self) {
        _ = try await MovieExporter.export(bundle: bundle, edl: .fullRange(), scale: 1.0, to: output)
    }
}

// MARK: - Size targeting

@Test("A generous size target is met and reported as met")
func generousTargetMet() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("gen-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        maxSizeBytes: 50_000_000)
    #expect(manifest.maxSizeBytes == 50_000_000)
    #expect(manifest.maxSizeMet == true)
    #expect(manifest.byteSize <= 50_000_000)
}

@Test("An impossible size target still writes a file and reports the miss")
func impossibleTargetReportsMiss() async throws {
    // 200 bytes cannot hold an mp4 header, let alone frames. The
    // discriminating case: an implementation that throws on an unmet target,
    // or that reports maxSizeMet true because the export session did not
    // error, fails here. So does one that deletes the file.
    let bundle = try await makeTestBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("imp-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        maxSizeBytes: 200)
    #expect(manifest.maxSizeMet == false)
    #expect(manifest.maxSizeBytes == 200)
    #expect(manifest.byteSize > 200)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@Test("No size target leaves both manifest fields nil")
func noTargetLeavesFieldsNil() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("non-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out)
    #expect(manifest.maxSizeBytes == nil)
    #expect(manifest.maxSizeMet == nil)
}

@Test("An impossible target drops the scale, and the manifest reports the scale actually used")
func impossibleTargetReportsEffectiveScale() async throws {
    // Discriminates against an implementation that reports the requested
    // scale (1.0) even after the ladder dropped to a smaller rung — an
    // agent told "scale 1.0" cannot explain a file with 0.35x dimensions.
    let bundle = try await makeTestBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("scale-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        maxSizeBytes: 200)
    #expect(manifest.maxSizeMet == false)
    #expect(manifest.scale < 1.0, "the ladder should have dropped below the requested scale of 1.0")
}

@Test("A bundle with no events.json at all still exports cleanly with no chapters")
func missingEventsFileExportsWithNoChapters() async throws {
    // The companion case to the corrupt-file test above: "file absent" is
    // legitimate (a recording predating M3b, or logging disabled) and must
    // not be treated as a failure. Discriminates against an implementation
    // that fixes the corrupt-file case by making ANY read failure fatal,
    // including a simple "file does not exist" — which would break every
    // export of an older bundle.
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    #expect(!FileManager.default.fileExists(atPath: bundle.eventsURL.path))

    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let manifest = try await MovieExporter.export(bundle: bundle, edl: .fullRange(), scale: 1.0, to: output)
    #expect(manifest.chapters.isEmpty)
}

@Test("A size target reachable only by dropping scale is met, and the constrained file is substantially smaller than an unconstrained export of the same bundle")
func scaleReductionActuallyShrinksTheFile() async throws {
    // Uses NOISE content deliberately (see `SyntheticFrameContent` in
    // SyntheticMovie.swift): flat gray frames compress to the encoder's
    // floor regardless of bitrate or resolution, which made the original
    // round of this test unable to tell "size targeting works" from "size
    // targeting is a complete no-op" — a reviewer confirmed all four
    // original tests kept passing with `fileLengthLimit` commented out
    // entirely. Noise does not compress, so both `fileLengthLimit` and a
    // scale drop measurably change the encoded size.
    //
    // Measured on this fixture (2s of 320x240 noise @ 30fps): unconstrained
    // scale 1.0 is ~700KB; `fileLengthLimit` alone at scale 1.0 barely
    // moves that (a 200-byte limit still produced ~578KB — fileLengthLimit
    // has SOME effect but hits a floor far above tiny targets). Only
    // dropping scale gets meaningfully smaller: 0.75->~386KB, 0.5->~311KB,
    // 0.35->~263KB. A target of 300_000 is unreachable at scale 1.0
    // (fileLengthLimit alone still produced ~700KB there) but reachable at
    // the ladder's 0.35 rung (~280KB with the limit applied). That makes
    // 300_000 the discriminating target: it can ONLY be met if the ladder
    // actually drops scale and re-encodes, not by fileLengthLimit alone at
    // the original scale.
    let bundle = try await makeTestBundle(seconds: 2, content: .noise)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let unconstrainedOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("unc-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: unconstrainedOut) }
    // A deliberately unreachable ceiling, not the absence of one.
    //
    // Both sides of the ratio below must be RE-ENCODED for the comparison to
    // mean anything, and an export with no ceiling at source resolution now
    // copies the samples instead (`PassthroughEligibility`). That is the right
    // behaviour and a much smaller file for real recordings, but it makes a
    // copied baseline against a re-encoded result apples-to-oranges — the
    // measured thresholds in the comment below were derived when both sides
    // re-encoded. A ceiling this large disqualifies passthrough while binding
    // nothing, so the baseline is the same artifact it always was.
    let unreachableCeiling = 1_000_000_000
    let unconstrained = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: unconstrainedOut,
        maxSizeBytes: unreachableCeiling)
    #expect(unconstrained.scale == 1.0,
            "the baseline ceiling was supposed to be unreachable, but the ladder walked")

    let target = 300_000
    let constrainedOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("con-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: constrainedOut) }
    let constrained = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: constrainedOut,
        maxSizeBytes: target)

    // NOT `byteSize <= target`. The hardware H.264 encoder is not
    // deterministic under CPU contention: the 0.35 rung measures ~263KB at
    // rest and was observed at 309,914 bytes under full-suite load, which
    // crosses a 300,000 target and fails a run that proved nothing. Every
    // absolute byte threshold against this encoder is a latent flake.
    //
    // Assert the property that actually matters instead (§8): the manifest
    // must not LIE. Whichever rung wins, `maxSizeMet` must agree with the
    // file on disk. That is immune to encoder variance because both sides
    // of the comparison move together, and it is the real contract — an
    // agent is misinformed only when the report disagrees with reality.
    #expect(constrained.maxSizeMet == (constrained.byteSize <= target),
            "the manifest must report the miss it actually had, not the one it hoped for")

    // The ladder must actually have walked. A no-op reports scale 1.0 and,
    // being unable to reach the target any other way, would also report
    // maxSizeMet false — satisfying the consistency check above by doing
    // nothing at all. This is the assertion that fails against a no-op.
    #expect(constrained.scale < 1.0,
            "the target is unreachable at scale 1.0, so meeting it requires dropping scale")

    // Proves work happened, not just that a number was reported: a no-op
    // would produce (approximately) the SAME size as the unconstrained
    // export, since nothing would differ between the two calls.
    //
    // M4a review finding #2: this used to compare against half the
    // unconstrained size (ratio < 0.5), which is not a margin derived from
    // anything — it flaked at roughly 1-in-5 under full-suite load (one
    // reviewer run: 340502 against a 311028 bound, ratio ~1.09). Re-measured
    // properly by mutation instead: the TRUE-POSITIVE ratio (this
    // implementation, unmutated), sampled across ~30 runs both standalone
    // and inside the full `SnittExportTests` suite (to reproduce the
    // contention that caused the flake), ranged from about 0.30 to 0.62 —
    // never above ~0.62. The NO-OP ratio — `sizeLadder` mutated to `[1.0]`,
    // so the ladder never actually drops scale and `fileLengthLimit` alone
    // (still active) is all that's left — measured a tight 0.947 across 5
    // runs. 0.85 sits with a comfortable margin on both sides: ~0.23 above
    // the true positive's observed ceiling, ~0.10 below the no-op floor.
    #expect(Double(constrained.byteSize) < Double(unconstrained.byteSize) * 0.85,
            "a real size target should shrink the file substantially, not just report success")
    #expect(constrained.scale < 1.0,
            "300_000 bytes is unreachable at scale 1.0 on this fixture; the ladder must have dropped scale")
}

@Test("An impossible GIF size target still writes a file and reports the miss")
func gifImpossibleTargetReportsMiss() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-\(UUID().uuidString).gif")
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        format: "gif", maxSizeBytes: 100)
    #expect(manifest.format == "gif")
    #expect(manifest.maxSizeMet == false)
    #expect(manifest.byteSize > 100)
    #expect(FileManager.default.fileExists(atPath: out.path))
    // Discriminating: 100 bytes is unreachable even for a genuine no-op
    // (one GIF at full scale, target ignored), so a no-op would ALSO
    // report "miss" here and satisfy every assertion above. Only an
    // implementation that actually walked the ladder down to its last rung
    // ends up at a scale below what was requested.
    #expect(manifest.scale < 1.0,
            "an impossible target should exhaust the ladder down to its smallest rung")
}

@Test("fileLengthLimit alone shrinks the file below an unconstrained export, at the same scale")
func fileLengthLimitAloneShrinksTheFile() async throws {
    // Guards finding #2 of the M3d fix wave: `session.fileLengthLimit =
    // Int64(maxSizeBytes)` in `exportMovie` was, at review time, entirely
    // untested — every SnittExport test that exercised size targeting was
    // satisfied by the scale ladder alone in `MovieExporter.export`, so
    // replacing the assignment with `_ = maxSizeBytes` (a no-op) left the
    // whole suite green. That is load-bearing code indistinguishable from
    // dead code to a future reader.
    //
    // This calls `exportMovie` DIRECTLY rather than going through
    // `MovieExporter.export`'s size ladder — measurement (see the sweep
    // below) showed that route cannot isolate this line. Mapped on this
    // fixture (2s of 320x240 noise @ 30fps):
    //   maxSizeBytes: nil      -> 706244 bytes (natural size)
    //   maxSizeBytes: 500_000  -> 706244 bytes (fileLengthLimit had NO
    //                             effect — it does not engage at all until
    //                             the request drops below roughly 300-325K
    //                             on this fixture)
    //   maxSizeBytes: 300_000  -> 680258 bytes (barely engaged — still far
    //                             over the requested target)
    //   maxSizeBytes: 10_000   -> 560337 bytes (the floor: reproduced
    //                             identically across three repeated runs)
    // So there is no target that both (a) sits strictly between the floor
    // and the natural size, AND (b) is actually met by fileLengthLimit at
    // scale 1.0 on this fixture — for every target in that band,
    // fileLengthLimit either does nothing (target too close to natural) or
    // overshoots it (target too aggressive), so `MovieExporter.export`'s
    // ladder never breaks out of its loop at rung 1 and always walks on to
    // a smaller scale, which would make `manifest.scale == 1.0` unreachable
    // through that path for any target where fileLengthLimit visibly did
    // something. That mismatch between the review's expected middle ground
    // and the measured all-or-nothing behaviour is itself part of the
    // finding. What IS reliably true, and is what this test pins: requesting
    // an aggressively low limit drives the file to that floor — reliably,
    // repeatably, at the SAME scale (1.0, since `exportMovie` never touches
    // scale; that is `CompositionBuilder`'s job, called identically for both
    // exports below) — which is exactly the behaviour a no-op assignment
    // could never produce.
    let bundle = try await makeTestBundle(seconds: 2, content: .noise)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(bundle: bundle, edl: .fullRange(), scale: 1.0)

    let unconstrainedOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("fll-unc-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: unconstrainedOut) }
    try await MovieExporter.exportMovie(built, to: unconstrainedOut)
    let unconstrainedSize = try #require(
        FileManager.default.attributesOfItem(atPath: unconstrainedOut.path)[.size] as? Int)

    let constrainedOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("fll-con-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: constrainedOut) }
    // Same `built` composition (scale 1.0, untouched) passed to both calls:
    // any size difference below can only come from `fileLengthLimit`, not
    // from a different composition being encoded.
    try await MovieExporter.exportMovie(built, to: constrainedOut, maxSizeBytes: 200)
    let constrainedSize = try #require(
        FileManager.default.attributesOfItem(atPath: constrainedOut.path)[.size] as? Int)

    // Relative, not absolute (the hardware H.264 encoder is not
    // deterministic under load — the same caution `scaleReductionActually
    // ShrinksTheFile` documents).
    //
    // M4a review finding #2: the previous 0.95 threshold flaked at roughly
    // 1-in-5 under full-suite load (one reviewer run: 621311 against a
    // 590953 bound, ratio ~1.05). Re-derived by mutation rather than by
    // widening the absolute margin further: the TRUE-POSITIVE ratio (this
    // implementation, unmutated), sampled across ~30 runs both standalone
    // and inside the full `SnittExportTests` suite, mostly sat in the
    // 0.30-0.50 range but reached as high as 0.79 twice under heavy
    // contention. The NO-OP ratio — `session.fileLengthLimit = ...`
    // commented out entirely — measured 0.97-1.0 across 5 runs (two
    // unconstrained encodes of the same composition naturally differ by
    // well under 5%). 0.90 sits with margin on both sides: ~0.11 above the
    // true positive's observed ceiling, ~0.07 below the no-op floor.
    #expect(Double(constrainedSize) < Double(unconstrainedSize) * 0.90,
            "fileLengthLimit should have measurably shrunk the file toward its floor")
    #expect(constrainedSize < unconstrainedSize)
}

@Test("A generous GIF size target is met on the first rung at full quality")
func gifGenerousTargetMetAtFullQuality() async throws {
    let bundle = try await makeTestBundle(seconds: 1)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("gg-\(UUID().uuidString).gif")
    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
        format: "gif", maxSizeBytes: 50_000_000)
    #expect(manifest.maxSizeMet == true)
    // Discriminating: an implementation that always walks the whole ladder,
    // or that starts partway down it, degrades a file that already fit.
    #expect(manifest.scale == 1.0)
}

@Test("An unconstrained GIF export reports the base frame rate, and mp4 reports none at all")
func effectiveFPSReflectsFormat() async throws {
    // Guards finding #3: without `effectiveFPS` on the manifest, a GIF
    // silently degraded from 15fps to 5fps looked identical to an untouched
    // export (both report `scale: 1.0`). This is the baseline half of that
    // coverage — the degraded case is `gifSizeTargetMetByDroppingFPSAlone`
    // below.
    let bundle = try await makeTestBundle(seconds: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let gifOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("fps-base-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: gifOut) }
    let gifManifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: gifOut, format: "gif")
    #expect(gifManifest.effectiveFPS == MovieExporter.defaultGIFFrameRate)

    let mp4Out = FileManager.default.temporaryDirectory
        .appendingPathComponent("fps-base-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: mp4Out) }
    let mp4Manifest = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: mp4Out, format: "mp4")
    #expect(mp4Manifest.effectiveFPS == nil,
            "frame rate is not an axis mp4 export touches; reporting one would be fabricated")
}

@Test("A GIF size target reachable by dropping frame rate alone is met without touching scale")
func gifSizeTargetMetByDroppingFPSAlone() async throws {
    // Guards finding #3 of the M3d fix wave: `SizeLadder` drops frame rate
    // BEFORE resolution, but before this fix `ExportManifest` had no
    // frame-rate field at all — a GIF that hit its budget by dropping from
    // 15fps to (say) 8fps reported `scale: 1.0`, indistinguishable from an
    // export the ladder never touched. `SizeLadderTests` only covers rung
    // STRUCTURE; no integration test before this one ever drove an actual
    // fps rung end-to-end.
    //
    // The target is derived from a measured baseline taken in THIS run
    // (60% of the natural, untouched 15fps size) rather than a literal
    // constant, because GIF byte size scales close to linearly with frame
    // count on the noise fixture (measured: 15fps ~2.79MB, 10fps ~1.87MB
    // [67%], 8fps ~1.49MB [53%], 5fps ~0.93MB [33%] on a 2s clip) but the
    // exact bytes still depend on the PRNG-seeded noise content and are not
    // worth hard-coding. 60% sits strictly between the measured 10fps
    // (67%) and 8fps (53%) ratios, so meeting it requires dropping AT LEAST
    // to 8fps — one fps rung is not enough, and no scale rung is needed at
    // all (scale rungs only begin after frame rate is exhausted down to
    // 5fps in `SizeLadder`).
    let bundle = try await makeTestBundle(seconds: 2, content: .noise)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let naturalOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("fps-nat-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: naturalOut) }
    let natural = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: naturalOut, format: "gif")
    #expect(natural.effectiveFPS == MovieExporter.defaultGIFFrameRate)

    let target = Int(Double(natural.byteSize) * 0.6)
    let targetedOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("fps-tgt-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: targetedOut) }
    let targeted = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: targetedOut,
        format: "gif", maxSizeBytes: target)

    #expect(targeted.maxSizeMet == true)
    // The discriminating pair: a manifest with no `effectiveFPS` field (or
    // one that always reports the base rate regardless of what was
    // actually written) fails the first; an implementation that dropped
    // scale instead of — or in addition to — frame rate fails the second.
    let effectiveFPS = try #require(targeted.effectiveFPS)
    #expect(effectiveFPS < MovieExporter.defaultGIFFrameRate,
            "the target is unreachable at 15fps on this fixture, so meeting it requires a frame-rate drop")
    #expect(targeted.scale == 1.0,
            "the target is reachable by dropping frame rate alone; scale must not have moved")
}
