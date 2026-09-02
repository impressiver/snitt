import Foundation
import ScreenCaptureKit
import CoreMedia

public struct CaptureOptions: Sendable {
    public var captureMicrophone: Bool
    public var captureSystemAudio: Bool
    public var maxDuration: Duration?

    public init(captureMicrophone: Bool = false,
                captureSystemAudio: Bool = true,
                maxDuration: Duration? = nil) {
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
        self.maxDuration = maxDuration
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
    private let target: CaptureTarget?
    private let sink: SampleBufferSink
    private let options: CaptureOptions

    private var stream: SCStream?
    private let lock = NSLock()
    private var didBegin = false

    public init(target: CaptureTarget,
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

        let stream = SCStream(filter: target.contentFilter(),
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

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        handle(sampleBuffer, of: type)
    }

    /// Routes one buffer. Separated from the delegate method so tests can
    /// drive the pipeline without an SCStream (spec section 15).
    func handle(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let track = TrackKind(type) else { return }
        guard CMSampleBufferDataIsReady(buffer) else { return }

        lock.lock()
        let needsBegin = !didBegin
        if needsBegin { didBegin = true }
        lock.unlock()

        do {
            // The session starts at the first buffer's timestamp, so the
            // three tracks share one timeline from the same clock.
            if needsBegin {
                try sink.begin(at: buffer.presentationTimeStamp)
            }
            try sink.append(buffer, to: track)
        } catch {
            // Dropping a buffer must never tear down the stream; a partial
            // recording beats no recording (spec section 11).
        }
    }
}
