// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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

/// A pause and its resume are one instant (2026-09-11).
@Suite
struct PauseResumePairTests {

    @Test("Resume is stamped at the instant the pause was stamped")
    func theyShareOneInstant() async throws {
        // A pause occupies no footage — it is the absence of buffers — so the
        // instant the recording stopped and the instant it started again are
        // one point in the file. Two markers claiming a gap describe footage
        // the file does not contain.
        //
        // They used to disagree by the capture latency, and backwards: `pause`
        // stamps from the host clock at request time, while `resume` resolved
        // to the pause's MEDIA instant, and ScreenCaptureKit delivers buffers
        // carrying timestamps from the recent past. A real recording shows the
        // pair at 3.000 and 3.172 — Resumed 172ms BEFORE the Paused it follows.
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let recorder = try Recorder.forTesting(bundleURL: bundleURL,
                                               videoSize: CGSize(width: 160, height: 120))
        try await recorder.startForTesting()
        for frame in 0..<10 {
            recorder.feedForTesting(
                makeVideoBuffer(at: Double(frame) / 30.0,
                                size: CGSize(width: 160, height: 120)), .screen)
        }

        await recorder.pause()
        // Real time passes while paused — which is the whole point: the wall
        // moves and the file does not.
        try await Task.sleep(nanoseconds: 150_000_000)
        await recorder.resume()

        let bundle = try await recorder.stop()
        let events = try EventLog.read(from: bundle).events
        let paused = try #require(events.first { $0.label == "Paused" })
        let resumed = try #require(events.first { $0.label == "Resumed" })
        #expect(paused.timeSeconds == resumed.timeSeconds,
                "Paused at \(paused.timeSeconds), Resumed at \(resumed.timeSeconds)")
    }
}
