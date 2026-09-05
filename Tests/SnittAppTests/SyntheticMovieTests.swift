import AVFoundation
import Foundation
import Testing

/// Mean sample value over a sparse stride of a `CGImage`'s pixel data — a
/// cheap fingerprint sufficient to tell "which frame is this" apart, per
/// spike S7. Not pixel-exact comparison; nothing here needs that.
private func meanSample(of image: CGImage) -> Int {
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return 0 }
    let length = CFDataGetLength(data)
    guard length > 0 else { return 0 }
    let stride = max(1, length / 4096)
    var total = 0
    var count = 0
    var offset = 0
    while offset < length {
        total += Int(bytes[offset])
        count += 1
        offset += stride
    }
    return count > 0 ? total / count : 0
}

@Test("Ramp frames are distinguishable from one another")
func rampFramesDiffer() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ramp-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeSyntheticMovie(to: url, seconds: 2, content: .ramp)

    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var fingerprints: Set<Int> = []
    for seconds in [0.2, 1.0, 1.8] {
        let image = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        fingerprints.insert(meanSample(of: image))
    }
    // The whole point. With the default `.flat` content this is 1, and every
    // "which frame is showing" assertion in M4b would pass vacuously.
    #expect(fingerprints.count == 3)
}

@Test("Flat content is still the default, so existing fixtures are unchanged")
func flatRemainsDefault() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flat-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeSyntheticMovie(to: url, seconds: 1)   // no content: argument

    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    // Zero tolerance, matching `rampFramesDiffer` above: verified by mutation
    // that without it, this test does not discriminate at all. Default
    // (loose) `AVAssetImageGenerator` tolerance snaps both 0.2s and 0.8s
    // requests to the same nearby frame regardless of what `content` is in
    // effect, so `fingerprints.count == 1` held even after mutating the
    // default to `.ramp` — a false pass. Forcing exact decode is what makes
    // this test sensitive to which content mode actually ran.
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var fingerprints: Set<Int> = []
    for seconds in [0.2, 0.8] {
        let image = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        fingerprints.insert(meanSample(of: image))
    }
    // Discriminating against making `.ramp` the default, which would silently
    // change every other fixture in the suite.
    #expect(fingerprints.count == 1)
}
