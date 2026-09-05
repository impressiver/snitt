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
/// Originally video-only, since `AutomationHost.trim`/`.export` tests only
/// needed a real, readable movie with a known duration. `audioTrackCount`
/// was added (silent LPCM only, no `.tone` option — `SnittExportTests`' copy
/// has that for size-target tests, which don't live in this target) for
/// `PreviewControllerTests.attachesTheGivenComposition`, which needs a
/// fixture whose EDL can produce a non-nil `AVAudioMix` (a muted track) —
/// `built.audioMix` is nil whenever there are no audio tracks at all.
///
/// - Parameter maxKeyFrameInterval: opt-in `AVVideoMaxKeyFrameIntervalKey`.
///   `nil` (the default) leaves the encoder's own keyframe placement alone —
///   no existing test's fixture changes. With this left unset, the encoder
///   places keyframes so densely on this fixture's low-motion content that a
///   tolerant seek has nothing to snap to but the exact target, which is
///   exactly the failure mode this parameter exists to let a test escape:
///   pass a value large relative to the clip's total frame count (e.g. the
///   frame count itself, forcing a single keyframe at the very start) to
///   produce a movie where `AVPlayer.seek(to:)` WITHOUT
///   `toleranceBefore/After: .zero` visibly lands somewhere other than the
///   requested time, and where dropping those tolerances is therefore
///   something a test can actually detect rather than something that quietly
///   changes nothing.
func writeSyntheticMovie(to url: URL, seconds: Double,
                         size: CGSize = CGSize(width: 320, height: 240),
                         fps: Int32 = 30,
                         maxKeyFrameInterval: Int32? = nil,
                         audioTrackCount: Int = 0) async throws {
    nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    var videoOutputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
    ]
    if let maxKeyFrameInterval {
        videoOutputSettings[AVVideoCompressionPropertiesKey] = [
            AVVideoMaxKeyFrameIntervalKey: maxKeyFrameInterval,
        ]
    }
    nonisolated(unsafe) let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
    videoInput.expectsMediaDataInRealTime = false

    let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
    ]

    nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: pixelBufferAttributes)

    // Our OWN pool, not `adaptor.pixelBufferPool`. See the NOTE below for why:
    // the adaptor's pool is owned by the writer's internal state machine and
    // can be torn down underneath a buffer request racing a writer failure,
    // crashing with a use-after-free. A pool we allocate ourselves, from the
    // same attributes, has no such lifecycle tie to the writer and cannot be
    // pulled out from under us.
    var framePool: CVPixelBufferPool?
    let poolStatus = CVPixelBufferPoolCreate(
        kCFAllocatorDefault, nil, pixelBufferAttributes as CFDictionary, &framePool)
    guard poolStatus == kCVReturnSuccess, let framePool else {
        throw NSError(domain: "SyntheticMovie", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "cannot create pixel buffer pool"])
    }
    nonisolated(unsafe) let pool = framePool

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

    let videoProgress = FrameCounter()
    let videoFinished = OnceFlag()
    // See `Tests/SnittExportTests/SyntheticMovie.swift` for why this uses
    // `requestMediaDataWhenReady` plus a `group.notify` continuation rather
    // than `group.wait()`/`DispatchSemaphore.wait()`: both block the calling
    // cooperative-pool thread and can deadlock the whole suite once enough
    // tests are blocked in here concurrently.
    //
    // NOTE: this file is deliberately duplicated in
    // `Tests/SnittExportTests/SyntheticMovie.swift` (see that file's doc
    // comment for why). Both copies must stay in step — in particular the
    // `writer.status == .failed` check below (correct and still useful for
    // terminating promptly), AND the use of our own `pool` above instead of
    // `adaptor.pixelBufferPool`. The latter used to be a real use-after-free:
    // if the writer fails mid-stream, `isReadyForMoreMediaData` can stay true
    // while AVFoundation tears down the adaptor's pixel buffer pool, so
    // `adaptor.pixelBufferPool` returns a non-nil but dangling pool and
    // `CVPixelBufferPoolCreatePixelBuffer` crashes dereferencing freed memory
    // (SIGSEGV, confirmed via crash report — a `writer.status == .failed`
    // check alone was not enough, since the teardown can happen between that
    // check and the pool read/buffer creation a few lines later). Owning the
    // pool removes the race instead of narrowing it. Fix this hazard in one
    // copy, fix it in both.
    let group = DispatchGroup()
    group.enter()
    videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic-movie.video")) {
        while videoInput.isReadyForMoreMediaData {
            if writer.status == .failed {
                videoFinished.fireOnce {
                    videoInput.markAsFinished()
                    group.leave()
                }
                return
            }
            guard videoProgress.value < frameCount else {
                videoFinished.fireOnce {
                    videoInput.markAsFinished()
                    group.leave()
                }
                return
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
                    if writer.status == .failed {
                        audioFinished.fireOnce {
                            input.markAsFinished()
                            group.leave()
                        }
                        return
                    }
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
                        startFrame: audioProgress.value)
                    else { continue }
                    input.append(sampleBuffer)
                    audioProgress.value += framesThisPacket
                }
            }
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

/// Builds one packet of silent 32-bit float LPCM. Only `.silent` content is
/// needed in this target — see `writeSyntheticMovie`'s doc comment above for
/// why `.tone` was not ported over.
private func makeSilentAudioSampleBuffer(formatDescription: CMAudioFormatDescription,
                                         frameCount: Int, startFrame: Int) -> CMSampleBuffer? {
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
        presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: 48_000),
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer
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
