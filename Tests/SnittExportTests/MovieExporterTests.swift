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
private func makeTestBundle(seconds: Double = 4, audioTrackCount: Int = 0) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds, audioTrackCount: audioTrackCount)
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
