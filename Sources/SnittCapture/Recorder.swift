import Foundation
import CoreMedia
import ScreenCaptureKit
import SnittDocument

/// Drives a capture into a complete `.snitt` bundle.
///
/// On stop, writes the sidecar files so the bundle is valid the moment
/// recording ends — no separate "save" step exists (spec section 7).
public actor Recorder {
    private let bundle: SnittBundle
    private let session: CaptureSession
    private let sink: AssetWriterSink
    private let initiator: Initiator

    private var startedAt: Date?

    public init(target: CaptureTarget,
                bundleURL: URL,
                options: CaptureOptions = CaptureOptions(),
                initiator: Initiator = .human) throws {
        let bundle = try SnittBundle(creatingAt: bundleURL)
        let descriptor = target.descriptor
        let sink = try AssetWriterSink(
            outputURL: bundle.captureURL,
            videoSize: CGSize(width: descriptor.width, height: descriptor.height)
        )
        self.bundle = bundle
        self.sink = sink
        self.initiator = initiator
        self.session = CaptureSession(target: target, sink: sink, options: options)
    }

    private init(bundle: SnittBundle,
                 sink: AssetWriterSink,
                 session: CaptureSession,
                 initiator: Initiator) {
        self.bundle = bundle
        self.sink = sink
        self.session = session
        self.initiator = initiator
    }

    public func start() async throws {
        startedAt = Date()
        try await session.start()
    }

    public func stop() async throws -> SnittBundle {
        // No-op when there is no live stream, which is the testing path.
        try? await session.stop()
        _ = try? await sink.finish()
        try writeSidecars()
        return bundle
    }

    private func writeSidecars() throws {
        let duration = startedAt.map { Date().timeIntervalSince($0) }
        let metadata = RecordingMetadata(
            createdAt: startedAt ?? Date(),
            initiator: initiator,
            durationSeconds: duration,
            git: nil,      // populated in M2
            health: nil    // populated in M2
        )
        try metadata.write(to: bundle)
        try EventLog().write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
    }

    // MARK: - Testing seam

    static func forTesting(bundleURL: URL, videoSize: CGSize) throws -> Recorder {
        let bundle = try SnittBundle(creatingAt: bundleURL)
        let sink = try AssetWriterSink(outputURL: bundle.captureURL,
                                       videoSize: videoSize)
        let session = CaptureSession.forTesting(sink: sink)
        return Recorder(bundle: bundle, sink: sink,
                        session: session, initiator: .human)
    }

    func startForTesting() async throws {
        startedAt = Date()
    }

    /// Feeds a synthetic buffer straight to the session, bypassing SCStream.
    ///
    /// Declared `nonisolated` (and thus callable without `await`) because
    /// `CMSampleBuffer` is not `Sendable`: routing it across the actor
    /// boundary through an isolated method would be a Swift 6 concurrency
    /// error. This is safe because it only touches `session`, an immutable
    /// `let`, so no actor-isolated state is involved.
    nonisolated func feedForTesting(_ buffer: CMSampleBuffer, _ type: SCStreamOutputType) {
        session.handle(buffer, of: type)
    }
}
