import Testing
import Foundation
import CoreMedia
import ScreenCaptureKit
@testable import SnittCapture

/// Records what the session routed, so the pipeline can be tested with no screen.
final class SpySink: SampleBufferSink, @unchecked Sendable {
    var begun = false
    var beginCount = 0
    var appended: [(TrackKind, Double)] = []
    var finishedURL = URL(fileURLWithPath: "/tmp/spy.mov")
    let health = HealthSampler()
    private let lock = NSLock()

    func begin(at startTime: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        begun = true
        beginCount += 1
    }

    func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws {
        lock.lock(); defer { lock.unlock() }
        appended.append((track, buffer.presentationTimeStamp.seconds))
    }

    func finish() async throws -> URL { finishedURL }
}

@Test("Routes each output type to its matching track")
func routesBuffersToTracks() throws {
    let sink = SpySink()
    let session = CaptureSession.forTesting(sink: sink)
    let size = CGSize(width: 320, height: 240)

    session.handle(makeVideoBuffer(at: 0.0, size: size), of: .screen)
    session.handle(makeAudioBuffer(at: 0.1), of: .audio)
    session.handle(makeAudioBuffer(at: 0.2), of: .microphone)

    #expect(sink.appended.count == 3)
    #expect(sink.appended.map(\.0) == [.video, .systemAudio, .microphone])
}

@Test("Buffers without ScreenCaptureKit frame attachments are treated as complete")
func synthesizedBuffersAreNotFilteredOut() throws {
    let sink = SpySink()
    let session = CaptureSession.forTesting(sink: sink)
    let size = CGSize(width: 320, height: 240)

    session.handle(makeVideoBuffer(at: 0.0, size: size), of: .screen)

    #expect(sink.appended.count == 1,
            "a synthetic buffer carries no frame info and must not be dropped")
}

@Test("Begins the sink on the first buffer, not before")
func beginsLazilyOnFirstBuffer() throws {
    let sink = SpySink()
    let session = CaptureSession.forTesting(sink: sink)

    #expect(sink.begun == false, "no session before any media arrives")

    session.handle(makeVideoBuffer(at: 5.0, size: CGSize(width: 320, height: 240)),
                   of: .screen)
    #expect(sink.begun == true)
}

@Test("Begins only once across many buffers")
func beginsExactlyOnce() throws {
    let sink = SpySink()
    let session = CaptureSession.forTesting(sink: sink)
    let size = CGSize(width: 320, height: 240)

    for frame in 0..<10 {
        session.handle(makeVideoBuffer(at: Double(frame) / 60.0, size: size),
                       of: .screen)
    }
    #expect(sink.appended.count == 10)
    #expect(sink.begun == true)
    #expect(sink.beginCount == 1)
}

@Test("A media offset is measured from the video's first frame, not from wall clock")
func mediaOffsetIsRelativeToFirstFrame() {
    // A marker's offset must land in the same time base as the video track, or
    // it points a reviewer at the wrong moment (§4.12).
    let first = CMTime(seconds: 1000.0, preferredTimescale: 600)
    let now = CMTime(seconds: 1012.5, preferredTimescale: 600)
    #expect(abs((CaptureSession.mediaOffset(from: first, to: now) ?? -1) - 12.5) < 0.001)
}

@Test("A marker before the first frame has no media offset")
func noOffsetBeforeFirstFrame() {
    #expect(CaptureSession.mediaOffset(from: nil, to: CMTime(seconds: 5, preferredTimescale: 600)) == nil)
}

@Test("An implausible media offset falls back to wall clock")
func implausibleMediaOffsetFallsBack() {
    // The 1.6-million-second case: a media clock that is not the host clock.
    #expect(CaptureSession.plausibleOffset(media: 1_644_292, wallClock: 3.0) == 3.0)
}

@Test("A plausible media offset is preferred over wall clock")
func plausibleMediaOffsetWins() {
    // The whole point of the media clock: it is the accurate one, differing
    // from wall clock by the stream's startup latency.
    #expect(CaptureSession.plausibleOffset(media: 3.3, wallClock: 3.0) == 3.3)
}

@Test("With no media clock yet, wall clock is used")
func noMediaClockUsesWallClock() {
    #expect(CaptureSession.plausibleOffset(media: nil, wallClock: 2.0) == 2.0)
}
