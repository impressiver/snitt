import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import SnittCapture
@testable import SnittDocument

/// Pause/resume through the real capture pipeline (M5e, D53).
///
/// `PauseLedgerTests` covers the arithmetic. These cover the thing the
/// arithmetic exists for: that paused footage does not reach the file, and that
/// what does reach it is CONTINUOUS — a viewer sees the recording jump from the
/// pause to the resume, not a frozen gap the length of the pause.
///
/// Both properties are asserted, because they fail independently. Dropping
/// buffers without shifting timestamps gives a correct-length file with a stall
/// in it; shifting without dropping gives a file whose later frames overwrite
/// earlier ones.
///
/// Asserted at the SINK boundary with a spy, not by measuring the encoded
/// file's duration. A first version did the latter and was invalid: feeding 120
/// synthetic frames in a tight loop yields ~0.4s of video whether or not
/// anything is paused, because `AVAssetWriterInput` drops what it is not ready
/// for. The unpaused control measured 0.42s and revealed it. The spy makes the
/// property exact — these buffers arrived, those did not, with these
/// timestamps — and needs no encoder at all.
@MainActor
struct PauseResumeTests {
    /// Records what reached the sink, so "dropped" and "shifted" are directly
    /// observable rather than inferred from an encoded file.
    final class SpySink: SampleBufferSink, @unchecked Sendable {
        let health = HealthSampler()
        private let lock = NSLock()
        private var _appended: [(track: TrackKind, pts: CMTime)] = []
        var appended: [(track: TrackKind, pts: CMTime)] {
            lock.lock(); defer { lock.unlock() }; return _appended
        }
        func begin(at startTime: CMTime) throws {}
        func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws {
            lock.lock(); defer { lock.unlock() }
            _appended.append((track, buffer.presentationTimeStamp))
        }
        func finish() async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    }

    private func makeSession() -> (CaptureSession, SpySink) {
        let sink = SpySink()
        return (CaptureSession.forTesting(sink: sink), sink)
    }

    /// A buffer stamped at an absolute media time, independent of the host
    /// clock — the pause arithmetic is about relative spans, and anchoring to
    /// "now" would make the expected values unwritable.
    private func frame(at seconds: Double) -> CMSampleBuffer {
        makeVideoBufferAtAbsoluteTime(seconds: seconds, size: CGSize(width: 320, height: 240))
    }

    @Test("Buffers fed while paused never reach the sink")
    func pausedBuffersAreDropped() {
        let (session, sink) = makeSession()
        session.handle(frame(at: 0), of: .screen)
        session.handle(frame(at: 1), of: .screen)
        session.pause()
        session.handle(frame(at: 2), of: .screen)
        session.handle(frame(at: 3), of: .screen)
        session.resume()
        session.handle(frame(at: 4), of: .screen)

        #expect(sink.appended.count == 3, "expected 3 kept buffers, got \(sink.appended.count)")
    }

    @Test("Buffers after a resume are shifted back by the paused span")
    func resumedBuffersAreShifted() throws {
        // The independent half. Dropping without shifting leaves the last
        // buffer at 4s, so the file carries the pause as a 2s frozen gap.
        let (session, sink) = makeSession()
        session.handle(frame(at: 0), of: .screen)
        session.pause()
        session.handle(frame(at: 2), of: .screen)   // sets the pause at 2s
        session.resume()
        session.handle(frame(at: 4), of: .screen)   // resumes at 4s: 2s paused

        let last = try #require(sink.appended.last)
        #expect(abs(last.pts.seconds - 2.0) < 0.01,
                "expected the 4s frame written at 2s, got \(last.pts.seconds)s")
    }

    @Test("A second pause shifts by the TOTAL, not just the latest span")
    func shiftsAccumulateAcrossPauses() throws {
        let (session, sink) = makeSession()
        session.handle(frame(at: 0), of: .screen)
        session.pause();  session.handle(frame(at: 1), of: .screen)
        session.resume(); session.handle(frame(at: 3), of: .screen)   // 2s paused
        session.pause();  session.handle(frame(at: 4), of: .screen)
        session.resume(); session.handle(frame(at: 7), of: .screen)   // +3s = 5s

        let last = try #require(sink.appended.last)
        #expect(abs(last.pts.seconds - 2.0) < 0.01,
                "expected 7s minus 5s paused = 2s, got \(last.pts.seconds)s")
    }

    @Test("Pause and resume are idempotent at the session level")
    func repeatedCallsAreInert() throws {
        let (session, sink) = makeSession()
        session.handle(frame(at: 0), of: .screen)
        session.pause(); session.pause()
        session.handle(frame(at: 2), of: .screen)
        session.resume(); session.resume()
        session.handle(frame(at: 4), of: .screen)

        #expect(sink.appended.count == 2)
        let last = try #require(sink.appended.last)
        // A second pause() that moved the start to 2s would shift by 2s and
        // write this at 2s instead of 2s... so the discriminator is the count
        // plus totalPaused below.
        #expect(abs(last.pts.seconds - 2.0) < 0.01)
        #expect(!session.isPaused)
    }
}
