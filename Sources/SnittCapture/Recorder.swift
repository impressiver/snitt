import Foundation
import CoreMedia
import ScreenCaptureKit
import SnittDocument

public enum RecorderError: Error, Equatable {
    /// `stop()` was called before `start()`.
    case notStarted
    /// `stop()` was called a second time after finalization already ran.
    case alreadyFinished
}

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
    private var isFinished = false
    private let markers = MarkerLog()

    /// - Parameter initiator: Deliberately has NO default. A default of
    ///   `.human` is what let every agent recording ship mislabelled: the
    ///   argument was simply never passed, and nothing failed. Provenance is
    ///   the one metadata field whose whole purpose is telling the two apart,
    ///   so an omission must be a compile error rather than a silent lie.
    public init(target: ResolvedTarget,
                bundleURL: URL,
                options: CaptureOptions = CaptureOptions(),
                initiator: Initiator) throws {
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

    /// Stops capture, finalizes the movie, and completes the bundle.
    ///
    /// Sidecar files are written even when finalization fails, so the bundle on
    /// disk stays well-formed and recoverable — but the failure is then
    /// rethrown, because a caller must never be handed a bundle that looks
    /// complete while `capture.mov` is truncated or unplayable.
    public func stop() async throws -> SnittBundle {
        guard startedAt != nil else { throw RecorderError.notStarted }
        guard !isFinished else { throw RecorderError.alreadyFinished }

        let stoppedAt = Date()
        isFinished = true

        // Swallowed deliberately: on the testing path there is no live stream,
        // and a stream-stop failure does not corrupt the written movie.
        try? await session.stop()

        var finishError: Error?
        do {
            _ = try await sink.finish()
        } catch {
            finishError = error
        }

        let collectedMarkers = await markers.snapshot()
        try writeSidecars(stoppedAt: stoppedAt, collectedMarkers: collectedMarkers)

        if let finishError { throw finishError }
        return bundle
    }

    /// Records a marker at the current offset into the recording.
    ///
    /// Returns the offset so the caller can report it — an agent that just
    /// marked "ran the tests" wants to know where that landed.
    public func mark(label: String?) -> Double {
        let offset = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        Task { await markers.add(at: offset, label: label) }
        return offset
    }

    private func writeSidecars(stoppedAt: Date, collectedMarkers: [LoggedEvent]) throws {
        let duration = startedAt.map { stoppedAt.timeIntervalSince($0) }
        let metadata = RecordingMetadata(
            createdAt: startedAt ?? Date(),
            initiator: initiator,
            durationSeconds: duration,
            git: nil,      // populated in M2
            health: nil    // populated in M2
        )
        try metadata.write(to: bundle)
        try EventLog(events: collectedMarkers).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
    }

    // MARK: - Testing seam

    static func forTesting(bundleURL: URL, videoSize: CGSize,
                           initiator: Initiator = .human) throws -> Recorder {
        let bundle = try SnittBundle(creatingAt: bundleURL)
        let sink = try AssetWriterSink(outputURL: bundle.captureURL,
                                       videoSize: videoSize)
        let session = CaptureSession.forTesting(sink: sink)
        return Recorder(bundle: bundle, sink: sink,
                        session: session, initiator: initiator)
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
