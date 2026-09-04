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
private func makeTestBundle(seconds: Double = 4, audioTrackCount: Int = 0) throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try writeSyntheticMovie(to: bundle.captureURL, seconds: seconds, audioTrackCount: audioTrackCount)
    return bundle
}

@Test("Exporting writes a playable movie whose duration matches the composition")
func exportWritesAPlayableMovie() async throws {
    let bundle = try makeTestBundle(seconds: 4)
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
    let bundle = try makeTestBundle(seconds: 2)
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
    let bundle = try makeTestBundle(seconds: 10)
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
    let bundle = try makeTestBundle(seconds: 10)
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
    let bundle = try makeTestBundle(seconds: 3)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    defer { try? FileManager.default.removeItem(at: output) }

    let manifest = try await MovieExporter.export(
        bundle: bundle, edl: .fullRange(), scale: 1.0, to: output)

    let onDiskSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int
    #expect(manifest.byteSize == onDiskSize)
    #expect(manifest.byteSize > 1000)
    #expect(manifest.format == "mp4")
    #expect(manifest.outputPath == output.path)
    #expect(abs(manifest.durationSeconds - 3.0) < 0.2)
    #expect(manifest.width > 0)
    #expect(manifest.height > 0)
}
