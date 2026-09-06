import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import SnittCapture
@testable import SnittApp
import SnittDocument
import SnittExport
import Testing

/// Builds a `PreviewController` over a tiny synthetic movie, for tests that
/// only need SOME playable composition — the open-count behaviour under
/// test here does not depend on the fixture's content, only on there being
/// a real `AVPlayer` to pause and query.
@MainActor
private func makePreviewController(seconds: Double) async throws -> PreviewController {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    return PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
}

/// A minimal, real one-frame-at-a-time video buffer — just enough for
/// `AssetWriterSink` (inside `Recorder`) to `begin()`/`finish()` successfully
/// and produce a genuinely valid, loadable `capture.mov`.
///
/// Duplicated from `Tests/SnittCaptureTests/SyntheticBuffers.swift` rather
/// than shared — see `writeSyntheticMovie`'s own doc comment above for why:
/// Swift Testing target sources do not share helpers across files, let alone
/// across test targets. Trimmed to video only and not host-clock anchored,
/// since nothing here reads a media offset — only whether the movie as a
/// whole builds and plays.
private func makeEditorTestVideoBuffer(atFrame frame: Int, size: CGSize) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                        kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    let buffer = pixelBuffer!

    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescriptionOut: &formatDescription)

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 30),
        decodeTimeStamp: .invalid)

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil,
        formatDescription: formatDescription!, sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer)
    return sampleBuffer!
}

@MainActor
private func makeEditorTestCoordinator() -> RecordingCoordinator {
    let store = TargetStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    return RecordingCoordinator(
        // `MarkerResolver` (from `RecordingCoordinatorTests.swift`, same
        // target): always throws. These tests never reach `resolve()` at
        // all — the active recording is wired in directly — but every
        // fixture that constructs a `RecordingCoordinator` in this target
        // supplies real resolvers rather than leaving them nil-shaped.
        pickerResolver: MarkerResolver(),
        cachedResolverFactory: { _ in MarkerResolver() },
        store: store,
        outputDirectory: FileManager.default.temporaryDirectory,
        ensureAccess: { true })
}

/// Wires a real, finalized `Recorder`-produced bundle into `coordinator` as
/// its active recording, then runs the exact stop path production code
/// runs (`RecordingCoordinator.stopForTesting()`), and returns the bundle it
/// produced.
///
/// `Recorder`'s own testing seam (`forTesting` / `startForTesting` /
/// `feedForTesting`) is internal to `SnittCapture` and reachable only via
/// `@testable import` from a test target — `RecordingCoordinator`'s own
/// production code cannot see it (a plain `import SnittCapture`). That is
/// why `stopForTesting()` on the coordinator takes no `initiator:` parameter
/// the way Task 5's brief sketches it: the initiator has to be baked into
/// the `Recorder` at construction, here, in the one place that CAN reach the
/// seam. This is arguably more faithful anyway — `Recorder.init(initiator:)`
/// has no default for exactly this reason: nothing ever re-stamps a
/// recording's initiator after it starts.
@MainActor
private func stopEditorTestCoordinator(_ coordinator: RecordingCoordinator,
                                       initiator: Initiator,
                                       corruptCapture: Bool = false) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let size = CGSize(width: 32, height: 32)
    let recorder = try Recorder.forTesting(bundleURL: url, videoSize: size,
                                           initiator: initiator)
    try await recorder.startForTesting()
    for frame in 0..<10 {
        recorder.feedForTesting(makeEditorTestVideoBuffer(atFrame: frame, size: size), .screen)
    }
    await coordinator.setActiveForTesting(recorder)
    if corruptCapture {
        await coordinator.corruptNextCaptureForTesting()
    }
    return try await coordinator.stopForTesting()
}

