import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import SnittDocument

/// The Finder icon for a `.snitt` bundle: a frame from the recording itself,
/// under Snitt's record dot.
///
/// A folder of recordings is unreadable without this. Every bundle is named
/// `Snitt-<epoch>.snitt` and every one of them carries the same generic package
/// icon, so telling yesterday's bug report from this morning's demo means
/// opening them one at a time. The captured frame is the only thing that
/// distinguishes one from another at a glance — which is why it gets the whole
/// icon and the branding is a badge in the corner rather than a frame around
/// the outside. At 16 and 32 points, where a document icon is actually seen
/// most, chrome is indistinguishable from blur and costs the picture the space
/// that makes it recognisable.
///
/// Composed through `CGContext` rather than `NSImage.lockFocus()` deliberately:
/// `lockFocus` wants a window server, the test bundle has no screen, and an
/// icon that can only be produced on a logged-in desktop cannot be tested.
public enum RecordingIcon {

    // MARK: - Geometry
    //
    // Every constant is a FRACTION of the icon's side, so one composition
    // serves all seven sizes the Finder asks for. Pixel constants would need a
    // layout per size, and the sizes would drift apart the first time one was
    // adjusted.

    static let cornerFraction: CGFloat = 115.0 / 512.0
    static let badgeInsetFraction: CGFloat = 112.0 / 512.0
    static let badgeRadiusFraction: CGFloat = 52.0 / 512.0
    static let badgeRingFraction: CGFloat = 11.0 / 512.0
    static let borderWidthFraction: CGFloat = 4.0 / 512.0

    /// Opacity of the scrim at the very bottom of the icon.
    ///
    /// The badge sits on whatever the recording happened to contain there. On a
    /// dark terminal it reads fine unaided; on a white documentation page the
    /// white ring vanishes into the background and the dot looks like a stray
    /// red mark. The scrim guarantees the ring always has something to separate
    /// it from.
    static let scrimAlpha: CGFloat = 0.55

    /// Sizes baked into the stamped icon.
    ///
    /// The Finder asks for 16 (list and column view) through 512 (Get Info),
    /// and Retina doubles every one. Supplying a single 512 and letting the
    /// system downscale gives a muddy 16 and 32, which are the sizes that
    /// matter most.
    public static let renderedSides: [Int] = [16, 32, 64, 128, 256, 512, 1024]

    /// Snitt's record red, matching `Resources/AppIcon.png`.
    static let recordRed = CGColor(srgbRed: 0.933, green: 0.267, blue: 0.267, alpha: 1)
    /// The app icon's window-outline slate, used here only as a hairline edge.
    static let slate = CGColor(srgbRed: 0.541, green: 0.576, blue: 0.659, alpha: 0.5)

    // MARK: - Choosing the frame

