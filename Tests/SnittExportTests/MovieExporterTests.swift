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
    edl.cuts = [TimeRange(start: 0, end: 5)]
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
    edl.cuts = [TimeRange(start: 4, end: 6)]
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
    let unconstrained = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: unconstrainedOut)

    let target = 300_000
    let constrainedOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("con-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: constrainedOut) }
    let constrained = try await MovieExporter.export(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: constrainedOut,
        maxSizeBytes: target)

    #expect(constrained.byteSize <= target)
    #expect(constrained.maxSizeMet == true)
    // Proves work happened, not just that a number was reported: a no-op
    // implementation would produce (approximately) the SAME size as the
    // unconstrained export, since nothing would differ between the two
    // calls. Half is a generous margin against the ~700KB vs ~280KB
    // measured above.
    #expect(constrained.byteSize < unconstrained.byteSize / 2,
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
