// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import Foundation
import SnittDocument

public enum EstimateError: Error, Equatable {
    /// GIF size tracks how much the picture MOVES rather than how long it runs,
    /// and its frames carry no interframe compression — AVFoundation's
    /// estimator describes an H.264 export and says nothing about a GIF.
    /// Refused rather than answered with a number from the wrong codec.
    case unsupportedFormat(String)
}

/// Answering "how big, how long, what size?" before spending the export.
///
/// **This asks AVFoundation rather than modelling anything**, and arriving
/// there took discarding two things that seemed reasonable.
///
/// Scaling the source's bitrate by duration and pixel count came in at
/// 0.55–0.67x of actual at full scale and 0.15–0.25x at half: H.264 does not
/// trade pixels for bits linearly, because the encoder holds quality instead.
///
/// Encoding a sample and extrapolating did better — a single opening slice
/// estimated 10.6MB for a real 200s recording that exported to 176.6MB, and
/// sampling across the recording in one composition finally produced a true
/// bound at 1.9x. But it costs a partial encode, it needed three attempts to
/// stop being wrong, and `AVAssetExportSession.estimateOutputFileLength` was
/// there the whole time: instant, monotonic across presets, and a true ceiling.
///
/// The ceiling is GENEROUS — measured at 3.9x actual on a real recording — and
/// that is stated wherever it is reported. It is the right tool for choosing
/// between resolutions, which is what a caller is actually doing, and the wrong
/// one for predicting a byte count. `--max-size` remains the way to FIT a
/// budget, because it fits by measuring.
public enum ExportEstimator {

    /// What one resolution would produce.
    public static func estimate(bundle: SnittBundle,
                                edl: EditDecisionList,
                                resolution: ExportResolution,
                                scale: Double = 1.0,
                                format: String = "mp4") async throws -> ExportEstimate {
        guard format != "gif" else { throw EstimateError.unsupportedFormat(format) }
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
        return try await estimate(built: built, resolution: resolution)
    }

    /// Every resolution at once, largest first.
    ///
    /// One composition, six estimates: the expensive part is building, and
    /// asking each preset costs microseconds. A caller choosing where to land
    /// should see the whole menu rather than guess and re-ask.
    public static func menu(bundle: SnittBundle,
                            edl: EditDecisionList,
                            scale: Double = 1.0) async throws -> [ExportEstimate] {
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
        var out: [ExportEstimate] = []
        for resolution in ExportResolution.descending {
            if let estimate = try? await estimate(built: built, resolution: resolution) {
                out.append(estimate)
            }
        }
        return out
    }

    private static func estimate(built: BuiltComposition,
                                 resolution: ExportResolution) async throws -> ExportEstimate {
        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: MovieExporter.presetName(for: resolution))
        else { throw ExportError.noExportSession }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix

        let bytes: Int64 = await withCheckedContinuation { continuation in
            session.estimateOutputFileLength { length, _ in
                continuation.resume(returning: length)
            }
        }
        let size = renderSize(of: built, at: resolution)
        return ExportEstimate(
            resolution: resolution,
            durationSeconds: built.duration,
            width: Int(size.width), height: Int(size.height),
            estimatedMaxBytes: Int(bytes),
            basis: "AVFoundation's own ceiling for this preset — generous, "
                 + "measured at about 4x the real file on a 5K recording. Use it "
                 + "to choose between resolutions, not to predict a byte count.")
    }

    /// What the export will actually render at.
    ///
    /// A preset never enlarges: asking for 2160p from a 720p recording gets
    /// 720p, because upscaling adds pixels and no information. So the render is
    /// the composition's size capped to the preset's long edge, preserving
    /// aspect.
    static func renderSize(of built: BuiltComposition,
                           at resolution: ExportResolution) -> CGSize {
        let size = built.videoComposition.renderSize
        guard let longEdge = resolution.longEdge else { return size }
        let current = max(size.width, size.height)
        guard current > CGFloat(longEdge), current > 0 else { return size }
        let factor = CGFloat(longEdge) / current
        return CGSize(width: (size.width * factor).rounded(),
                      height: (size.height * factor).rounded())
    }
}