/// Grouped in a serialized suite for two reasons, not one:
///
/// 1. (Per dispatch) these tests mutate process-global `NSApp` activation
///    policy while swift-testing otherwise runs tests in parallel; letting
///    two of them race would make one observe the other's policy write.
/// 2. Bare `NSApp` (the C global, distinct from `NSApplication.shared`) is
///    an implicitly-unwrapped optional that AppKit only sets the first time
///    something touches `NSApplication.shared`. In a plain test bundle
///    nothing does that automatically, so the very first `NSApp.…` call —
///    in whichever of these tests happened to run first — force-unwrapped a
///    nil and crashed the whole run (signal 5, no summary line). The
///    suite's `init()` touches `NSApplication.shared` once, deterministically,
///    before any test body runs.
///
/// Task 5's editor-on-stop tests (`RecordingCoordinator.stopForTesting`)
/// live in THIS suite rather than in `RecordingCoordinatorTests.swift`, for
/// reason 1 above: they construct real editor windows through the stop path
/// and read `EditorWindowController`'s process-global `openWindowCount` —
/// exactly the state this suite already exists to serialize access to.
/// Swift Testing runs different suites concurrently by default, so a
/// second, independently-serialized suite touching the same global would
/// serialize against itself but still race against this one.
@Suite(.serialized)
@MainActor
struct EditorWindowControllerTests {
    init() {
        _ = NSApplication.shared
    }

    // Activation policy is no longer this controller's concern: the app is
    // permanently `.regular` (§4.14, D45; see `AppShell`), which is why the
    // promote/demote dance and its dedicated tests were deleted rather than
    // rewritten to assert "unchanged" — once `AppShellTests` has run
    // `AppShell.install` in this same process, macOS does not reliably allow
    // reverting a regular app back to `.accessory`, which would make an
    // "activation policy is untouched" assertion here flaky for reasons
    // having nothing to do with this controller. Coverage that the app IS
    // regular lives in `AppShellTests`. What's left here is the open-count
    // bookkeeping, which never depended on activation policy in the first
    // place.

