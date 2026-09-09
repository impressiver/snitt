import AVFoundation
import Foundation
import SnittDocument

public enum ExportError: Error, Equatable {
    case noExportSession
    case sessionFailed(String)
    /// `NSFileManager`'s `.size` attribute came back as something other than
    /// an `NSNumber`. Unreachable on macOS in practice, but this milestone's
    /// own banned pattern is `(… as? T) ?? 0` — a failed cast silently
    /// becoming 0 bytes would satisfy `byteSize <= maxSizeBytes` and report
    /// `maxSizeMet == true` for a file whose size was never actually read.
    case unreadableFileSize(String)
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

    /// A same-directory sibling of `url` the export writes to before it is
    /// known to have succeeded (finding #4, mirroring `GIFExporter`'s
    /// helper of the same name): `AVAssetExportSession` can throw partway
    /// through a rung in the ladder below, and a rung that throws must not
    /// disturb whatever a PREVIOUS, successful rung already left at `url` —
    /// otherwise the manifest can end up describing a byte size and
    /// dimensions for a path with no file on it at all.
    private static func temporaryURL(near url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".snitt-tmp-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
    }

    public static func exportMovie(_ built: BuiltComposition,
                                   to url: URL,
                                   maxSizeBytes: Int? = nil,
                                   clicks: [ClickMark] = []) async throws {
        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.noExportSession }

        // With clicks, an export-only copy carrying the animation tool; without
        // them, the shared composition untouched. The copy exists because
        // `animationTool` cannot be used with `AVPlayerItem` (V5), so setting
        // it on the object preview also holds would break playback in order to
        // decorate the export.
        session.videoComposition = ClickOverlay.exportComposition(
            from: built.videoComposition, marks: clicks) ?? built.videoComposition
        // The mix lives on the export session, not the player item (M4's
        // preview layer) — §9's whole point is that the two paths cannot
        // apply the mix differently, and putting it here is what
        // `exportAppliesTheMix` checks.
        session.audioMix = built.audioMix
        if let maxSizeBytes {
            // The encoder's own primitive: one pass, the session picks a
            // bitrate that fits. Only if this misses do we re-encode at a
            // smaller scale (see the ladder in `export`).
            session.fileLengthLimit = Int64(maxSizeBytes)
        }

