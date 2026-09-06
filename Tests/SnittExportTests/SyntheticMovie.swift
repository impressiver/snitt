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
/// What pixels a synthetic frame is filled with.
///
/// `.flat` (the default) writes a solid gray frame: cheap to generate and
/// fine for every test that only cares that a movie exists, plays, has the
/// right duration, or has tracks paired correctly. But a flat frame
/// compresses to almost nothing regardless of bitrate or resolution — H.264
/// finds it trivial — so a fixture built entirely from flat frames sits at
/// the encoder's floor (header plus minimal frame data) no matter what
/// `fileLengthLimit` or scale is requested. Any test that needs the encoded
/// size to actually RESPOND to a size target (bitrate limit, scale
/// reduction) must use `.noise`: per-pixel random data that does not
/// compress, so both a bitrate limit and a resolution drop measurably
/// shrink the output.
enum SyntheticFrameContent {
    case flat
    case noise
    // Each frame filled with a value derived from its index, so "which frame
    // is on screen" is observable — needed once `AVPlayerItemVideoOutput`
    // fingerprinting (spike S7) is exercised. See the `SnittAppTests` copy of
    // this enum, which is the one Task 1 of the M4b plan actually wires up;
    // added here too so the two enums don't drift on this case specifically,
    // even though nothing in this target currently constructs `.ramp`.
    case ramp
}

/// What samples a synthetic audio track is filled with.
///
/// `.silent` (the default, and the only option before Task 1) writes zeroed
/// LPCM — fine for every test that only cares that an audio track exists and
/// pairs to the right source. But a mix that mutes an already-silent track
/// changes nothing observable: AAC encodes near-zero signal to essentially
/// the same size whether the mix's volume parameter is 0.0 or 1.0. A test
/// asserting that muting shrinks the exported file (`exportAppliesTheMix`)
/// needs `.tone` — a real sine wave — or it cannot fail no matter how the
/// mix is (mis)implemented; it would pass even if the mix were never applied
/// at all, because a silent source already encodes small.
enum SyntheticAudioContent {
    case silent
    case tone
}

func writeSyntheticMovie(to url: URL, seconds: Double,
                         size: CGSize = CGSize(width: 320, height: 240),
                         fps: Int32 = 30,
                         audioTrackCount: Int = 0,
                         content: SyntheticFrameContent = .flat,
                         audioContent: SyntheticAudioContent = .silent) async throws {
    nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    nonisolated(unsafe) let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
    ])
    videoInput.expectsMediaDataInRealTime = false

    let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
    ]

    nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: pixelBufferAttributes)

    // Our OWN pool, not `adaptor.pixelBufferPool`. See the NOTE below the
    // media-data loops for why: the adaptor's pool is owned by the writer's
    // internal state machine and can be torn down underneath a buffer request
    // racing a writer failure, crashing with a use-after-free. A pool we
    // allocate ourselves, from the same attributes, has no such lifecycle tie
    // to the writer and cannot be pulled out from under us.
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

    // NOTE: this file is deliberately duplicated in
    // `Tests/SnittAppTests/SyntheticMovie.swift` (see this file's top-level
    // doc comment for why the duplication itself is deliberate). Both
    // copies must stay in step — in particular the `writer.status ==
    // .failed` checks in the video and audio media-data loops below (correct
    // and still useful for terminating promptly), AND the use of our own
    // `pool` above instead of `adaptor.pixelBufferPool`. The latter used to
    // be a real use-after-free: if the writer fails mid-stream,
    // `isReadyForMoreMediaData` can stay true while AVFoundation tears down
    // the adaptor's pixel buffer pool, so `adaptor.pixelBufferPool` returns a
    // non-nil but dangling pool and `CVPixelBufferPoolCreatePixelBuffer`
    // crashes dereferencing freed memory (SIGSEGV, confirmed via crash
    // report from the `SnittAppTests` copy, twice — a `writer.status ==
    // .failed` check alone was not enough, since the teardown can happen
    // between that check and the pool read/buffer creation a few lines
    // later). Owning the pool removes the race instead of narrowing it. Fix
    // this hazard in one copy, fix it in both.
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
                let byteCount = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
                switch content {
                case .flat:
                    memset(base, 128, byteCount)
                case .noise:
                    // Per-pixel random bytes, regenerated every frame so
                    // there is no exploitable redundancy across time either
                    // (H.264's inter-frame prediction would otherwise
                    // collapse a repeated noise frame just as flatly as a
                    // solid color). This is what makes bitrate limits and
                    // scale reduction actually change the encoded size.
                    //
                    // Seeded, not `arc4random_buf`: an unseeded fill makes
                    // every run's frame content — and therefore its encoded
                    // size — different, which is fatal for a test that
                    // asserts a byte threshold. `scaleReductionActuallyShrinksTheFile`
                    // measurably flaked from exactly this (340,083 and
                    // 362,233 bytes against a 300,000-byte target in two of
                    // three full-suite runs). A fixed-seed generator keeps
                    // the noise just as incompressible while making the
                    // output byte-for-byte reproducible across runs.
                    fillWithSeededNoise(base, byteCount: byteCount,
                                        seed: UInt64(videoProgress.value) &+ 1)
                case .ramp:
                    // Kept in step with the `SnittAppTests` copy's `.ramp`
                    // fill so the two enums agree on more than just the case
                    // name. See that copy's `writeSyntheticMovie` doc comment
                    // for why (spike S7 / M4b frame-identity scrubbing).
                    memset(base, Int32(20 + (videoProgress.value * 7) % 200), byteCount)
                }
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
                    guard let sampleBuffer = makeAudioSampleBuffer(
                        formatDescription: formatDescription,
                        frameCount: framesThisPacket,
                        startFrame: audioProgress.value,
                        sampleRate: audioSampleRate,
                        content: audioContent)
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

