// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotError: Error, Equatable {
    case noFrameYet
    case encodingFailed
}

/// Writes one captured frame to a PNG.
///
/// Separated from `Recorder` so the encode is testable against a pixel buffer
/// built by hand, with no stream, no bundle and no recording — the same seam
/// `SampleBufferSink` gives the capture path.
public enum ScreenshotWriter {
    /// A shared context: `CIContext` creation is expensive (it compiles
    /// kernels and can allocate a Metal device), and a screenshot taken during
    /// a recording competes with the encoder for exactly the resources §12.1's
    /// health sampling exists to protect.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The longest edge an inline screenshot is downscaled to.
    ///
    /// 1280 because `GIFExporter.maximumWidth` already settled the same
    /// question for the same reason: it is the point past which a frame stops
    /// being worth its bytes. An inline screenshot is returned over MCP into a
    /// model's context and the loop takes them repeatedly, so full backing
    /// resolution (a 5K display is 5120 wide, and base64 adds a third again)
    /// would spend the agent's context on pixels it does not need. 1280 is
    /// ample for what the tool is FOR: seeing that a tab strip is in frame,
    /// that the wrong window was captured, or that a dialog is covering the
    /// target.
    public static let inlineMaximumEdge: Double = 1280

    /// One captured frame as PNG data, downscaled to `inlineMaximumEdge`.
    ///
    /// Separate from `writePNG`: the file inside the bundle stays at full
    /// capture resolution, because it is the archival copy and a person may
    /// open it. Only the copy that travels to an agent is reduced.
    ///
    /// Never enlarges. A frame already smaller than the cap is encoded as-is,
    /// matching `ExportResolution`'s rule that asking for more than the
    /// recording has keeps what it has.
    public static func inlinePNGData(_ image: CVImageBuffer) throws -> Data {
        let ciImage = CIImage(cvImageBuffer: image)
        let extent = ciImage.extent
        let longest = max(extent.width, extent.height)
        let scale = longest > inlineMaximumEdge ? inlineMaximumEdge / longest : 1.0
        let scaled = scale < 1.0
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw ScreenshotError.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotError.encodingFailed
        }
        return data as Data
    }

    public static func writePNG(_ image: CVImageBuffer, to url: URL) throws {
        let ciImage = CIImage(cvImageBuffer: image)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ScreenshotError.encodingFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotError.encodingFailed
        }
    }
}