        let tempURL = temporaryURL(near: url)
        // A stale temp file from an earlier crashed run must not fail this
        // one; `AVAssetExportSession` refuses to write over an existing file.
        try? FileManager.default.removeItem(at: tempURL)
        do {
            // Deliberately retained even though `fileLengthLimit` is now
            // known (measured, not assumed) to shrink toward a floor rather
            // than throw: floor behaviour is undocumented and can plausibly
            // vary across encoders and OS releases, and the cost of this
            // catch is a few lines against losing an entire long export to
            // an unhandled throw if it ever does misbehave. Currently
            // untestable through the public API — nothing observed drives
            // `AVAssetExportSession.export` to throw here — except that the
            // cleanup on the line right below (finding #4) now runs inside
            // it, which makes this branch partly exercisable after all: a
            // constructed throw here is exactly what proves that cleanup
            // doesn't clobber a previous rung's good file.
            try await session.export(to: tempURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ExportError.sessionFailed(String(describing: error))
        }

        // Only now — with a complete file sitting at `tempURL` — does
        // whatever was previously at `url` get replaced. Re-exporting after
        // a tweak is the normal loop, so a stale file from a previous run at
        // `url` must not fail this one; deferring the removal to here (as
        // opposed to up front, before the export even ran) is what keeps a
        // throwing rung from destroying a previously good file.
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private static func fileByteSize(at url: URL) throws -> Int {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        else {
            throw ExportError.unreadableFileSize(url.path)
        }
        return size
    }

    /// GIF's size-targeting path. Mirrors the shape of the mp4 ladder above
    /// (build at a rung, write, measure, keep the last rung that succeeded)
    /// but walks `SizeLadder` — frame rate first, then scale — because
    /// ImageIO has no `fileLengthLimit` equivalent: there is no encoder
    /// primitive to try before re-encoding, so the ladder IS the whole
    /// mechanism here, not a fallback after one.
    ///
    /// Returns the composition actually written, the scale and frame rate it
    /// was written at, the resulting file's byte size, and whether
    /// `maxSizeBytes` (if any) was met.
    ///
    /// The frame rate is part of this return value, not an afterthought: the
    /// ladder drops fps before scale, so a GIF that hit its budget by
    /// dropping to 5fps looks — absent this — identical in the manifest to
    /// one that hit it untouched. `effectiveFPS` is what makes that
    /// distinguishable.
    private static func exportGIF(bundle: SnittBundle,
                                  clickEvents: [LoggedEvent] = [],
                                  edl: EditDecisionList,
                                  scale: Double,
                                  to outputURL: URL,
                                  maxSizeBytes: Int?) async throws
        -> (built: BuiltComposition, scale: Double, fps: Double, byteSize: Int, sizeMet: Bool) {
        guard let maxSizeBytes else {
            // No target: one GIF at the base frame rate and the requested
            // scale, no ladder walked at all.
            let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
            try await GIFExporter.write(built, to: outputURL, framesPerSecond: defaultGIFFrameRate,
                                        clicks: clickMarks(for: built, events: clickEvents))
            let byteSize = try fileByteSize(at: outputURL)
            return (built, scale, defaultGIFFrameRate, byteSize, false)
        }

        let rungs = SizeLadder.rungs(baseFPS: defaultGIFFrameRate)
        var lastSuccessfulBuilt: BuiltComposition?
        var lastSuccessfulScale = scale
        var lastSuccessfulFPS = defaultGIFFrameRate
        var byteSize = 0
        var met = false
        for rung in rungs {
            let rungScale = scale * rung.scaleMultiplier
            let rungBuilt = try await CompositionBuilder.build(
                bundle: bundle, edl: edl, scale: rungScale)
            do {
                try await GIFExporter.write(
                    rungBuilt, to: outputURL, framesPerSecond: rung.framesPerSecond,
                    // Recomputed for THIS rung: a smaller scale is a different
                    // render transform, and a mark placed for the full-size
                    // frame lands somewhere else on a scaled one.
                    clicks: clickMarks(for: rungBuilt, events: clickEvents))
            } catch {
                // Same contract as the mp4 ladder: a rung that fails to
                // encode does not abort the whole export, it just isn't
                // this rung's answer. `outputURL` is untouched by a throwing
                // rung (GIFExporter.write writes to a temp path and only
                // moves it into place on success), so it still holds
                // whatever the LAST successful rung wrote — matching the
                // `lastSuccessfulBuilt`/`byteSize`/fps this loop is about to
                // report (finding #4).
                continue
            }
            lastSuccessfulBuilt = rungBuilt
            lastSuccessfulScale = rungScale
            lastSuccessfulFPS = rung.framesPerSecond
            byteSize = try fileByteSize(at: outputURL)
            if byteSize <= maxSizeBytes { met = true; break }
        }

        if let lastSuccessfulBuilt {
            return (lastSuccessfulBuilt, lastSuccessfulScale, lastSuccessfulFPS, byteSize, met)
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
        try await GIFExporter.write(built, to: outputURL, framesPerSecond: smallest.framesPerSecond,
                                    clicks: clickMarks(for: built, events: clickEvents))
        byteSize = try fileByteSize(at: outputURL)
        return (built, smallestScale, smallest.framesPerSecond, byteSize, byteSize <= maxSizeBytes)
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
                              subtitlesURL: URL? = nil,
                              format: String = "mp4",
                              maxSizeBytes: Int? = nil,
                              // D64. Off by default: a recording's clicks are
                              // data (§4.5), and drawing them is a choice the
                              // person exporting makes, not something that
                              // happens to every export because the events
                              // happen to be there.
                              clicks: Bool = false) async throws -> ExportManifest {
        var built: BuiltComposition
        var effectiveScale: Double
        var effectiveFPS: Double?
        var byteSize: Int
        var sizeMet = false

        // Read once. `readBundleEvents` throws on damaged JSON and returns []
        // for a missing file, which is the same distinction chapters rely on:
        // "no clicks" must mean none were recorded, not that something went
        // wrong and this shrugged.
        let clickEvents = clicks ? try readBundleEvents(bundle) : []

        if format == "gif" {
            var fps: Double
            (built, effectiveScale, fps, byteSize, sizeMet) = try await exportGIF(
                bundle: bundle, clickEvents: clickEvents, edl: edl, scale: scale,
                to: outputURL, maxSizeBytes: maxSizeBytes)
            effectiveFPS = fps
        } else {
            effectiveFPS = nil
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
                        try await exportMovie(
                            rungBuilt, to: outputURL, maxSizeBytes: maxSizeBytes,
                            // Per rung, for the same reason the GIF ladder
                            // recomputes: this rung is a different scale and
                            // therefore a different render transform.
                            clicks: clickMarks(for: rungBuilt, events: clickEvents))
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
                    try await exportMovie(built, to: outputURL, maxSizeBytes: nil,
                                          clicks: clickMarks(for: built, events: clickEvents))
                    byteSize = try fileByteSize(at: outputURL)
                    sizeMet = byteSize <= maxSizeBytes
                }
            } else {
                try await exportMovie(built, to: outputURL, maxSizeBytes: nil,
                                          clicks: clickMarks(for: built, events: clickEvents))
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

        // A SEPARATE file from chapters, not an alternative rendering of the
        // same one (D50). They carry different fields, have different timing
        // rules, and a player loads them into different tracks — merging them
        // would put "Paused" and "Screenshot" into the captions.
        if let subtitlesURL {
            let subtitles = WebVTTSubtitles.render(markers: mappedMarkers,
                                                   duration: built.duration)
            try subtitles.write(to: subtitlesURL, atomically: true, encoding: .utf8)
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
            effectiveFPS: effectiveFPS,
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
    /// The click marks for one built composition.
    ///
    /// Takes the composition rather than a precomputed list because both size
    /// ladders rebuild at smaller scales, and a mark's position comes from the
    /// render transform — so marks belong to a build, not to an export.
    private static func clickMarks(for built: BuiltComposition,
                                   events: [LoggedEvent]) -> [ClickMark] {
        guard !events.isEmpty else { return [] }
        return ClickOverlay.marks(events: events, keptRanges: built.keptRanges,
                                  naturalSize: built.naturalSize,
                                  renderTransform: built.renderTransform)
    }

    private static func readBundleEvents(_ bundle: SnittBundle) throws -> [LoggedEvent] {
        guard FileManager.default.fileExists(atPath: bundle.eventsURL.path) else { return [] }
        return try EventLog.read(from: bundle).events
    }
}
