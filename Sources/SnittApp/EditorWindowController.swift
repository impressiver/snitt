import AppKit
import SnittDocument
import SwiftUI

/// SwiftUI shell around the `AVPlayerLayer` surface: play/pause controls and
/// a jump-point list. §4.7 puts the video surface in AppKit
/// (`PlayerLayerView`) while everything around it stays SwiftUI.
private struct EditorContentView: View {
    let controller: PreviewController

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: controller.player)
                .frame(minWidth: 480, minHeight: 270)
            HStack(spacing: 12) {
                Button("Play") { controller.play() }
                Button("Pause") { controller.pause() }
            }
            .padding(8)
            if !controller.jumpPoints.isEmpty {
                List(controller.jumpPoints, id: \.timeSeconds) { point in
                    Button(point.label) {
                        Task { await controller.jump(to: point) }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }
}

/// Hosts one editor's preview in its own `NSWindow`.
///
/// Snitt is an accessory (menu-bar-only) app (`main.swift` sets
/// `.accessory`), and an accessory app's windows cannot become key in the
/// normal way — an editor opened without addressing this appears unfocused,
/// sits behind other apps, and ignores the keyboard. This controller
/// promotes the app to `.regular` while at least one editor is open and
/// demotes it back to `.accessory` once the last one closes.
///
/// The policy is driven by `openWindowCount`, not by any single window's
/// lifetime — tying it to one window's `isOpen` flag demotes the app the
/// moment ANY editor closes, even while a second one is still on screen.
@MainActor
public final class EditorWindowController: NSObject, NSWindowDelegate {
    private let controller: PreviewController
    public let window: NSWindow
    private var isShown = false

    private static var count = 0
    public static var openWindowCount: Int { count }

    /// Retains every open editor for as long as its window is on screen.
    ///
    /// Without this, an editor's ONLY owner is whatever created it. The stop
    /// path that Task 5 adds constructs one and calls `show()` without
    /// holding on to it afterwards — every prior caller of this type was a
    /// test that kept its own `let editor = ...` alive for the whole test, so
    /// this gap never showed up before there was a caller that didn't. A
    /// dropped `EditorWindowController` deallocates: `NSWindow.delegate` is
    /// `weak`, so `windowWillClose` stops firing, and the window itself can
    /// vanish from under a user who is still watching it.
    private static var open: [EditorWindowController] = []

    public init(controller: PreviewController, title: String) {
        self.controller = controller
        let hosting = NSHostingView(rootView: EditorContentView(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.contentView = hosting
        // We hold `window` for the controller's lifetime (the `window`
        // property below), so the default release-on-close would fight that
        // ownership; keep the NSWindow alive until we drop our own reference.
        window.isReleasedWhenClosed = false
        self.window = window
        super.init()
        window.delegate = self
    }

    /// Brings the window to the front and, on the first open, promotes the
    /// app so the window can actually take focus and keystrokes.
    public func show() {
        if !isShown {
            isShown = true
            Self.count += 1
            Self.open.append(self)
            Self.applyActivationPolicy()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Stops playback and closes the window. Safe to call more than once,
    /// and safe even if the window was already closed via its own close
    /// button (`windowWillClose` runs the same teardown).
    public func close() {
        guard isShown else { return }
        teardown()
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        teardown()
    }

    /// The one place that leaves the open count and pauses playback — run
    /// exactly once per window, however the close was triggered.
    private func teardown() {
        guard isShown else { return }
        isShown = false
        // A closed window whose player keeps playing leaves audio coming
        // from a window the user can no longer see.
        controller.pause()
        Self.count -= 1
        Self.open.removeAll { $0 === self }
        Self.applyActivationPolicy()
    }

    /// Regular while any editor is open, accessory once the last one closes
    /// — driven by the count, never by a single window's lifetime.
    private static func applyActivationPolicy() {
        NSApp.setActivationPolicy(count > 0 ? .regular : .accessory)
    }
}
