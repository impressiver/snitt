import AVFoundation
import CoreVideo
import Foundation

/// Writes a tiny real `.mov` file directly against `AVAssetWriter`.
///
/// `SnittExport` must not depend on `SnittCapture` (see `Package.swift`), so
/// the synthetic-buffer helpers in `Tests/SnittCaptureTests` are not
/// importable from here — importing the capture test target would smuggle
/// that forbidden dependency back in through the test graph. This is a
/// deliberate, small duplication of the same idea (a solid-colour video
/// track written frame by frame) rather than sharing code across the
/// boundary the architecture draws.
///
/// Written as a plain synchronous polling loop, rather than
/// `requestMediaDataWhenReady`'s callback, so there is nothing here for
/// strict concurrency to complain about: everything runs on the calling
/// thread and nothing crosses an `@Sendable` boundary.
func writeSyntheticMovie(to url: URL, seconds: Double,
                         size: CGSize = CGSize(width: 320, height: 240),
                         fps: Int32 = 30) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
    ])
    videoInput.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])

    guard writer.canAdd(videoInput) else {
        throw NSError(domain: "SyntheticMovie", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot add video input"])
    }
    writer.add(videoInput)

    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "SyntheticMovie", code: 2) }
    writer.startSession(atSourceTime: .zero)

    let frameCount = Int((seconds * Double(fps)).rounded())
    let frameDuration = CMTime(value: 1, timescale: fps)

    for frame in 0..<frameCount {
        while !videoInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }

        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "SyntheticMovie", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "no pixel buffer pool"])
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { continue }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 128,
                   CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
        adaptor.append(buffer, withPresentationTime: presentationTime)
    }

    videoInput.markAsFinished()

    let finishSemaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { finishSemaphore.signal() }
    finishSemaphore.wait()

    if writer.status == .failed {
        throw writer.error ?? NSError(domain: "SyntheticMovie", code: 3)
    }
}
