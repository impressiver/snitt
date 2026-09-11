// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import ScreenCaptureKit
import CoreMedia
import SnittDocument

public struct CaptureOptions: Sendable {
    /// Terms the speech recogniser should expect (D81). Carried from the
    /// request that started the recording and stored in its metadata, so a
    /// transcription that happens later — or again — uses the hints the person
    /// who made the recording supplied.
    public var vocabulary: [String] = []
    public var captureMicrophone: Bool
    public var captureSystemAudio: Bool
    public var maxDuration: Duration?
    /// Log the fact of clicks and keystrokes (§4.2). Off by default: it costs
    /// the user a third TCC dialog (§4.10).
    public var logInputEvents: Bool

    public init(captureMicrophone: Bool = false,
                captureSystemAudio: Bool = true,
                maxDuration: Duration? = nil,
                logInputEvents: Bool = false) {
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
        self.maxDuration = maxDuration
        self.logInputEvents = logInputEvents
    }
}

public enum CaptureError: Error, Equatable {
    case alreadyRunning
    case notRunning
}

/// Owns the `SCStream` lifecycle and routes delivered buffers to a sink.
///
/// All three inputs arrive on this one stream against one clock, which is
/// why macOS 15 is the floor (spec sections 4.6 and 9).
public final class CaptureSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private let target: ResolvedTarget?
    private let sink: SampleBufferSink
    private let options: CaptureOptions

    /// Mutated only by `start()` and `stop()`, deliberately without lock
    /// protection: `stop()` awaits, and holding an `NSLock` across an await
    /// is unsound. Callers must invoke `start()`/`stop()` from a single
    /// serialized context — Task 10's `Recorder` is an actor, which provides
    /// that. `handle` never touches `stream`, so the delivery queue's
    /// concurrent access never races with it.
    private var stream: SCStream?
    private let lock = NSLock()
    private var didBegin = false
    /// Pause bookkeeping (M5e, D53). Guarded by `lock` like `didBegin`.
    ///
    /// `pauseRequested` is what `pause()`/`resume()` set; the LEDGER is only
    /// ever advanced inside `handle`, using a real buffer's presentation
    /// timestamp. That keeps every value in the ledger on the media clock —
    /// mixing a wall-clock pause instant into a media-clock shift is the kind
    /// of error that produces a file which plays perfectly with every marker in
    /// the wrong place.
    private var pauseRequested = false
    private var pauses = PauseLedger()
    /// The most recent video frame seen, for `screenshot` (M5e, D53).
    ///
    /// Exactly one is retained and replaced on every frame — the standard
    /// latest-frame pattern. Holding more would starve ScreenCaptureKit's
    /// buffer pool; holding none would mean a screenshot has to open a second
    /// capture, which is a different image at a different instant and defeats
    /// the point: D53 wants "what I saw" and "what I said about it" on ONE
    /// offset, which only holds if the screenshot IS a recorded frame.
    private var latestFrame: CMSampleBuffer?

    /// The presentation timestamp of the first delivered buffer — the video
    /// track's t=0, on SCStream's host/mach clock. Guarded by `lock` alongside
    /// `didBegin`, since both are set together in `handle(_:of:)`.
    private var firstPresentationTime: CMTime?

    public init(target: ResolvedTarget,
                sink: SampleBufferSink,
                options: CaptureOptions = CaptureOptions()) {
        self.target = target
        self.sink = sink
        self.options = options
        super.init()
    }

    private init(sink: SampleBufferSink) {
        self.target = nil
        self.sink = sink
        self.options = CaptureOptions()
        super.init()
    }

    /// Builds a session with no stream, for routing tests.
    static func forTesting(sink: SampleBufferSink) -> CaptureSession {
        CaptureSession(sink: sink)
    }

    public func start() async throws {
        guard let target else { throw CaptureError.notRunning }
        guard stream == nil else { throw CaptureError.alreadyRunning }

        let descriptor = target.descriptor
        let configuration = SCStreamConfiguration()
        configuration.width = descriptor.width
        configuration.height = descriptor.height
        configuration.capturesAudio = options.captureSystemAudio
        configuration.captureMicrophone = options.captureMicrophone
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Match AssetWriterSink's mono audio inputs explicitly. SCK defaults to
        // 2 channels, and feeding stereo PCM into a mono AAC input without a
        // channel layout is a known AVAssetWriter conversion failure. Stereo
        // system audio is a later enhancement; it requires the sink's inputs to
        // be configured per-track rather than identically.
        configuration.channelCount = 1

        // The filter arrives already resolved — by the picker for interactive
        // selection, or by cache re-resolution for the hotkey path. The session
        // deliberately does not participate in selection (§5.2).
        let stream = SCStream(filter: target.filter,
                              configuration: configuration,
                              delegate: nil)

        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: .global(qos: .userInitiated))
        if options.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio,
                                       sampleHandlerQueue: .global(qos: .userInitiated))
        }
        if options.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone,
                                       sampleHandlerQueue: .global(qos: .userInitiated))
        }

        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops the stream. Deliberately does NOT finish the sink: `Recorder`
    /// owns the bundle lifecycle and finishes it, so the sink is never
    /// finalized twice.
    public func stop() async throws {
        guard let stream else { throw CaptureError.notRunning }
        try await stream.stopCapture()
        self.stream = nil
    }

    /// §12.1's metrics, gathered by the sink during the writer pass.
    func health() -> CaptureHealth { sink.health.result() }

    /// Seconds from the video's t=0 to now, in the SAME time base the video
    /// track uses.
    ///
    /// Markers must not use wall-clock time: `Recorder.startedAt` is stamped
    /// before the stream starts delivering, so it precedes the first frame's
    /// presentation timestamp by however long SCStream takes to come up. A
    /// marker on the wrong clock points at the wrong moment (§4.12).
    ///
    /// Returns nil before the first buffer arrives, when there is no video
    /// time base to be relative to yet.
    /// Where "now" sits in the WRITTEN file — media elapsed minus everything
    /// paused, including a pause still open.
    ///
    /// This is the clock markers, cuts and the duration belong on, and
    /// `latestFrameForScreenshot` already says so in as many words: *"the
    /// instant this frame occupies in the written file, which is the clock
    /// markers and cuts use."* A pause is the ABSENCE of buffers — the writer
    /// cannot be paused — so file time and elapsed time diverge by exactly the
    /// paused total from the first pause onward.
    ///
    /// Nil before the first frame, like `mediaOffsetNow`.
    func outputOffsetNow() -> Double? {
        lock.lock()
        let first = firstPresentationTime
        let ledger = pauses
        lock.unlock()
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let elapsed = Self.mediaOffset(from: first, to: now) else { return nil }
        return elapsed - ledger.totalPausedSeconds(now: now)
    }

    /// Everything paused so far, for callers that need to correct a wall-clock
    /// span rather than ask for an instant.
    func totalPausedSecondsNow() -> Double {
        lock.lock()
        let ledger = pauses
        lock.unlock()
        return ledger.totalPausedSeconds(now: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func mediaOffsetNow() -> Double? {
        lock.lock()
        let first = firstPresentationTime
        lock.unlock()
        return Self.mediaOffset(from: first, to: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// The pure arithmetic behind `mediaOffsetNow()`, factored out because the
    /// host clock itself cannot be driven from a test.
    static func mediaOffset(from first: CMTime?, to now: CMTime) -> Double? {
        guard let first else { return nil }
        return CMTimeGetSeconds(CMTimeSubtract(now, first))
    }

    /// Falls back to wall clock when the media offset is implausible.
    ///
    /// The media offset assumes SCStream's presentation timestamps are on the
    /// host clock. That holds today, but it is an assumption no test can check
    /// without a live display — and when it is wrong the failure is silent and
    /// total: every marker lands at "seconds since boot" and chapters inherit
    /// it. A generous slack keeps the precise media offset in the normal case
    /// while turning a catastrophic mismatch into a slightly imprecise marker.
    ///
    /// The 5-second slack is deliberately generous and must never fire on a
    /// real recording — SCStream's startup latency is hundreds of
    /// milliseconds, not seconds — while still catching a clock-base
    /// mismatch, which is off by orders of magnitude, not seconds. Do not
    /// tighten this: a smaller slack risks firing on legitimate recordings
    /// under system load, which is worse than the imprecision it would save.
    ///
    /// The comparison is symmetric where the physics is one-sided. The media
    /// clock starts at the FIRST FRAME and the wall clock starts before
    /// `startCapture()`, so a legitimate `media` is always slightly LESS than
    /// `wallClock`; `media > wallClock` by any real margin is already a
    /// mismatch. The slack absorbs that today, so this is not a live defect —
    /// but anyone tightening the guard should make it one-sided rather than
    /// halving the 5.0.
    static func plausibleOffset(media: Double?, wallClock: Double?) -> Double? {
        guard let media else { return wallClock }
        guard let wallClock else { return media >= 0 ? media : nil }
        return abs(media - wallClock) <= 5.0 ? media : wallClock
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        handle(sampleBuffer, of: type)
    }

    /// The latest video frame and the OUTPUT time it sits at.
    ///
    /// The time is `adjusted`, not raw: it is the instant this frame occupies
    /// in the written file, which is the clock markers and cuts use. Returning
    /// the raw source time would put a screenshot's marker at a different
    /// place than the frame it came from as soon as anything had been paused.
    func latestFrameForScreenshot() -> (image: CVImageBuffer, outputTime: CMTime)? {
        lock.lock(); defer { lock.unlock() }
        guard let latestFrame,
              let image = CMSampleBufferGetImageBuffer(latestFrame) else { return nil }
        let start = firstPresentationTime ?? .zero
        let raw = CMSampleBufferGetPresentationTimeStamp(latestFrame)
        return (image, CMTimeSubtract(pauses.adjusted(raw), start))
    }

    /// Stops writing buffers until `resume()`. Idempotent.
    func pause() { lock.lock(); pauseRequested = true; lock.unlock() }

    /// Resumes writing. Idempotent.
    func resume() { lock.lock(); pauseRequested = false; lock.unlock() }

    /// Whether buffers are currently being dropped.
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pauseRequested }

    /// Total time spent paused so far, in seconds.
    var pausedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        let total = pauses.totalPaused
        return total.isValid ? total.seconds : 0
    }

    /// A copy of `buffer` with every timing shifted back by `offset`.
    ///
    /// Returns nil rather than throwing if the copy fails; the caller appends
    /// the original, which is worse (a gap) but not fatal — losing the buffer
    /// entirely would tear a hole in the recording that no later frame fills.
    static func retimed(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        let count = CMSampleBufferGetNumSamples(buffer)
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: max(1, count))
        var produced = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: timings.count, arrayToFill: &timings,
            entriesNeededOut: &produced) == noErr else { return nil }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp =
                    CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp =
                    CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: timings.count, sampleTimingArray: &timings,
            sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }

    /// Routes one buffer. Separated from the delegate method so tests can
    /// drive the pipeline without an SCStream (spec section 15).
    func handle(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let track = TrackKind(type) else { return }
        guard CMSampleBufferDataIsReady(buffer) else { return }

        // ScreenCaptureKit delivers .screen buffers for idle/blank/suspended
        // frames that carry no new surface. Appending one fails the
        // AVAssetWriter permanently — after which every later append is a
        // silent no-op — so a single idle frame on a static screen would
        // destroy the whole recording. Audio buffers carry no frame info and
        // are never filtered here.
        if type == .screen, !Self.isCompleteFrame(buffer) { return }

        // The lock is held across begin+append, not just across the didBegin
        // flip. ScreenCaptureKit delivers on a CONCURRENT queue, so releasing
        // it earlier would let an append from another track reach the sink
        // before the begin that must precede it — silently dropping the
        // session's first buffer. The sink serializes internally anyway, so
        // holding the lock here costs no real concurrency.
        lock.lock()
        defer { lock.unlock() }

        // Retained BEFORE the pause check below, deliberately: a screenshot
        // must work while paused. That is when an agent most wants one — it
        // paused to look at something.
        if type == .screen { latestFrame = buffer }

        // Pause transitions are settled HERE, against a real media timestamp,
        // rather than when pause()/resume() were called. A pause therefore
        // takes effect at the next buffer, which is sub-frame precision and
        // costs nothing, and the ledger never sees a clock other than this one.
        if pauseRequested, !pauses.isPaused {
            pauses.pause(at: buffer.presentationTimeStamp)
        } else if !pauseRequested, pauses.isPaused {
            pauses.resume(at: buffer.presentationTimeStamp)
        }
        // Dropped, not written: an AVAssetWriter session cannot be paused, so
        // the pause IS the absence of these buffers. Every later timestamp is
        // shifted back by the total paused time so the file stays continuous —
        // a viewer sees a jump, never a frozen gap.
        if pauses.isPaused { return }

        do {
            // The session starts at the first buffer's timestamp, so the
            // three tracks share one timeline from the same clock.
            if !didBegin {
                try sink.begin(at: buffer.presentationTimeStamp)
                didBegin = true
                firstPresentationTime = buffer.presentationTimeStamp
            }
            let toAppend = pauses.totalPaused == .zero
                ? buffer
                : (Self.retimed(buffer, by: pauses.totalPaused) ?? buffer)
            try sink.append(toAppend, to: track)
        } catch {
            // Dropping a buffer must never tear down the stream; a partial
            // recording beats no recording (spec section 11).
        }
    }

    /// True when a screen sample buffer represents a newly rendered frame.
    ///
    /// A buffer whose status is anything other than `.complete` carries no new
    /// surface content. Buffers with no attachment at all are treated as
    /// complete, because that is how synthetic buffers in tests arrive.
    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                buffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let rawStatus = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else {
            return true
        }
        return status == .complete
    }
}
