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
/// - Parameter audioTrackCount: number of silent LPCM audio tracks to write,
///   in addition to the video track. Needed to exercise
///   `CompositionBuilder`'s per-source-track audio pairing, which a
///   video-only synthetic movie (`sourceAudio == []`) never runs.
func writeSyntheticMovie(to url: URL, seconds: Double,
                         size: CGSize = CGSize(width: 320, height: 240),
                         fps: Int32 = 30,
                         audioTrackCount: Int = 0) throws {
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
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
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
    videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic-movie.video")) {
        while videoInput.isReadyForMoreMediaData {
            guard videoProgress.value < frameCount else {
                videoInput.markAsFinished()
                group.leave()
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
        for (index, input) in audioInputs.enumerated() {
            group.enter()
            let audioProgress = FrameCounter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic-movie.audio.\(index)")) {
                while input.isReadyForMoreMediaData {
                    guard audioProgress.value < totalAudioFrames else {
                        input.markAsFinished()
                        group.leave()
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

    group.wait()

    let finishSemaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { finishSemaphore.signal() }
    finishSemaphore.wait()

    if writer.status == .failed {
        throw writer.error ?? NSError(domain: "SyntheticMovie", code: 3)
    }
}

/// Mutable frame/sample-count cursor, boxed so each `requestMediaDataWhenReady`
/// closure can advance its own progress across repeated invocations on its
/// own dedicated queue. Never touched from more than one queue.
private final class FrameCounter: @unchecked Sendable {
    var value = 0
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