    @Test("Closing one of two editors keeps the other open")
    func closingOneOfTwoKeepsTheOtherOpen() async throws {
        // `EditorWindowTestGate` (Task 7): this suite's `.serialized`
        // trait only serializes its OWN tests. `DocumentOpenerTests` and
        // `EditorPersistenceTests` are separately-serialized suites that
        // run concurrently with this one and also open real windows
        // against this same process-global counter — without the gate, one
        // of their windows can appear or disappear between this test's
        // `before` snapshot and its assertions.
        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            let first = EditorWindowController(
                controller: try await makePreviewController(seconds: 2), title: "a",
                bundleURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("snitt"),
                edl: .fullRange(), events: [])
            let second = EditorWindowController(
                controller: try await makePreviewController(seconds: 2), title: "b",
                bundleURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("snitt"),
                edl: .fullRange(), events: [])

            first.show(); second.show()
            #expect(EditorWindowController.openWindowCount == before + 2)

            first.close()
            // Discriminating against bookkeeping tied to a single window's
            // lifetime rather than to the open set — that implementation drops
            // the count to `before` here instead of `before + 1`.
            #expect(EditorWindowController.openWindowCount == before + 1)

            second.close()
            #expect(EditorWindowController.openWindowCount == before)
        }
    }

    @Test("Pausing on close stops playback rather than leaving audio running")
    func closingPausesPlayback() async throws {
        // Doesn't itself read `openWindowCount`, but still opens a real
        // window against the same process-global counter another
        // suite's gated before/after test could be mid-snapshot on — the
        // gate has to wrap every window-opening test here, not just the
        // ones that assert the count, or an ungated open here could still
        // perturb a gated assertion elsewhere.
        try await EditorWindowTestGate.run {
            let controller = try await makePreviewController(seconds: 3)
            let editor = EditorWindowController(controller: controller, title: "demo",
                                                  bundleURL: FileManager.default.temporaryDirectory
                                                      .appendingPathComponent(UUID().uuidString).appendingPathExtension("snitt"),
                                                  edl: .fullRange(), events: [])
            editor.show()
            controller.play()

            editor.close()

            // A closed window whose player keeps playing leaves audio coming from a
            // window the user cannot see.
            #expect(controller.player.rate == 0)
        }
    }

    @Test("Closing by the window's own close button tears down like close() does")
    func closeButtonPathTearsDown() async throws {
        // The path a real user actually takes. `close()` is the programmatic
        // door; clicking the window's close button arrives through
        // `windowWillClose(_:)` instead, and if that path skips teardown the
        // window's audio keeps playing with nothing on screen to show for it,
        // and `openWindowCount` stays inflated for the rest of the run.
        //
        // Task 4's report said this needed a live window server. It does not:
        // `windowWillClose(_:)` is public and `teardown()` is idempotent, so
        // the delegate callback can be invoked directly with a synthetic
        // notification.
        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            let controller = try await makePreviewController(seconds: 3)
            let editor = EditorWindowController(controller: controller, title: "demo",
                                                  bundleURL: FileManager.default.temporaryDirectory
                                                      .appendingPathComponent(UUID().uuidString).appendingPathExtension("snitt"),
                                                  edl: .fullRange(), events: [])
            editor.show()
            controller.play()

            editor.windowWillClose(Notification(name: NSWindow.willCloseNotification))

            // M4a review finding #3: this used to assert `== 0` outright, which
            // only held because this suite's serialized tests happened to run
            // in source order with every other test cleaning up after itself.
            // Reordering the file — or a future test leaking a window — breaks
            // an absolute assertion silently. Relative to a captured `before`
            // count, this only depends on THIS test's own open/close pair.
            #expect(EditorWindowController.openWindowCount == before)
            #expect(controller.player.rate == 0)
        }
    }

    // MARK: - Task 5: stopping opens the editor

    @Test("Stopping a human recording opens an editor")
    func humanStopOpensEditor() async throws {
        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            let coordinator = makeEditorTestCoordinator()
            let bundle = try await stopEditorTestCoordinator(coordinator, initiator: .human)
            _ = bundle
            #expect(EditorWindowController.openWindowCount == before + 1)
            // M4a review finding #3: this test never closed the editor it just
            // opened, leaking a real window (and a bumped `openWindowCount`) for
            // the rest of the run. The suite absorbed it because every other
            // test's assertions are relative to a captured `before` count —
            // except `closeButtonPathTearsDown`'s absolute `openWindowCount ==
            // 0`, which only survived by accident of source order (this test
            // used to run after it). `RecordingCoordinator.openEditor` builds
            // the `EditorWindowController` internally and never hands it back,
            // so `closeAllForTesting()` is the only way to tear it down here.
            EditorWindowController.closeAllForTesting()
            #expect(EditorWindowController.openWindowCount == before)
        }
    }

    @Test("Stopping an agent recording does NOT open a window")
    func agentStopOpensNothing() async throws {
        // §5.3: agent recordings happen with no human present. A window
        // appearing on someone's screen because a background agent finished
        // is the surprise the consent rules exist to prevent.
        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            let coordinator = makeEditorTestCoordinator()
            _ = try await stopEditorTestCoordinator(coordinator, initiator: .agent)
            #expect(EditorWindowController.openWindowCount == before)
        }
    }

    @Test("A bundle the builder cannot open still finalises the recording")
    func unbuildableBundleStillStops() async throws {
        // The recording is on disk and safe before the editor is even
        // considered. Losing it because a preview could not be built would
        // trade the valuable thing for the convenient one.
        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            let coordinator = makeEditorTestCoordinator()
            let bundle = try await stopEditorTestCoordinator(coordinator, initiator: .human,
                                                             corruptCapture: true)
            #expect(FileManager.default.fileExists(atPath: bundle.url.path))
            #expect(EditorWindowController.openWindowCount == before)
        }
    }
}