/// Fills `byteCount` bytes at `base` with high-entropy, deterministic noise.
///
/// Backed by SplitMix64, seeded per call (typically per frame) so content
/// stays reproducible run to run — a fixed input to `writeSyntheticMovie`
/// always encodes to the same byte size — while remaining just as
/// incompressible as `arc4random_buf` was: every output bit is a fresh
/// avalanche of the counter, not a repeating or structured pattern an
/// encoder could exploit.
private func fillWithSeededNoise(_ base: UnsafeMutableRawPointer, byteCount: Int, seed: UInt64) {
    var state = seed
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    let buffer = base.assumingMemoryBound(to: UInt64.self)
    let wordCount = byteCount / MemoryLayout<UInt64>.size
    for i in 0..<wordCount {
        buffer[i] = next()
    }
    let remainder = byteCount - wordCount * MemoryLayout<UInt64>.size
    if remainder > 0 {
        let tail = base.advanced(by: wordCount * MemoryLayout<UInt64>.size)
            .assumingMemoryBound(to: UInt8.self)
        let value = next()
        withUnsafeBytes(of: value) { bytes in
            for i in 0..<remainder { tail[i] = bytes[i] }
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

/// One packet of LPCM audio, timestamped by frame offset — silent zeros or a
/// real sine tone depending on `content` (see `SyntheticAudioContent`).
/// Small, deliberately duplicated version of the same idea as
/// `Tests/SnittCaptureTests/SyntheticBuffers.swift`'s `makeAudioBuffer` — see
/// this file's top-level doc comment for why it isn't shared directly.
private func makeAudioSampleBuffer(formatDescription: CMAudioFormatDescription,
                                   frameCount: Int, startFrame: Int,
                                   sampleRate: Double,
                                   content: SyntheticAudioContent) -> CMSampleBuffer? {
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

    switch content {
    case .silent:
        break
    case .tone:
        // 440Hz sine at 0.8 amplitude, matching the track's format
        // (32-bit float LPCM, see `writeSyntheticMovie` above). Phase is
        // continuous across packets via `startFrame`, so there is no
        // discontinuity an encoder could flatten into silence at packet
        // boundaries.
        var samples = [Float](repeating: 0, count: frameCount)
        let frequency = 440.0
        for i in 0..<frameCount {
            let t = Double(startFrame + i) / sampleRate
            samples[i] = Float(0.8 * sin(2.0 * Double.pi * frequency * t))
        }
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: bytes.count)
        }
    }

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
