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
