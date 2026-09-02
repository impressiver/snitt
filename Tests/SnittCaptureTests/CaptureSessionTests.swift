import Testing
import Foundation
import CoreMedia
import ScreenCaptureKit
@testable import SnittCapture

/// Records what the session routed, so the pipeline can be tested with no screen.
final class SpySink: SampleBufferSink, @unchecked Sendable {
    var begun = false
    var appended: [(TrackKind, Double)] = []
    var finishedURL = URL(fileURLWithPath: "/tmp/spy.mov")
    private let lock = NSLock()

    func begin(at startTime: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        begun = true
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
}
