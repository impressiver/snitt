import CoreGraphics
import SnittDocument

/// Maps a drag over the preview into a `CropRect`.
///
/// The trap this exists to avoid: `PlayerLayerBackedView` uses
/// `videoGravity = .resizeAspect`, so the video does NOT fill its view — a
/// 16:9 recording in a squarish window is letterboxed, and a 4:3 one is
/// pillarboxed. Treating the drag as a fraction of the VIEW crops the wrong
/// region, and the error is invisible whenever the window happens to match the
/// recording's aspect ratio, which is exactly when someone would test it by
/// hand.
///
/// Pure and taking both sizes as parameters so it is testable without a window,
/// a player, or a decoded frame — the same reason `openingContentRect` takes a
/// visible frame.
///
/// Coordinates are top-left origin, matching both SwiftUI's default space and
/// `CropRect`'s documented convention.
enum CropGeometry {
    /// The rect an aspect-fit video actually occupies inside `bounds`.
    static func videoRect(videoSize: CGSize, in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2,
                      y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Converts a drag in view coordinates into a normalized crop.
    ///
    /// Returns `nil` when the drag does not overlap the video at all (a drag
    /// entirely in the letterbox) or is degenerate — both mean "no crop was
    /// expressed", which the caller must not confuse with "crop to nothing".
    static func crop(fromDrag drag: CGRect, videoSize: CGSize, in bounds: CGRect) -> CropRect? {
        let video = videoRect(videoSize: videoSize, in: bounds)
        guard video.width > 0, video.height > 0 else { return nil }
        let clipped = drag.intersection(video)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
        return CropRect(x: (clipped.minX - video.minX) / video.width,
                        y: (clipped.minY - video.minY) / video.height,
                        width: clipped.width / video.width,
                        height: clipped.height / video.height)
    }
}
