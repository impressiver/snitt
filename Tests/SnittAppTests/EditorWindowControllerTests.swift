import AppKit
import AVFoundation
import Foundation
import SnittApp
import SnittDocument
import SnittExport
import Testing

/// Builds a `PreviewController` over a tiny synthetic movie, for tests that
/// only need SOME playable composition — the activation-policy and
/// open-count behaviour under test here does not depend on the fixture's
/// content, only on there being a real `AVPlayer` to pause and query.
@MainActor
private func makePreviewController(seconds: Double) async throws -> PreviewController {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    return PreviewController(built: built, jumpPoints: [])
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
@Suite(.serialized)
@MainActor
struct EditorWindowControllerTests {
    init() {
        _ = NSApplication.shared
    }

    @Test("Opening an editor promotes the app so its window can take focus")
    func openingPromotesActivationPolicy() async throws {
        NSApp.setActivationPolicy(.accessory)
        let controller = try await makePreviewController(seconds: 2)
        let editor = EditorWindowController(controller: controller, title: "demo")

        editor.show()

        // An .accessory app's windows cannot become key: the editor would open
        // unfocused, behind other apps, and ignore the keyboard. This is the
        // assertion that fails against an implementation that just orders the
        // window front.
        #expect(NSApp.activationPolicy() == .regular)
        editor.close()
    }

    @Test("Closing the last editor returns the app to the menu bar")
    func closingLastEditorDemotes() async throws {
        NSApp.setActivationPolicy(.accessory)
        let editor = EditorWindowController(
            controller: try await makePreviewController(seconds: 2), title: "demo")
        editor.show()
        editor.close()
        // Leaving the app .regular would strand a Dock icon for a menu-bar app
        // with no windows.
        #expect(NSApp.activationPolicy() == .accessory)
    }

    @Test("Closing one of two editors keeps the app promoted")
    func closingOneOfTwoKeepsPromotion() async throws {
        NSApp.setActivationPolicy(.accessory)
        let first = EditorWindowController(
            controller: try await makePreviewController(seconds: 2), title: "a")
        let second = EditorWindowController(
            controller: try await makePreviewController(seconds: 2), title: "b")
        first.show(); second.show()

        first.close()

        // Discriminating against a policy tied to a single window's lifetime
        // rather than to the open count — that implementation passes both tests
        // above and demotes the app while a window is still on screen.
        #expect(NSApp.activationPolicy() == .regular)
        #expect(EditorWindowController.openWindowCount == 1)
        second.close()
        #expect(NSApp.activationPolicy() == .accessory)
    }

    @Test("Pausing on close stops playback rather than leaving audio running")
    func closingPausesPlayback() async throws {
        let controller = try await makePreviewController(seconds: 3)
        let editor = EditorWindowController(controller: controller, title: "demo")
        editor.show()
        controller.play()

        editor.close()

        // A closed window whose player keeps playing leaves audio coming from a
        // window the user cannot see.
        #expect(controller.player.rate == 0)
    }

    @Test("Closing by the window's own close button tears down like close() does")
    func closeButtonPathTearsDown() async throws {
        // The path a real user actually takes. `close()` is the programmatic
        // door; clicking the window's close button arrives through
        // `windowWillClose(_:)` instead, and if that path skips teardown the
        // app strands a Dock icon with no windows and keeps playing audio the
        // user cannot see.
        //
        // Task 4's report said this needed a live window server. It does not:
        // `windowWillClose(_:)` is public and `teardown()` is idempotent, so
        // the delegate callback can be invoked directly with a synthetic
        // notification.
        let controller = try await makePreviewController(seconds: 3)
        let editor = EditorWindowController(controller: controller, title: "demo")
        editor.show()
        controller.play()
        #expect(NSApp.activationPolicy() == .regular)

        editor.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        #expect(EditorWindowController.openWindowCount == 0)
        #expect(NSApp.activationPolicy() == .accessory)
        #expect(controller.player.rate == 0)
    }
}
