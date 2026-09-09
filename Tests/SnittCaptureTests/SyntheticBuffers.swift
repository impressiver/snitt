// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import CoreMedia
import CoreVideo

/// Builds a solid-grey video sample buffer. Used to drive the capture
/// pipeline in tests without a real screen.
func makeVideoBuffer(at seconds: Double, size: CGSize,
                      pixelFormat: OSType = kCVPixelFormatType_32BGRA) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault,
                        Int(size.width), Int(size.height),
                        pixelFormat, nil, &pixelBuffer)
    let buffer = pixelBuffer!

    CVPixelBufferLockBaseAddress(buffer, [])
    if pixelFormat == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 128,
               CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescriptionOut: &formatDescription
    )

    // Anchored to the real host clock, not an absolute small value: real
    // SCStream buffers carry host-clock timestamps, and CaptureSession's media
    // offset is computed against CMClockGetHostTimeClock(). A synthetic buffer
    // stamped with a bare CMTime(seconds:) would sit nowhere near "now" on
    // that clock, making any media-offset arithmetic exercised against it
    // meaningless (it would measure "seconds since boot", not seconds into
    // the recording).
    let anchor = CMClockGetTime(CMClockGetHostTimeClock())
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTimeAdd(anchor, CMTime(seconds: seconds, preferredTimescale: 600)),
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription!,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer!
}

/// Builds a silent PCM audio sample buffer of one 1024-frame packet.
func makeAudioBuffer(at seconds: Double) -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
    )

    var formatDescription: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )

    let frameCount = 1024
    var blockBuffer: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: frameCount * 4,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: frameCount * 4,
        flags: 0, blockBufferOut: &blockBuffer
    )
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer!,
                               offsetIntoDestination: 0,
                               dataLength: frameCount * 4)

    var sampleBuffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer!,
        formatDescription: formatDescription!,
        sampleCount: frameCount,
        // Host-clock anchored for the same reason makeVideoBuffer is — see
        // its comment.
        presentationTimeStamp: CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                                         CMTime(seconds: seconds, preferredTimescale: 48_000)),
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer!
}

/// A video buffer stamped at an ABSOLUTE media time, not anchored to the host
/// clock.
///
/// `makeVideoBuffer(at:)` deliberately anchors to `CMClockGetHostTimeClock()`
/// so media-offset arithmetic is exercised the way real SCStream buffers
/// exercise it. Pause/resume arithmetic is about relative SPANS between
/// buffers, and an implementation-visible "now" makes the expected values
/// unwritable — a test asserting "the 4s frame is written at 2s" needs 4s to
/// mean 4s.
func makeVideoBufferAtAbsoluteTime(seconds: Double, size: CGSize) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                        kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    let buffer = pixelBuffer!
    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescriptionOut: &formatDescription)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
        decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil,
        formatDescription: formatDescription!, sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer)
    return sampleBuffer!
}
