// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// The floating recording HUD (§4.11).
///
/// §4.11 says the hotkey and the menu-bar item start a recording with **no
/// window opening**. This is a window, so it earns its place by never doing
/// the thing that rule protects against: it cannot become key, cannot become
/// main, does not activate the app, and never takes the keyboard away from
/// whatever is being demonstrated. `RecordingHUDPanelTests` asserts each of
/// those individually rather than trusting the initialiser to have set them.
///
/// The controls it shows are a visible reminder of global hotkeys, not the
/// only way to reach them — see `RecordingHUDModel`'s shortcut constants. A
/// panel that refuses focus cannot be tabbed to, so buttons alone would make
/// recording a pointer-only activity.
@MainActor
final class RecordingHUDPanel: NSPanel {

    private let content: RecordingHUDView
    private var lastAnnouncement = ""

    /// `.borderless` plus `.nonactivatingPanel`: the second is the one that
    /// matters. Without it, clicking a button here brings Snitt forward and
    /// pushes the app being recorded behind — visible in the recording, and
    /// exactly the interruption §4.11 exists to prevent.
    init(shortcuts: RecordingHUDView.Shortcuts = .init()) {
        content = RecordingHUDView(shortcuts: shortcuts)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // Above normal windows AND above full-screen ones: you are usually
        // recording something running full screen, and a HUD hidden behind the
        // subject is a HUD that does not exist.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                              .ignoresCycle]
        // Set explicitly, not inherited: NSWindow defaults this to true for a
        // programmatically created window, which is an over-release under ARC.
        // A shipped v0.1.0 crash came from exactly this on the Settings window.
        isReleasedWhenClosed = false
        // The HUD reports on a recording that keeps running when Snitt is not
        // frontmost — which is the normal case — so it must not vanish with
        // the app's activation.
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        contentView = content
        setAccessibilityLabel("Recording controls")
    }

