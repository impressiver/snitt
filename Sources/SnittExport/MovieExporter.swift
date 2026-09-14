// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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

    /// Encode only the first `seconds` of a composition.
    ///
    /// Exists so a size can be MEASURED rather than modelled: the same encoder
    /// on the same pictures at the same dimensions, just less of it.
    static func exportSlice(_ built: BuiltComposition, to url: URL,
                            from start: Double = 0,
                            seconds: Double) async throws {
        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.noExportSession }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        let begin = max(0, min(start, max(0, built.duration - seconds)))
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: begin, preferredTimescale: 600),
            duration: CMTime(seconds: min(seconds, built.duration - begin),
                             preferredTimescale: 600))
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mp4)
    }

    /// The export preset for a requested resolution.
    ///
    /// `HighestQuality` for `source`, which is what every export used before
    /// there was a choice, so asking for nothing behaves exactly as it did.
    static func presetName(for resolution: ExportResolution) -> String {
        switch resolution {
        case .source: AVAssetExportPresetHighestQuality
        case .uhd2160p: AVAssetExportPreset3840x2160
        case .hd1080p: AVAssetExportPreset1920x1080
        case .hd720p: AVAssetExportPreset1280x720
        case .sd540p: AVAssetExportPreset960x540
        case .sd480p: AVAssetExportPreset640x480
        }
    }

    /// `edl` is what decides whether the samples can simply be copied. Passed
    /// in rather than derived from `built`, because by the time a composition
    /// exists the crop and the gains have already been folded into it and the
    /// question can no longer be asked of it.
    ///
    /// **Nil means re-encode, and that is deliberate.** It first defaulted to
    /// an empty `EditDecisionList`, which reads as "no crop, no gain" — so a
    /// caller that simply did not pass one was waved onto the fast path and had
    /// its crop silently dropped. `CropTests` caught it immediately. Unknown
    /// has to fail toward the slow, correct answer: the cost of re-encoding
    /// unnecessarily is a second, and the cost of copying when you should not
    /// is the wrong picture, exported quickly and without complaint.
    public static func exportMovie(_ built: BuiltComposition,
                                   to url: URL,
                                   maxSizeBytes: Int? = nil,
                                   clicks: [ClickMark] = [],
                                   resolution: ExportResolution = .source,
                                   edl: EditDecisionList? = nil,
                                   scale: Double = 1.0,
                                   cues: [SubtitleCue] = [],
                                   banners: [MarkerBanner] = []) async throws {
        // Copy the samples when nothing in this export would change a pixel.
        // Measured on a real 4112x2580 capture: 1.112s to re-encode, 0.023s to
        // copy, and the decoded frames match. See `PassthroughEligibility`.
        let canCopy = edl.map {
            PassthroughEligibility.isEligible(resolution: resolution,
                                              maxSizeBytes: maxSizeBytes,
                                              clicks: clicks, edl: $0,
                                              hasAudioMix: built.audioMix != nil,
                                              scale: scale)
        } ?? false
        let preset = canCopy ? AVAssetExportPresetPassthrough : presetName(for: resolution)

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: preset)
        else { throw ExportError.noExportSession }

        // With clicks, an export-only copy carrying the animation tool; without
        // them, the shared composition untouched. The copy exists because
        // `animationTool` cannot be used with `AVPlayerItem` (V5), so setting
        // it on the object preview also holds would break playback in order to
        // decorate the export.
        // A passthrough session takes NEITHER of these. Setting a
        // videoComposition forces a re-encode, which would silently undo the
        // whole point; setting an audioMix on a passthrough session is refused
        // outright. Eligibility already established that both would be no-ops.
        if !canCopy {
            // Clicks first, then text over them, so a caption is never drawn
            // underneath a ring. Each returns nil when it has nothing to add,
            // and the fallbacks chain so a composition is built once whichever
            // overlays are on.
            let withClicks = ClickOverlay.exportComposition(
                from: built.videoComposition, marks: clicks) ?? built.videoComposition
            session.videoComposition = TextOverlayComposition.composition(
                from: withClicks, cues: cues, banners: banners) ?? withClicks
            // The mix lives on the export session, not the player item (M4's
            // preview layer) — §9's whole point is that the two paths cannot
            // apply the mix differently, and putting it here is what
            // `exportAppliesTheMix` checks.
            session.audioMix = built.audioMix
        }
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
                                  transcriptWords: [TranscriptWord] = [],
                                  bannerEvents: [LoggedEvent] = [],
                                  edl: EditDecisionList,
                                  scale: Double,
                                  to outputURL: URL,
                                  maxSizeBytes: Int?) async throws
        -> (built: BuiltComposition, scale: Double, fps: Double, byteSize: Int, sizeMet: Bool) {
        // Clamp the scale before a single frame is generated. A GIF at Retina
        // capture size cannot be encoded at all — ImageIO quantises every
        // frame together inside `CGImageDestinationFinalize` and runs out of
        // address space — so this is a correctness bound, not a preference.
        // See `GIFExporter.maximumWidth`.
        //
        // Measured from a build rather than from the asset: the render size is
        // what the encoder actually sees, and it already accounts for the
        // crop, the preferred transform and the requested scale. Building is
        // cheap next to encoding, and the second build only happens when the
        // first was too wide to encode at all.
        var scale = scale
        let probe = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
        let probeWidth = probe.videoComposition.renderSize.width
        if probeWidth > GIFExporter.maximumWidth {
            scale *= GIFExporter.maximumWidth / probeWidth
        }

        guard let maxSizeBytes else {
            // No target: one GIF at the base frame rate and the requested
            // scale, no ladder walked at all.
            let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
            let overlays = textOverlays(for: built, words: transcriptWords,
                                        markerEvents: bannerEvents)
            try await GIFExporter.write(built, to: outputURL, framesPerSecond: defaultGIFFrameRate,
                                        clicks: clickMarks(for: built, events: clickEvents),
                                        cues: overlays.cues, banners: overlays.banners)
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
                    clicks: clickMarks(for: rungBuilt, events: clickEvents),
                    cues: textOverlays(for: rungBuilt, words: transcriptWords,
                                       markerEvents: bannerEvents).cues,
                    banners: textOverlays(for: rungBuilt, words: transcriptWords,
                                          markerEvents: bannerEvents).banners)
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
                              resolution: ExportResolution = .source,
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

        // The two burned-in overlays, from the EDL rather than a parameter:
        // they are a property of the document, set in the editor and carried
        // into every export, exactly as `showClicks` is. Events are read once
        // and reused; the transcript only when captions are actually wanted,
        // since reading it costs a file open for a recording that may have none.
        let bannerEvents = edl.showMarkers ? try readBundleEvents(bundle) : []
        // Filtered through `AudibleTranscript`, like every other surface that
        // shows transcript words. A muted track contributes no audio to this
        // file, so burning its speech in would caption something the viewer
        // cannot hear — and a viewer has no way to tell that from a
        // transcription error.
        let transcriptWords: [TranscriptWord] = edl.showSubtitles
            ? AudibleTranscript.audible((try? Transcript.read(from: bundle))?.words ?? [],
                                        trackStates: edl.trackStates)
            : []

        if format == "gif" {
            var fps: Double
            (built, effectiveScale, fps, byteSize, sizeMet) = try await exportGIF(
                bundle: bundle, clickEvents: clickEvents,
                transcriptWords: transcriptWords, bannerEvents: bannerEvents,
                edl: edl, scale: scale,
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
                            clicks: clickMarks(for: rungBuilt, events: clickEvents),
                            resolution: resolution, edl: edl, scale: rungScale,
                            cues: textOverlays(for: rungBuilt, words: transcriptWords,
                                               markerEvents: bannerEvents).cues,
                            banners: textOverlays(for: rungBuilt, words: transcriptWords,
                                                  markerEvents: bannerEvents).banners)
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
                                          clicks: clickMarks(for: built, events: clickEvents),
                                          resolution: resolution, edl: edl,
                                          scale: smallestScale,
                                          cues: textOverlays(for: built, words: transcriptWords,
                                                             markerEvents: bannerEvents).cues,
                                          banners: textOverlays(for: built, words: transcriptWords,
                                                                markerEvents: bannerEvents).banners)
                    byteSize = try fileByteSize(at: outputURL)
                    sizeMet = byteSize <= maxSizeBytes
                }
            } else {
                try await exportMovie(built, to: outputURL, maxSizeBytes: nil,
                                          clicks: clickMarks(for: built, events: clickEvents),
                                          resolution: resolution, edl: edl,
                                          scale: effectiveScale,
                                          cues: textOverlays(for: built, words: transcriptWords,
                                                             markerEvents: bannerEvents).cues,
                                          banners: textOverlays(for: built, words: transcriptWords,
                                                                markerEvents: bannerEvents).banners)
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

        // Read back from the FILE, not from the composition. A resolution
        // preset resizes during export, so the composition's renderSize is the
        // size before that happened: a 720p export of a 5K recording reported
        // 4112x2580 for a file that is actually 1280x804. The manifest is what
        // an agent quotes to describe a demo it cannot watch, so it has to
        // describe the demo.
        //
        // Falls back to the composition's size when the file cannot be read,
        // which is the pre-existing behaviour and no worse than it was.
        let written = (try? await videoSize(of: outputURL))
            ?? built.videoComposition.renderSize
        return ExportManifest(
            outputPath: outputURL.path,
            format: format,
            byteSize: byteSize,
            durationSeconds: built.duration,
            width: Int(written.width),
            height: Int(written.height),
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
    /// Captions and banners for one built composition, in OUTPUT time.
    ///
    /// Takes the composition for the same reason `clickMarks` does: the size
    /// ladder rebuilds at smaller scales, and the overlays are laid out
    /// against the render size, so they belong to a build rather than to an
    /// export.
    static func textOverlays(for built: BuiltComposition,
                             words: [TranscriptWord],
                             markerEvents: [LoggedEvent])
        -> (cues: [SubtitleCue], banners: [MarkerBanner]) {
        (SubtitleCues.cues(words: words, keptRanges: built.keptRanges),
         MarkerBanners.banners(events: markerEvents, keptRanges: built.keptRanges))
    }

    private static func clickMarks(for built: BuiltComposition,
                                   events: [LoggedEvent]) -> [ClickMark] {
        guard !events.isEmpty else { return [] }
        return ClickOverlay.marks(events: events, keptRanges: built.keptRanges,
                                  naturalSize: built.naturalSize,
                                  renderTransform: built.renderTransform)
    }

    /// The video dimensions a written file actually has.
    private static func videoSize(of url: URL) async throws -> CGSize? {
        guard let track = try await AVURLAsset(url: url)
            .loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // Through the transform, so a rotated recording reports the dimensions
        // a viewer sees rather than the ones stored.
        let oriented = size.applying(transform)
        return CGSize(width: abs(oriented.width), height: abs(oriented.height))
    }

    private static func readBundleEvents(_ bundle: SnittBundle) throws -> [LoggedEvent] {
        guard FileManager.default.fileExists(atPath: bundle.eventsURL.path) else { return [] }
        return try EventLog.read(from: bundle).events
    }
}
