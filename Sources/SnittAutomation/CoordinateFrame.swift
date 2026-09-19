// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Why a coordinate could not be converted.
///
/// A purpose-built type rather than `String`, for the reason `ParseFailure`
/// and `MCPBridgeError` both record: `Result` constrains `Failure` to `Error`,
/// and a retroactive `String: Error` conformance in a library target leaks to
/// every importer. Each frontend re-wraps the `message` in its own type so the
/// words reaching a caller are identical on both.
public struct CoordinateFailure: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The picture a caller measured its coordinates in (D105).
///
/// Both frontends take crops and reported input as PIXELS when the caller says
/// what they are pixels of, and as fractions when it does not. Neither may read
/// `capture.mov` (§4.9), so Snitt's own pixel size is not knowable where a
/// request is built, which is exactly why the caller names its own frame
/// rather than being told Snitt's. That is not a workaround for the missing
/// read. An agent's numbers come from a window it queried or a
/// `snitt_screenshot` image it is looking at, and BOTH routinely differ in size
/// from `capture.mov`: a Retina capture is twice its window in points, and the
/// inline screenshot is downscaled to 1280px on its longest edge. A fraction of
/// a named frame is right in all three spaces at once; a pixel count is right
/// in exactly one and silently wrong in the other two.
///
/// Which is also why the STORED `CropRect` stays fractional. That was never the
/// defect: a unit rect survives a change of source resolution and composes
/// with `--scale` without either knowing about the other. The defect was making
/// the CALLER do the division, from numbers it holds in pixels, into a type
/// that clamps rather than throws.
///
/// Lives here, shared, rather than once per frontend: §4.8 requires the CLI and
/// the MCP server to be incapable of diverging, and "two parsers converting the
/// same numbers two ways" is precisely how they would. A refusal comes back as
/// a `CoordinateFailure` that each frontend re-wraps in its own error type, so
/// the words a caller reads are the same on both.
public struct CoordinateFrame: Equatable, Sendable {
    public let width: Double
    public let height: Double

    /// Fails for a non-positive size: dividing by it produces an infinity or a
    /// sign flip, and both would sail through the bounds checks below as a
    /// rectangle nobody asked for.
    public static func make(width: Double, height: Double,
                            verb: String) -> Result<CoordinateFrame, CoordinateFailure> {
        guard width > 0, height > 0 else {
            return .failure(CoordinateFailure("\(verb) needs a frame width and height greater than 0, "
                          + "got \(width) x \(height)."))
        }
        return .success(CoordinateFrame(width: width, height: height))
    }

    /// A hair of tolerance, because a rectangle reaching exactly to the right
    /// edge in pixels divides to 0.9999999999999999 about as often as it
    /// divides to 1.
    private static let epsilon = 1e-9

    /// Converts a rectangle to the fractional `CropRect` that is stored,
    /// refusing anything that leaves the frame.
    ///
    /// `CropRect.init` CLAMPS, deliberately and correctly for the editor: a
    /// drag past the edge means the user wanted the edge. The same rectangle
    /// arriving over the automation API means something else: a caller that
    /// measured in the wrong space, or passed pixels without saying so, and
    /// clamping turns that into a crop that succeeds, reports a plausible
    /// pixel size, and shows the wrong part of the picture. §8 forbids exactly
    /// that, so the refusal happens here, before the clamp can hide it.
    public static func unitRect(x: Double, y: Double, width: Double, height: Double,
                                in frame: CoordinateFrame?,
                                verb: String) -> Result<CropRect, CoordinateFailure> {
        let ux = frame.map { x / $0.width } ?? x
        let uy = frame.map { y / $0.height } ?? y
        let uw = frame.map { width / $0.width } ?? width
        let uh = frame.map { height / $0.height } ?? height
        guard ux >= -epsilon, uy >= -epsilon,
              ux + uw <= 1 + epsilon, uy + uh <= 1 + epsilon else {
            return .failure(CoordinateFailure(
                "\(verb) was given a rectangle that runs off the frame: x \(ux), "
              + "y \(uy), width \(uw), height \(uh) as fractions. "
              + advice(frame) + " Snitt refuses rather than pulling it back to the "
              + "edge, which would crop something other than what was asked for and "
              + "report success."))
        }
        return .success(CropRect(x: ux, y: uy, width: uw, height: uh))
    }

    /// Converts a reported input position the same way, refusing a point
    /// outside the frame.
    ///
    /// A point off the edge means the caller measured in a space Snitt was not
    /// told about, a full screen rather than the window, or pixels with no
    /// frame size, and pinning it to the border would draw a ring where
    /// nothing was clicked, which is worse than no ring at all.
    public static func unitPoint(x: Double, y: Double,
                                 in frame: CoordinateFrame?,
                                 verb: String) -> Result<(x: Double, y: Double), CoordinateFailure> {
        let ux = frame.map { x / $0.width } ?? x
        let uy = frame.map { y / $0.height } ?? y
        for (axis, value) in [("x", ux), ("y", uy)] where !(value >= 0 && value <= 1) {
            return .failure(CoordinateFailure(
                "\(verb) \(axis) lands outside the recorded window (\(value) of the "
              + "way across, after converting). " + advice(frame)))
        }
        return .success((ux, uy))
    }

    private static func advice(_ frame: CoordinateFrame?) -> String {
        frame == nil
            ? "Without a frame width and height, coordinates must be fractions "
            + "between 0 and 1. Give the size of the picture you measured in and "
            + "pass pixels instead."
            : "Check that the frame width and height name the same picture the "
            + "coordinates were measured in."
    }
}