    /// Never. Both of these are the constraint, not a preference.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var onMark: (() -> Void)? {
        get { content.onMark } set { content.onMark = newValue }
    }
    var onTogglePause: (() -> Void)? {
        get { content.onTogglePause } set { content.onTogglePause = newValue }
    }
    var onStop: (() -> Void)? {
        get { content.onStop } set { content.onStop = newValue }
    }

    private var state: RecordingState = .idle
    private var tick: Timer?

    /// The live entry point: hand it a state and it keeps its own clock.
    ///
    /// The panel ticks itself rather than being driven from outside so there
    /// is exactly one call site per state CHANGE in the app delegate. A second
    /// caller refreshing the clock is a second thing that can forget to.
    func update(state newState: RecordingState) {
        state = newState
        apply(RecordingHUDModel.presentation(for: state, now: Date()))
        tick?.invalidate()
        tick = nil
        // A timer only while there is a number that moves. `.stopping` and
        // `.idle` have none, so nothing spins behind a HUD showing "Saving…".
        guard case .recording = newState else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.apply(RecordingHUDModel.presentation(for: self.state, now: Date()))
            }
        }
    }

    /// Applies a presentation, shows or hides accordingly, and tells the
    /// accessibility system when the state actually changed.
    ///
    /// Announcing only on CHANGE, not on every tick: this is driven by a timer
    /// so the clock advances, and posting "Recording" once a second would make
    /// VoiceOver unusable while recording.
    func apply(_ presentation: RecordingHUDPresentation) {
        content.apply(presentation)
        guard presentation.isVisible else {
            lastAnnouncement = ""
            orderOut(nil)
            return
        }
        if !isVisible {
            positionAtBottomCentre()
            // `orderFrontRegardless`, never `makeKeyAndOrderFront`: the latter
            // is the one line that would break §4.11.
            orderFrontRegardless()
        }
        if presentation.announcement != lastAnnouncement {
            lastAnnouncement = presentation.announcement
            NSAccessibility.post(element: self,
                                 notification: .announcementRequested,
                                 userInfo: [.announcement: presentation.announcement,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Bottom centre of the active screen, clear of the Dock.
    func positionAtBottomCentre(on screen: NSScreen? = NSScreen.main) {
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                               y: visible.minY + 24))
    }

    /// Test seam — the view's own state, without reaching through AppKit.
    var contentForTesting: RecordingHUDView { content }
    var isTickingForTesting: Bool { tick != nil }
}

/// The HUD's contents: a status capsule and three controls.
@MainActor
final class RecordingHUDView: NSView {
    private let dot = NSView()
    private let clock = NSTextField(labelWithString: "0:00")
    private let status = NSTextField(labelWithString: "")
    private let markButton = NSButton()
    private let pauseButton = NSButton()
    private let stopButton = NSButton()

    var onMark: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?

    /// The keys that reach these controls without the pointer, as the user
    /// has them configured. `pause` is nil because no pause hotkey exists yet.
    struct Shortcuts: Equatable, Sendable {
        var mark: String?
        var pause: String?
        var stop: String?
    }
    private let shortcuts: Shortcuts

    init(shortcuts: Shortcuts = Shortcuts()) {
        self.shortcuts = shortcuts
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        clock.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        status.font = .preferredFont(forTextStyle: .caption1)
        status.textColor = .secondaryLabelColor

        configure(markButton, symbol: "flag.fill",
                  label: RecordingHUDModel.controlLabel("Mark this moment",
                                                        shortcut: shortcuts.mark),
                  action: #selector(markTapped))
        configure(pauseButton, symbol: "pause.fill",
                  label: RecordingHUDModel.controlLabel("Pause recording",
                                                        shortcut: shortcuts.pause),
                  action: #selector(pauseTapped))
        configure(stopButton, symbol: "stop.fill",
                  label: RecordingHUDModel.controlLabel("Stop recording",
                                                        shortcut: shortcuts.stop),
                  action: #selector(stopTapped))

        let capsule = NSStackView(views: [dot, clock, status])
        capsule.spacing = 7
        capsule.alignment = .centerY
        let row = NSStackView(views: [capsule, markButton, pauseButton, stopButton])
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// 28pt, above the 24pt WCAG 2.5.8 target floor. `NSImage` symbols rather
    /// than ⏸/⏹ characters, which render as colour emoji on some systems and
    /// as text on others and cannot take a tint.
    private func configure(_ button: NSButton, symbol: String, label: String,
                           action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .flexiblePush
        button.isBordered = true
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    func apply(_ p: RecordingHUDPresentation) {
        clock.stringValue = p.clock ?? ""
        clock.isHidden = p.clock == nil
        status.stringValue = p.statusWord ?? ""
        status.isHidden = p.statusWord == nil

        // Shape first, colour second. A hollow ring versus a filled dot is
        // what a person who cannot separate red from grey has to read.
        dot.layer?.backgroundColor = p.isPaused
            ? NSColor.clear.cgColor : NSColor.systemRed.cgColor
        dot.layer?.borderWidth = p.isPaused ? 2 : 0
        dot.layer?.borderColor = NSColor.secondaryLabelColor.cgColor

        markButton.isEnabled = p.canMark
        pauseButton.isEnabled = p.canTogglePause
        stopButton.isEnabled = p.canStop

        let symbol = p.isPaused ? "record.circle.fill" : "pause.fill"
        let label = RecordingHUDModel.controlLabel(
            p.isPaused ? "Resume recording" : "Pause recording", shortcut: shortcuts.pause)
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        pauseButton.setAccessibilityLabel(label)
    }

    @objc private func markTapped() { onMark?() }
    @objc private func pauseTapped() { onTogglePause?() }
    @objc private func stopTapped() { onStop?() }

    // MARK: - Test seams
    var clockForTesting: String { clock.isHidden ? "" : clock.stringValue }
    var statusForTesting: String { status.isHidden ? "" : status.stringValue }
    var enabledForTesting: (mark: Bool, pause: Bool, stop: Bool) {
        (markButton.isEnabled, pauseButton.isEnabled, stopButton.isEnabled)
    }
    var pauseLabelForTesting: String { pauseButton.accessibilityLabel() ?? "" }
    var buttonSizesForTesting: [NSSize] {
        [markButton, pauseButton, stopButton].map(\.frame.size)
    }
    var accessibilityLabelsForTesting: [String] {
        [markButton, pauseButton, stopButton].map { $0.accessibilityLabel() ?? "" }
    }
    var dotIsHollowForTesting: Bool { (dot.layer?.borderWidth ?? 0) > 0 }
}