    /// How much detail a candidate frame carries, as the variance of its
    /// luminance on a 32x32 downscale.
    ///
    /// Scored at 32x32 on purpose, not merely for speed: that is roughly the
    /// size the icon is actually seen at, so this measures the structure that
    /// will still be visible in the Finder rather than detail that will not.
    /// High-frequency noise averages back to flat here and scores low, which
    /// is the right answer — a frame of static is no more recognisable as a
    /// thumbnail than a blank one.
    ///
    /// This is the whole reason the poster is not simply "the first frame". A
    /// screen recording opens on whatever was there before the interesting part
    /// started — a blank desktop, a window mid-draw, a white page that has not
    /// painted yet — and every one of those scores near zero here while any
    /// frame with actual content on it scores far higher.
    static func detailScore(of image: CGImage) -> Double {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var luminance = [Double]()
        luminance.reserveCapacity(side * side)
        for p in stride(from: 0, to: pixels.count, by: 4) {
            luminance.append(0.299 * Double(pixels[p])
                             + 0.587 * Double(pixels[p + 1])
                             + 0.114 * Double(pixels[p + 2]))
        }
        let mean = luminance.reduce(0, +) / Double(luminance.count)
        return luminance.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luminance.count)
    }

    /// Map an offset measured along the KEPT material onto a time in the
    /// source movie.
    ///
    /// The poster has to show what the recording *is*, not what was captured.
    /// Trimming a dead lead-in is the single most common edit this app exists
    /// to make, and sampling the source directly would keep choosing the poster
    /// from exactly the seconds the user just deleted.
    static func sourceTime(atKeptOffset offset: Double, in kept: [TimeRange]) -> Double? {
        var remaining = offset
        for range in kept {
            let span = range.end - range.start
            if remaining <= span { return range.start + max(0, remaining) }
            remaining -= span
        }
        return kept.last.map(\.end)
    }

    /// The frame that best represents the recording.
    ///
    /// - Parameter kept: the ranges surviving the EDL. Empty means the whole
    ///   movie, which is the state at finalization before any edit exists.
    public static func posterFrame(movieAt url: URL,
                                   within kept: [TimeRange] = [],
                                   samples: Int = 6) async throws -> CGImage? {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, samples > 0 else { return nil }

        let ranges = kept.isEmpty ? [TimeRange(start: 0, end: duration)] : kept
        let keptDuration = ranges.reduce(0) { $0 + ($1.end - $1.start) }
        guard keptDuration > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Decode at icon scale, not capture scale. A 5K screen recording hands
        // back 4112x2580 frames — 10.6 megapixels each, six of them, every one
        // scaled down and discarded. Capping here moved stamping a real 32s
        // recording from 960ms to a fraction of it, which is the difference
        // between this being able to run when a recording ends and not.
        //
        // 2048 rather than 1024: the icon aspect-FILLS a square, so the frame's
        // SHORTER side is what has to reach the largest rendered size (1024,
        // for 512pt at 2x). A 16:10 frame capped at 2048 keeps 1285 on its
        // short edge, which clears that with room to spare.
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        // Tolerances left at their permissive defaults ON PURPOSE. Forcing
        // `.zero` before makes every sample an exact-frame seek — decode from
        // the preceding keyframe forward to the requested instant — and this
        // wants "a representative frame", not a specific one. Nothing
        // downstream records or displays which timestamp the poster came from,
        // so precision here buys nothing and costs most of the runtime.

        var best: (score: Double, image: CGImage)?
        for i in 0..<samples {
            // Spread across the middle 84%: the last moments of a recording are
            // as likely to be a closing dialog or a half-dismissed window as
            // the first are to be a blank one.
            let fraction = samples == 1 ? 0.5 : 0.08 + 0.84 * Double(i) / Double(samples - 1)
            guard let seconds = sourceTime(atKeptOffset: keptDuration * fraction, in: ranges)
            else { continue }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            let score = detailScore(of: image)
            if best == nil || score > best!.score { best = (score, image) }
        }
        return best?.image
    }

    // MARK: - Composition

    /// Draw the icon at one size.
    ///
    /// Aspect-FILL rather than fit: letterbox bars around a 16:9 frame in a
    /// square icon read as a rendering bug, and the crop costs nothing because
    /// the icon is an identifier rather than a preview.
    public static func compose(poster: CGImage, side: Int) -> CGImage? {
        let s = CGFloat(side)
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: s, height: s)
        let radius = s * cornerFraction

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
        ctx.clip()

        let scale = max(s / CGFloat(poster.width), s / CGFloat(poster.height))
        let w = CGFloat(poster.width) * scale, h = CGFloat(poster.height) * scale
        ctx.draw(poster, in: CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2,
                                    width: w, height: h))

        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
                     CGColor(srgbRed: 0, green: 0, blue: 0, alpha: scrimAlpha)] as CFArray,
            locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0),
                                   options: [])
        }
        ctx.restoreGState()

        // A hairline edge so a recording of a white page still has a boundary
        // against the Finder's white background.
        let inset = s * borderWidthFraction / 2
        ctx.setStrokeColor(slate)
        ctx.setLineWidth(s * borderWidthFraction)
        ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                           cornerWidth: radius - inset, cornerHeight: radius - inset,
                           transform: nil))
        ctx.strokePath()

        let center = CGPoint(x: bounds.maxX - s * badgeInsetFraction,
                             y: bounds.minY + s * badgeInsetFraction)
        let dot = s * badgeRadiusFraction, ring = s * badgeRingFraction
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - dot - ring, y: center.y - dot - ring,
                                   width: (dot + ring) * 2, height: (dot + ring) * 2))
        ctx.setFillColor(recordRed)
        ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot,
                                   width: dot * 2, height: dot * 2))

        return ctx.makeImage()
    }

    /// The multi-resolution image the Finder consumes.
    public static func iconImage(poster: CGImage) -> NSImage? {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        var any = false
        for side in renderedSides {
            guard let rendered = compose(poster: poster, side: side) else { continue }
            let rep = NSBitmapImageRep(cgImage: rendered)
            // Each rep advertises its own point size, so the Finder selects the
            // one drawn for the size it is about to display instead of
            // resampling a single large one.
            rep.size = NSSize(width: side, height: side)
            image.addRepresentation(rep)
            any = true
        }
        return any ? image : nil
    }

    // MARK: - Stamping

    /// Give a bundle its icon, choosing the frame from the material its EDL
    /// keeps.
    ///
    /// - Returns: `false` when no frame could be read — a zero-length or
    ///   unreadable capture. The bundle keeps the generic icon; a recording
    ///   that cannot be thumbnailed is not a recording that should fail to
    ///   save.
    /// Stamp off the caller's timeline, swallowing failure.
    ///
    /// Stamping a real 5K recording takes around half a second — six seeks
    /// plus seven renders — which is far too much to sit in front of a
    /// recording reporting that it stopped. `RecordingCoordinator` already
    /// carries a note that the stop path must not grow work that gates its
    /// return, and this is exactly that work.
    ///
    /// Swallowing is right here and nowhere else in this file: an icon is
    /// decoration, and a recording that captured fine must not report failure
    /// because its thumbnail did not render. The returned task is the seam —
    /// tests await it instead of racing it.
    @discardableResult
    public static func stampInBackground(bundle: SnittBundle) -> Task<Bool, Never> {
        Task.detached(priority: .utility) {
            ((try? await stamp(bundle: bundle)) ?? false)
        }
    }

    @discardableResult
    public static func stamp(bundle: SnittBundle) async throws -> Bool {
        var kept: [TimeRange] = []
        if let edl = try? EditDecisionList.read(from: bundle) {
            let duration = try? await AVURLAsset(url: bundle.captureURL).load(.duration).seconds
            if let duration, duration.isFinite, duration > 0 {
                kept = KeptRanges.compute(duration: duration, cuts: edl.cuts.map(\.range))
            }
        }
        guard let poster = try await posterFrame(movieAt: bundle.captureURL, within: kept),
              let image = iconImage(poster: poster)
        else { return false }
        return NSWorkspace.shared.setIcon(image, forFile: bundle.url.path, options: [])
    }
}
