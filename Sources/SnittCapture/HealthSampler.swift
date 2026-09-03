import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SnittDocument

/// Cheap health metrics gathered during the existing writer pass (§12.1).
///
/// Exists because an agent is blind to its own output: a recording of the wrong
/// window, an occluded surface, or a dead microphone returns a valid path and
/// exit 0 today. These are WARNINGS, never failures — a legitimately static UI
/// demo will trip low frame variance, so no threshold gates anything until it
/// has been tuned against real recordings.
///
/// Sampling is deliberately sparse: every Nth frame, and a grid within it. The
/// cost has to stay far below the encode it rides along with, or it would
/// change the thing it is measuring.
public final class HealthSampler: @unchecked Sendable {
    /// Every Nth video frame is inspected.
    public static let frameStride = 30
    /// Pixels are sampled on a grid this many rows/columns apart.
    public static let pixelStride = 64

    private let lock = NSLock()
    private var frameIndex = 0
    private var frameVariances: [Double] = []
    private var micSumOfSquares = 0.0, micSampleCount = 0
    private var systemSumOfSquares = 0.0, systemSampleCount = 0

    public init() {}

    public static func variance(ofLuma samples: [Double]) -> Double {
        guard samples.count > 1 else { return 0 }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let sum = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sum / Double(samples.count)
    }

    public static func rms(ofFloatSamples samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    public func observe(_ buffer: CMSampleBuffer, track: TrackKind) {
        switch track {
        case .video: observeVideo(buffer)
        case .microphone, .systemAudio: observeAudio(buffer, track: track)
        }
    }

    private func observeVideo(_ buffer: CMSampleBuffer) {
        lock.lock()
        let index = frameIndex
        frameIndex += 1
        lock.unlock()
        guard index % Self.frameStride == 0 else { return }

        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let width = CVPixelBufferGetWidth(pixels)

        // The offset arithmetic below assumes chunky BGRA at 4 bytes per pixel.
        // True today because CaptureSession never sets configuration.pixelFormat
        // and BGRA is the default. If that ever changes to a planar format,
        // CVPixelBufferGetBytesPerRow returns 0, every sample is skipped, and
        // this would report variance 0 — indistinguishable from a black
        // capture. Skip explicitly rather than reporting a false measurement.
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return }

        // BGRA: take the green channel as a luma proxy. Cheap, and green
        // carries most of perceived luminance.
        var samples: [Double] = []
        for row in stride(from: 0, to: height, by: Self.pixelStride) {
            for column in stride(from: 0, to: width, by: Self.pixelStride) {
                let offset = row * rowBytes + column * 4 + 1
                guard offset < rowBytes * height else { continue }
                samples.append(Double(bytes[offset]))
            }
        }
        let variance = Self.variance(ofLuma: samples)
        lock.lock(); frameVariances.append(variance); lock.unlock()
    }

    private func observeAudio(_ buffer: CMSampleBuffer, track: TrackKind) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            return   // only Float32 PCM is measured; anything else is skipped
        }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        // Only the first AudioBuffer is read. Correct today because
        // CaptureSession forces channelCount = 1 for both audio tracks; must
        // be revisited if/when stereo (non-interleaved) capture lands, since
        // that would silently under-measure or make this call return
        // non-noErr with a single-buffer bufferListSize.
        guard status == noErr, let data = list.mBuffers.mData else { return }

        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }

        // The block buffer OWNS the samples `mData` points at, and ARC cannot
        // see that dependency — the pointer is not syntactically derived from
        // it — so without this the optimiser may release it before the loop
        // reads. This is the documented hazard of the RetainedBlockBuffer API.
        withExtendedLifetime(blockBuffer) {
            let pointer = data.assumingMemoryBound(to: Float.self)
            var sum = 0.0
            for index in 0..<count {
                let sample = Double(pointer[index])
                sum += sample * sample
            }

            lock.lock()
            switch track {
            case .microphone: micSumOfSquares += sum; micSampleCount += count
            case .systemAudio: systemSumOfSquares += sum; systemSampleCount += count
            case .video: break
            }
            lock.unlock()
        }
    }

    public func result() -> CaptureHealth {
        lock.lock(); defer { lock.unlock() }
        let meanVariance = frameVariances.isEmpty
            ? nil
            : frameVariances.reduce(0, +) / Double(frameVariances.count)
        let mic = micSampleCount > 0
            ? (micSumOfSquares / Double(micSampleCount)).squareRoot() : nil
        let system = systemSampleCount > 0
            ? (systemSumOfSquares / Double(systemSampleCount)).squareRoot() : nil
        return CaptureHealth(meanFrameVariance: meanVariance,
                             micRMS: mic, systemAudioRMS: system)
    }
}
