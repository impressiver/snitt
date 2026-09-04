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
/// Video and audio inputs are fed via `requestMediaDataWhenReady`, each on
/// its own queue, rather than a hand-rolled polling loop per input: with two
/// or more inputs on one `AVAssetWriter`, the writer withholds readiness from
/// a track that has run ahead of the others until they catch up (it needs
/// all tracks progressing for interleaving), and a loop that finishes one
/// input's samples before starting the next never lets the lagging inputs
/// catch up — every additional input beyond the first deadlocked outright.
/// Handing each input its own callback and queue, coordinated by a
/// `DispatchGroup`, is the pattern AVFoundation actually expects.
///
/// `async`, and waits via `withCheckedContinuation`/`group.notify` rather
/// than `DispatchGroup.wait()`/`DispatchSemaphore.wait()` — deliberately.
/// swift-testing runs tests concurrently by default, and this function used
/// to be synchronous, called from `async` tests. Both of its blocking waits
/// parked the CALLING thread, which belongs to Swift's cooperative thread
/// pool (one thread per core, not the unbounded thread pool GCD itself
/// uses). Once enough concurrently-running tests were blocked in here at
/// once, the pool was exhausted and the very callbacks needed to unblock
/// them (queued as tasks, not free-running threads) could never be
/// scheduled — the whole test run hung. `group.notify` and a completion
/// handler both resume from a GCD callback, off the cooperative pool
/// entirely, so nothing here parks a cooperative-pool thread.
///
/// - Parameter audioTrackCount: number of silent LPCM audio tracks to write,
///   in addition to the video track. Needed to exercise
///   `CompositionBuilder`'s per-source-track audio pairing, which a
///   video-only synthetic movie (`sourceAudio == []`) never runs.
func writeSyntheticMovie(to url: URL, seconds: Double,
                         size: CGSize = CGSize(width: 320, height: 240),
                         fps: Int32 = 30,
                         audioTrackCount: Int = 0) async throws {
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

    let audioSampleRate = 48_000.0
    var audioFormatDescription: CMAudioFormatDescription?
    var audioInputs: [AVAssetWriterInput] = []
    if audioTrackCount > 0 {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription)
        audioFormatDescription = formatDescription

        for _ in 0..<audioTrackCount {
            // `outputSettings: nil` + a source format hint keeps the track's
            // format as-is (LPCM passthrough) rather than requiring a
            // compression settings dictionary — irrelevant for a silent test
            // fixture, and one less thing that can fail to encode.
            nonisolated(unsafe) let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: formatDescription)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw NSError(domain: "SyntheticMovie", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "cannot add audio input"])
            }
            writer.add(input)
            audioInputs.append(input)
        }
    }

    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "SyntheticMovie", code: 2) }
    writer.startSession(atSourceTime: .zero)

    let frameCount = Int((seconds * Double(fps)).rounded())
    let frameDuration = CMTime(value: 1, timescale: fps)
    let packetFrameCount = 1024
    let totalAudioFrames = Int(seconds * audioSampleRate)

    let group = DispatchGroup()

    group.enter()
    let videoProgress = FrameCounter()
    // `AVAssetWriterInput.markAsFinished()` documents that
    // `requestMediaDataWhenReady`'s callback will not be invoked again
    // afterwards, but that promise is about future READINESS callbacks —
    // it says nothing about a callback already in flight, or about a
    // spurious re-entrant call racing the first. `OnceFlag` makes the
    // "finished" transition — and therefore `group.leave()` — idempotent
    // regardless, because `DispatchGroup.leave()` called more times than
    // `enter()` traps rather than warning.
    let videoFinished = OnceFlag()
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

    if let formatDescription = audioFormatDescription {
        for (index, loopInput) in audioInputs.enumerated() {
            nonisolated(unsafe) let input = loopInput
            group.enter()
            let audioProgress = FrameCounter()
            let audioFinished = OnceFlag()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic-movie.audio.\(index)")) {
                while input.isReadyForMoreMediaData {
                    guard audioProgress.value < totalAudioFrames else {
                        audioFinished.fireOnce {
                            input.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                    let framesThisPacket = min(packetFrameCount, totalAudioFrames - audioProgress.value)
                    guard let sampleBuffer = makeSilentAudioSampleBuffer(
                        formatDescription: formatDescription,
                        frameCount: framesThisPacket,
                        startFrame: audioProgress.value,
                        sampleRate: audioSampleRate)
                    else { continue }
                    input.append(sampleBuffer)
                    audioProgress.value += framesThisPacket
                }
            }
        }
    }

    // NOT group.wait(): see the doc comment above. group.notify's callback
    // fires on a GCD-managed queue once every enter() has a matching
    // leave(), so resuming the continuation there never parks a
    // cooperative-pool thread the way group.wait() did.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        group.notify(queue: .global()) {
            continuation.resume()
        }
    }

    // NOT a DispatchSemaphore.wait() for the same reason. finishWriting's
    // completion handler is documented to run exactly once, but OnceFlag
    // guards the continuation regardless — resuming a CheckedContinuation
    // twice traps rather than warns, so "the callback runs once" is an
    // invariant worth defending rather than trusting blindly.
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

/// Mutable frame/sample-count cursor, boxed so each `requestMediaDataWhenReady`
/// closure can advance its own progress across repeated invocations on its
/// own dedicated queue. Never touched from more than one queue.
private final class FrameCounter: @unchecked Sendable {
    var value = 0
}

/// Makes a state transition happen exactly once, even if the code path that
/// triggers it runs more than once or races itself. Used to guard
/// `group.leave()` (called more times than `enter()` traps) and
/// `CheckedContinuation.resume()` (called twice traps) against AVFoundation
/// completion handlers whose "exactly once" behaviour is documented but not
/// contractually enforced from the caller's side.
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

/// One packet of silent LPCM audio, timestamped by frame offset. Small,
/// deliberately duplicated version of the same idea as
/// `Tests/SnittCaptureTests/SyntheticBuffers.swift`'s `makeAudioBuffer` — see
/// this file's top-level doc comment for why it isn't shared directly.
private func makeSilentAudioSampleBuffer(formatDescription: CMAudioFormatDescription,
                                         frameCount: Int, startFrame: Int,
                                         sampleRate: Double) -> CMSampleBuffer? {
    var blockBuffer: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: frameCount * 4,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: frameCount * 4,
        flags: 0, blockBufferOut: &blockBuffer
    )
    guard let blockBuffer else { return nil }
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer,
                               offsetIntoDestination: 0,
                               dataLength: frameCount * 4)

    var sampleBuffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        presentationTimeStamp: CMTime(value: CMTimeValue(startFrame),
                                      timescale: CMTimeScale(sampleRate)),
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer
}
