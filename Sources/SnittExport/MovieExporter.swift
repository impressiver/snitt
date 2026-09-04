import AVFoundation
import Foundation
import SnittDocument

public enum ExportError: Error, Equatable {
    case noExportSession
    case sessionFailed(String)
}

/// Writes a composition to an mp4, and assembles the manifest an agent uses
/// to describe what it made without watching it (§8).
///
/// `exportMovie` takes a `BuiltComposition` rather than a bundle, so it
/// cannot construct its own composition and drift from what preview shows
/// (§9).
public enum MovieExporter {
    public static func exportMovie(_ built: BuiltComposition, to url: URL) async throws {
        // Re-exporting after a tweak is the normal loop; a stale file from
        // the previous run must not fail the next one.
        try? FileManager.default.removeItem(at: url)

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.noExportSession }

        session.videoComposition = built.videoComposition

        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            throw ExportError.sessionFailed(String(describing: error))
        }
    }

    /// The full pipeline: build the composition, write the mp4, map markers
    /// from bundle time into export time, optionally write a WebVTT chapters
    /// sidecar, and return the manifest.
    ///
    /// This is the entry point that produces `chapters` correctly. Calling
    /// `exportMovie` directly (as `CompositionBuilder`'s own caller in M4's
    /// preview path might, for a scrub-only use) skips manifest assembly
    /// entirely, which is why it stays a separate, lower-level function
    /// rather than folding manifest construction into it.
    public static func export(bundle: SnittBundle,
                              edl: EditDecisionList,
                              scale: Double,
                              to outputURL: URL,
                              chaptersURL: URL? = nil) async throws -> ExportManifest {
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
        try await exportMovie(built, to: outputURL)

        // Re-derive the exact kept ranges the composition was built from —
        // not just KeptRanges.compute's raw output — because
        // CompositionBuilder additionally drops kept ranges shorter than one
        // frame. Using a different set here would let a marker map onto a
        // position that does not exist in the file just written.
        let sourceAsset = AVURLAsset(url: bundle.captureURL)
        let sourceDuration = CMTimeGetSeconds(try await sourceAsset.load(.duration))
        let keptRanges = KeptRanges.compute(duration: sourceDuration, cuts: edl.cuts)
            .filter { $0.end - $0.start >= CompositionBuilder.minimumKeptDuration }

        let bundleEvents = (try? EventLog.read(from: bundle))?.events ?? []
        let mappedMarkers = MarkerMapping.map(bundleEvents, keptRanges: keptRanges)

        let vtt = WebVTTChapters.render(markers: mappedMarkers, duration: built.duration)
        if let chaptersURL {
            try vtt.write(to: chaptersURL, atomically: true, encoding: .utf8)
        }

        let chapters = WebVTTChapters.titledMarkers(mappedMarkers)
            .map { ExportManifest.Chapter(timeSeconds: $0.time, title: $0.title) }

        let byteSize = try FileManager.default.attributesOfItem(
            atPath: outputURL.path)[.size] as? Int ?? 0

        return ExportManifest(
            outputPath: outputURL.path,
            format: "mp4",
            byteSize: byteSize,
            durationSeconds: built.duration,
            width: Int(built.videoComposition.renderSize.width),
            height: Int(built.videoComposition.renderSize.height),
            scale: scale,
            chaptersPath: chaptersURL?.path,
            chapters: chapters)
    }
}
