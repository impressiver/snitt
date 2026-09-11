// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AVFoundation
@testable import SnittCapture
@testable import SnittDocument

@Test("A finished recording produces a complete bundle")
func producesCompleteBundle() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let recorder = try Recorder.forTesting(bundleURL: bundleURL,
                                           videoSize: CGSize(width: 320, height: 240))
    try await recorder.startForTesting()

    let size = CGSize(width: 320, height: 240)
    for frame in 0..<30 {
        let t = Double(frame) / 30.0
        recorder.feedForTesting(makeVideoBuffer(at: t, size: size), .screen)
        recorder.feedForTesting(makeAudioBuffer(at: t), .audio)
    }

    let bundle = try await recorder.stop()
    let fm = FileManager.default

    #expect(fm.fileExists(atPath: bundle.captureURL.path))
    #expect(fm.fileExists(atPath: bundle.metaURL.path))
    #expect(fm.fileExists(atPath: bundle.eventsURL.path))
    #expect(fm.fileExists(atPath: bundle.editURL.path))

    let meta = try RecordingMetadata.read(from: bundle)
    #expect(meta.schemaVersion == 1)
    #expect(meta.initiator == .human)
    #expect((meta.durationSeconds ?? 0) > 0)

    let edit = try EditDecisionList.read(from: bundle)
    #expect(edit.cuts.isEmpty)
    #expect(edit.trackStates.count == 3)

    let events = try EventLog.read(from: bundle)
    #expect(events.events.isEmpty, "M1 records no events; that is M3")
}

@Test("capture.mov is a real movie with a video track")
func captureIsPlayable() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    for frame in 0..<30 {
        recorder.feedForTesting(
            makeVideoBuffer(at: Double(frame) / 30.0, size: size), .screen
        )
    }
    let bundle = try await recorder.stop()

    let asset = AVURLAsset(url: bundle.captureURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == 1)
}

@Test("Stopping without starting throws rather than writing a phantom bundle")
func stopWithoutStartThrows() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let recorder = try Recorder.forTesting(bundleURL: bundleURL,
                                           videoSize: CGSize(width: 320, height: 240))
    await #expect(throws: RecorderError.notStarted) {
        _ = try await recorder.stop()
    }
}

@Test("A failure to finalize the movie surfaces instead of being swallowed")
func finalizationFailureSurfaces() async throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    for frame in 0..<10 {
        recorder.feedForTesting(makeVideoBuffer(at: Double(frame) / 30.0, size: size),
                                .screen)
    }
    _ = try await recorder.stop()

    // The sink is already finished; a second stop must surface the
    // alreadyFinished guard rather than returning a bundle as though nothing
    // went wrong.
    await #expect(throws: RecorderError.alreadyFinished) {
        _ = try await recorder.stop()
    }
}

@Test("An agent-initiated recording is stamped as such in metadata.json")
func agentProvenanceReachesTheBundle() async throws {
    // Closes finding 6 one layer deeper than `initiator(isAgent:)` can. Every
    // recording shipped as `.human` because `Recorder.init` defaulted to it, so
    // `.agent` had zero references outside its own declaration — including in
    // any bundle Snitt had ever written.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size,
                                           initiator: .agent)
    try await recorder.startForTesting()
    for frame in 0..<5 {
        recorder.feedForTesting(
            makeVideoBuffer(at: Double(frame) / 30.0, size: size), .screen)
    }
    let bundle = try await recorder.stop()

    #expect(try RecordingMetadata.read(from: bundle).initiator == .agent,
            "provenance is the one field whose whole purpose is telling the two apart")
}

@Test("A marker added immediately before stop is in the written bundle")
func markJustBeforeStopSurvives() async throws {
    // The common agent sequence is `record mark` then `record stop`, and this
    // pins that path end to end.
    //
    // It does NOT discriminate the fire-and-forget version this replaced:
    // restoring `Task { await markers.add(...) }` and running this 110 times,
    // including a 20-way concurrent variant, produced no failures. A
    // non-detached Task created inside an actor-isolated method inherits that
    // actor's context, so the write was enqueued ahead of the later stop(),
    // and both operations then serialised on SessionEventLog's executor (then
    // named MarkerLog) in enqueue order. Neither is guaranteed — actors are
    // reentrant and their executors are not specified FIFO — so the old code
    // worked by scheduler behaviour, not by construction. The ordering
    // guarantee now lives in `mark` being awaited; this test guards the
    // end-to-end path, not that guarantee.
    //
    // The same shape reappeared in M3b's input-event callback, which is
    // nonisolated and so CANNOT await. It is closed differently: the timestamp
    // is captured in the tap callback rather than inside the Task, and
    // `writeSidecars` sorts, so arrival order stops mattering. See
    // `eventsAreWrittenInTimeOrder`.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    recorder.feedForTesting(makeVideoBuffer(at: 0, size: size), .screen)

    let offset = await recorder.mark(label: "last thing")
    #expect(offset >= 0 && offset < 60,
            "a marker offset must be seconds into the recording, not seconds since boot")
    let bundle = try await recorder.stop()

    let events = try EventLog.read(from: bundle).events
    #expect(events.contains { $0.label == "last thing" && $0.kind == .marker })
}

