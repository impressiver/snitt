import AVFoundation
import CoreVideo
import Foundation

/// Writes a tiny real `.mov` file directly against `AVAssetWriter`.
///
/// Duplicated from `Tests/SnittExportTests/SyntheticMovie.swift` deliberately
/// — see that file's doc comment. Swift Testing target sources don't share
/// private helpers across files, let alone across test targets, and
/// `SnittAppTests` needs a real `capture.mov` to close the M3c whole-branch
/// review finding that trim and export ran on two different clocks: a
/// metadata-only bundle (no `capture.mov` at all) cannot exercise that bug,
/// because there is no media duration to disagree with the wall-clock one.
///
/// This is a smaller copy — video only, no audio tracks — since
/// `AutomationHost.trim`/`.export` tests only need a real, readable movie
/// with a known duration, not the per-source-track audio pairing that
/// `SnittExportTests`' copy also exercises.
func writeSyntheticMovie(to url: URL, seconds: Double,
                         size: CGSize = CGSize(width: 320, height: 240),
                         fps: Int32 = 30) async throws {
    nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    nonisolated(unsafe) let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
    ])
    videoInput.expectsMediaDataInRealTime = false

    nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(
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

    let videoProgress = FrameCounter()
    let videoFinished = OnceFlag()
    // See `Tests/SnittExportTests/SyntheticMovie.swift` for why this uses
    // `requestMediaDataWhenReady` plus a `group.notify` continuation rather
    // than `group.wait()`/`DispatchSemaphore.wait()`: both block the calling
    // cooperative-pool thread and can deadlock the whole suite once enough
    // tests are blocked in here concurrently.
    let group = DispatchGroup()
    group.enter()
    videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic-movie.video")) {
        while videoInput.isReadyForMoreMediaData {
            guard videoProgress.value < frameCount else {
                videoFinished.fireOnce {
                    videoInput.markAsFinished()
                    group.leave()
                }
                return
            }
            guard let pool = adaptor.pixelBufferPool else { return }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { continue }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 128,
                       CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(videoProgress.value))
            adaptor.append(buffer, withPresentationTime: presentationTime)
            videoProgress.value += 1
        }
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        group.notify(queue: .global()) {
            continuation.resume()
        }
    }

    let finishGuard = OnceFlag()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.finishWriting {
            finishGuard.fireOnce {
                if writer.status == .failed {
                    continuation.resume(throwing: writer.error ?? NSError(domain: "SyntheticMovie", code: 3))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Mutable frame-count cursor. See `SnittExportTests`' copy.
private final class FrameCounter: @unchecked Sendable {
    var value = 0
}

/// Makes a state transition happen exactly once. See `SnittExportTests`' copy.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fireOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}
