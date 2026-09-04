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
    /// Scale multipliers tried in order when the encoder's own
    /// `fileLengthLimit` cannot hit the target. Bounded deliberately: each
    /// rung is a full re-encode, and an unbounded search on a long recording
    /// would run for minutes with no way for the caller to see progress.
    ///
    /// mp4-only, deliberately: `fileLengthLimit` already handles bitrate for
    /// mp4, so this ladder only needs to walk scale. GIF has no bitrate
    /// primitive at all, so its ladder (`SizeLadder`) is a separate public
    /// type walking frame rate and scale together — a different algorithm,
    /// not a shared one with a dead axis for either caller.
    private static let sizeLadder: [Double] = [1.0, 0.75, 0.5, 0.35]

    /// The frame rate GIF export starts from before size targeting (if any)
    /// walks `SizeLadder` down from it.
    public static let defaultGIFFrameRate = 15.0

    public static func exportMovie(_ built: BuiltComposition,
                                   to url: URL,
                                   maxSizeBytes: Int? = nil) async throws {
        // Re-exporting after a tweak is the normal loop; a stale file from
        // the previous run must not fail the next one.
        try? FileManager.default.removeItem(at: url)

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.noExportSession }

        session.videoComposition = built.videoComposition
        if let maxSizeBytes {
            // The encoder's own primitive: one pass, the session picks a
            // bitrate that fits. Only if this misses do we re-encode at a
            // smaller scale (see the ladder in `export`).
            session.fileLengthLimit = Int64(maxSizeBytes)
        }

        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            throw ExportError.sessionFailed(String(describing: error))
        }
    }

    private static func fileByteSize(at url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// GIF's size-targeting path. Mirrors the shape of the mp4 ladder above
    /// (build at a rung, write, measure, keep the last rung that succeeded)
    /// but walks `SizeLadder` — frame rate first, then scale — because
    /// ImageIO has no `fileLengthLimit` equivalent: there is no encoder
    /// primitive to try before re-encoding, so the ladder IS the whole
    /// mechanism here, not a fallback after one.
    ///
    /// Returns the composition actually written, the scale it was written
    /// at, the resulting file's byte size, and whether `maxSizeBytes` (if
    /// any) was met.
    private static func exportGIF(bundle: SnittBundle,
                                  edl: EditDecisionList,
                                  scale: Double,
                                  to outputURL: URL,
                                  maxSizeBytes: Int?) async throws
        -> (built: BuiltComposition, scale: Double, byteSize: Int, sizeMet: Bool) {
        guard let maxSizeBytes else {
            // No target: one GIF at the base frame rate and the requested
            // scale, no ladder walked at all.
            let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
            try await GIFExporter.write(built, to: outputURL, framesPerSecond: defaultGIFFrameRate)
            let byteSize = try fileByteSize(at: outputURL)
            return (built, scale, byteSize, false)
        }

        let rungs = SizeLadder.rungs(baseFPS: defaultGIFFrameRate)
        var lastSuccessfulBuilt: BuiltComposition?
        var lastSuccessfulScale = scale
        var byteSize = 0
        var met = false
        for rung in rungs {
            let rungScale = scale * rung.scaleMultiplier
            let rungBuilt = try await CompositionBuilder.build(
                bundle: bundle, edl: edl, scale: rungScale)
            do {
                try await GIFExporter.write(
                    rungBuilt, to: outputURL, framesPerSecond: rung.framesPerSecond)
            } catch {
                // Same contract as the mp4 ladder: a rung that fails to
                // encode does not abort the whole export, it just isn't
                // this rung's answer.
                continue
            }
            lastSuccessfulBuilt = rungBuilt
            lastSuccessfulScale = rungScale
            byteSize = try fileByteSize(at: outputURL)
            if byteSize <= maxSizeBytes { met = true; break }
        }

        if let lastSuccessfulBuilt {
            return (lastSuccessfulBuilt, lastSuccessfulScale, byteSize, met)
        }

        // Every rung threw. The honesty contract still requires a file at
        // the output path, so fall back to the smallest rung, unconditionally.
        guard let smallest = rungs.last else {
            // rungs is never empty (SizeLadder always returns at least the
            // base rung), but hitting this would mean nothing was ever
            // written — surface that rather than crash on an unwrap.
            throw GIFError.destinationUnavailable
        }
        let smallestScale = scale * smallest.scaleMultiplier
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: smallestScale)
        try await GIFExporter.write(built, to: outputURL, framesPerSecond: smallest.framesPerSecond)
        byteSize = try fileByteSize(at: outputURL)
        return (built, smallestScale, byteSize, byteSize <= maxSizeBytes)
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
                              chaptersURL: URL? = nil,
                              format: String = "mp4",
                              maxSizeBytes: Int? = nil) async throws -> ExportManifest {
        var built: BuiltComposition
        var effectiveScale: Double
        var byteSize: Int
        var sizeMet = false

        if format == "gif" {
            (built, effectiveScale, byteSize, sizeMet) = try await exportGIF(
                bundle: bundle, edl: edl, scale: scale, to: outputURL, maxSizeBytes: maxSizeBytes)
        } else {
            built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
            effectiveScale = scale
            byteSize = 0

            if let maxSizeBytes {
                var met = false
                var lastSuccessfulBuilt: BuiltComposition?
                var lastSuccessfulScale = effectiveScale
                for rung in sizeLadder {
                    let rungScale = scale * rung
                    let rungBuilt = try await CompositionBuilder.build(
                        bundle: bundle, edl: edl, scale: rungScale)
                    do {
                        try await exportMovie(rungBuilt, to: outputURL, maxSizeBytes: maxSizeBytes)
                    } catch {
                        // The session may throw rather than produce a
                        // best-effort file when the limit is impossible. Either
                        // way the contract is the same: keep the smallest
                        // attempt that DID succeed and keep trying smaller
                        // scales, rather than losing the whole export to one
                        // rung's failure.
                        continue
                    }
                    lastSuccessfulBuilt = rungBuilt
                    lastSuccessfulScale = rungScale
                    byteSize = try fileByteSize(at: outputURL)
                    if byteSize <= maxSizeBytes { met = true; break }
                }
                // If no rung fit, the file on disk (from the last successful
                // attempt, the smallest one tried) is kept and reported
                // honestly rather than thrown away or misreported as a success.
                sizeMet = met
                if let lastSuccessfulBuilt {
                    built = lastSuccessfulBuilt
                    effectiveScale = lastSuccessfulScale
                } else {
                    // Every rung's export threw — even the smallest one, which
                    // is the caller's best shot at a small file. The honesty
                    // contract still requires a file at the output path, so
                    // fall back to an unconstrained export, but at the
                    // SMALLEST rung's scale, not the originally requested one:
                    // the caller asked for small, and handing back the largest
                    // possible file (full scale, no limit) when every attempt
                    // to shrink it failed would be the worst available choice.
                    let smallestScale = scale * (sizeLadder.last ?? 1.0)
                    built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: smallestScale)
                    effectiveScale = smallestScale
                    try await exportMovie(built, to: outputURL, maxSizeBytes: nil)
                    byteSize = try fileByteSize(at: outputURL)
                    sizeMet = byteSize <= maxSizeBytes
                }
            } else {
                try await exportMovie(built, to: outputURL, maxSizeBytes: nil)
                byteSize = try fileByteSize(at: outputURL)
            }
        }

        // `built.keptRanges` is the SAME set CompositionBuilder inserted
        // into the composition — not recomputed against a second,
        // separately-loaded asset — so a marker mapped through it can never
        // land on a position the just-written file doesn't have.
        let bundleEvents = try readBundleEvents(bundle)
        let mappedMarkers = MarkerMapping.map(bundleEvents, keptRanges: built.keptRanges)

        let vtt = WebVTTChapters.render(markers: mappedMarkers, duration: built.duration)
        if let chaptersURL {
            try vtt.write(to: chaptersURL, atomically: true, encoding: .utf8)
        }

        let chapters = WebVTTChapters.titledMarkers(mappedMarkers)
            .map { ExportManifest.Chapter(timeSeconds: $0.time, title: $0.title) }

        return ExportManifest(
            outputPath: outputURL.path,
            format: format,
            byteSize: byteSize,
            durationSeconds: built.duration,
            width: Int(built.videoComposition.renderSize.width),
            height: Int(built.videoComposition.renderSize.height),
            // The scale actually used, not the one requested — the ladder
            // may have dropped below `scale` to hit the target.
            scale: effectiveScale,
            maxSizeBytes: maxSizeBytes,
            maxSizeMet: maxSizeBytes == nil ? nil : sizeMet,
            chaptersPath: chaptersURL?.path,
            chapters: chapters)
    }

    /// Reads `bundle`'s event log, treating "no file" and "unreadable file"
    /// as two different outcomes rather than collapsing both into "no
    /// markers".
    ///
    /// `EventLog.read` throws for both a missing file and corrupt JSON —
    /// `Data(contentsOf:)` and `JSONDecoder.decode` give the caller no way
    /// to tell those apart from the thrown error alone. A bare `try?` here
    /// would export successfully with a well-formed, chapter-less manifest
    /// for a bundle whose `events.json` is simply damaged — indistinguishable
    /// from a recording that genuinely had no markers. §8 exists precisely so
    /// an agent's manifest is something factually true; "no chapters" must
    /// mean "no markers were recorded," not "something went wrong reading
    /// the sidecar and this code shrugged." A missing file, on the other
    /// hand, is legitimate — a bundle from before M3b, or one with logging
    /// disabled — and must still export cleanly with no chapters.
    private static func readBundleEvents(_ bundle: SnittBundle) throws -> [LoggedEvent] {
        guard FileManager.default.fileExists(atPath: bundle.eventsURL.path) else { return [] }
        return try EventLog.read(from: bundle).events
    }
}