@Test("A monitor is created only when input logging is asked for")
func monitorOnlyWhenAsked() async throws {
    // Nothing exercised logInputEvents == true through Recorder at all before
    // this: the testing initialiser hardcoded it to false, so the whole feature
    // was structurally excluded from the suite.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let off = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size,
                                      logInputEvents: false,
                                      isInputMonitoringGranted: { true })
    await off.installInputMonitorIfEnabled()
    #expect(await off.inputEvents == nil,
            "a recording that did not ask for input logging must install no tap")
}

@Test("Input logging without the grant installs nothing rather than prompting")
func noMonitorWithoutTheGrant() async throws {
    // Reaching CGEvent.tapCreate without the grant is what makes macOS raise
    // its TCC dialog — on screen, in frame, mid-recording, with no pre-explain
    // (§4.10), and on the agent path with nobody there to dismiss it. The
    // preflight gate is what stops that.
    //
    // The grant is INJECTED rather than read from the machine: TCC state is
    // per-machine, and a test guarded on the real grant would quietly do
    // nothing on a developer machine that has granted the test runner — which
    // is exactly where this path was verified by hand.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let recorder = try Recorder.forTesting(
        bundleURL: bundleURL, videoSize: CGSize(width: 320, height: 240),
        logInputEvents: true, isInputMonitoringGranted: { false })
    await recorder.installInputMonitorIfEnabled()
    #expect(await recorder.inputEvents == nil,
            "no grant means no tap — and so no unannounced TCC dialog mid-recording")
}

@Test("stop() tears the monitor down before the steps that can throw")
func stopReleasesMonitorEvenWhenFinalizationThrows() async throws {
    // The tap holds a +1 on the monitor and its callback runs on another
    // thread; a stop() that threw before uninstalling it would leave a live tap
    // pointing at an object about to be released. So teardown must happen on
    // EVERY path out of stop(), including the failing one.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let recorder = try Recorder.forTesting(
        bundleURL: bundleURL, videoSize: CGSize(width: 320, height: 240),
        logInputEvents: true)
    try await recorder.startForTesting()

    weak var weakMonitor: InputEventMonitor?
    do {
        let monitor = InputEventMonitor { _, _ in }
        weakMonitor = monitor
        await recorder.injectMonitorForTesting(monitor)
    }
    #expect(weakMonitor != nil, "the recorder holds it")

    // No buffer was ever fed, so the sink was never started and finish()
    // throws — the failing finalization path.
    await #expect(throws: (any Error).self) { _ = try await recorder.stop() }

    #expect(await recorder.inputEvents == nil)
    #expect(weakMonitor == nil, "a throwing stop() must still release the monitor")
}

@Test("events.json is written in time order even when events arrive out of order")
func eventsAreWrittenInTimeOrder() async throws {
    // Input events are appended from unstructured Tasks whose completion order
    // is NOT the order the keys were pressed in — the timestamp is now captured
    // in the tap callback, so a late-arriving early event is normal rather than
    // impossible. Every consumer (chapters, --auto-trim) reads events.json as a
    // timeline, so the file must be monotonic regardless of arrival order.
    // Markers and input events share the log, so the combined array is sorted.
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let size = CGSize(width: 320, height: 240)
    let recorder = try Recorder.forTesting(bundleURL: bundleURL, videoSize: size)
    try await recorder.startForTesting()
    for frame in 0..<5 {
        recorder.feedForTesting(
            makeVideoBuffer(at: Double(frame) / 30.0, size: size), .screen)
    }

    await recorder.recordInputEventForTesting(.keystroke, at: 3.0)
    await recorder.recordInputEventForTesting(.click, at: 1.0)
    await recorder.recordInputEventForTesting(.keystroke, at: 2.0)

    let bundle = try await recorder.stop()
    let times = try EventLog.read(from: bundle).events.map(\.timeSeconds)
    #expect(times == [1.0, 2.0, 3.0], "written order must be time order")
    #expect(times == times.sorted(), "events.json must be monotonic")
}
