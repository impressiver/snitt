import AppKit
import Combine
import SnittDocument
import SwiftUI

/// Owns the mutable editing state the timeline drives: the EDL a trim
/// appends a cut to, and the events a trim's re-apply must keep passing.
///
/// `PreviewController.apply(edl:events:)` defaults `events` to `[]`, which
/// means "no markers to place" and recomputes jump points to empty rather
/// than keeping stale ones (Task 4's binding — stale markers are a silent
/// §9 divergence, an empty scrub bar is a visible one). This type exists so
/// that every trim keeps passing the recording's real events instead of
/// silently losing every marker.
@MainActor
private final class EditorTimelineState: ObservableObject {
    let controller: PreviewController
    let events: [LoggedEvent]
    @Published var edl: EditDecisionList

    init(controller: PreviewController, edl: EditDecisionList, events: [LoggedEvent]) {
        self.controller = controller
        self.edl = edl
        self.events = events
    }

    func onScrub(_ time: Double) {
        Task { await controller.seek(toSeconds: time) }
    }

    func onTrim(_ range: TimeRange) {
        edl.cuts.append(range)
        let edl = self.edl
        let events = self.events
        Task { try? await controller.apply(edl: edl, events: events) }
    }
}

/// Embeds `TimelineView` (AppKit) in the SwiftUI shell, driving it from
/// `state` and forwarding its callbacks back into `state`.
private struct TimelineViewRepresentable: NSViewRepresentable {
    @ObservedObject var state: EditorTimelineState
    let playhead: Double

    func makeNSView(context: Context) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 480, height: 40))
        view.onScrub = { [weak state] in state?.onScrub($0) }
        view.onTrim = { [weak state] in state?.onTrim($0) }
        return view
    }

    func updateNSView(_ nsView: TimelineView, context: Context) {
        nsView.update(duration: state.controller.durationSeconds,
                     cuts: state.edl.cuts,
                     jumpPoints: state.controller.jumpPoints,
                     playhead: playhead)
    }
}

/// SwiftUI shell around the `AVPlayerLayer` surface: play/pause controls, the
/// timeline, and a jump-point list. §4.7 puts the video surface — and, per
/// Task 6, the timeline's gesture handling — in AppKit while everything
/// around them stays SwiftUI.
private struct EditorContentView: View {
    @ObservedObject fileprivate var state: EditorTimelineState
    @State private var playhead: Double = 0

    private var controller: PreviewController { state.controller }

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: controller.player)
                .frame(minWidth: 480, minHeight: 270)
            TimelineViewRepresentable(state: state, playhead: playhead)
                .frame(height: 40)
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
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            // Playhead position is appearance only — not asserted by any
            // test (Task 6 dispatch) — so simple polling is enough; a
            // player-driven time observer would add AVFoundation closure
            // plumbing for a value nothing verifies.
            let seconds = controller.player.currentTime().seconds
            playhead = seconds.isFinite ? seconds : 0
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

    /// `edl` and `events` default to an untrimmed range and no markers for
    /// callers that only care about window lifecycle (most existing tests) —
    /// a real editor session must pass the recording's actual EDL and
    /// events, or every trim it draws applies against the wrong starting
    /// point and loses the recording's real markers.
    public init(controller: PreviewController, title: String,
                edl: EditDecisionList = .fullRange(), events: [LoggedEvent] = []) {
        self.controller = controller
        let state = EditorTimelineState(controller: controller, edl: edl, events: events)
        let hosting = NSHostingView(rootView: EditorContentView(state: state))
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

    // MARK: - Testing seam

    /// Closes every editor `EditorWindowController` currently thinks is
    /// open, exactly as if each had gone through `close()`.
    ///
    /// M4a review finding #3: a test that opens an editor through
    /// `RecordingCoordinator.stopForTesting()` — which constructs the
    /// `EditorWindowController` internally and never hands it back — has no
    /// other way to tear it down, so it leaked a real window (and a bumped
    /// `openWindowCount`) for the rest of the run. `close()` itself is
    /// idempotent and per-instance; this just calls it for every instance
    /// still in `open`, using a copy of the array since `close()` mutates
    /// `open` as it runs.
    static func closeAllForTesting() {
        for editor in open {
            editor.close()
        }
    }
}
