import Foundation
import AppKit
import Carbon.HIToolbox

/// The Settings window (§4.14, Command-comma).
///
/// Consolidates five settings that accumulated as status-item toggles across
/// M2b–M5b. The status-item toggles STAY — they are the fast path — so both
/// surfaces read and write the same `UserDefaults` keys through the same
/// settings types (`AgentSettings`, `EventLoggingSettings`, `MicrophoneSettings`,
/// `UpdateSettings`, `CrashReportSettings`). A settings window with its own
/// storage would be two settings wearing one name: the menu says off, the
/// window says on, and the user cannot tell which one the app obeys.
///
/// D55 (M5f Task 7) adds two `HotkeyRecorderButton`s alongside those five
/// checkboxes, for the record and marker hotkeys. They read/write
/// `HotkeySettings` against the SAME `defaults` — no status-item equivalent
/// exists for a hotkey the way one does for the five checkboxes, but the
/// single-store discipline still applies — and, unlike a checkbox, changing
/// one must also re-register the REAL `HotkeyMonitor` `hotkeyRegistrar`
/// owns; see `HotkeyRegistrar`'s own doc comment for why storing a new
/// combination without doing that would be M5b's R22 defect again.
///
/// M5f also adds a row for `OutputDirectorySettings` — where recordings are
/// saved (D56/M5d's deferred output-location item). No status-item
/// equivalent exists for this one either (there is no natural "toggle" for
/// a folder path), but the same single-store discipline applies: the row
/// reads and writes the SAME `defaults` and the SAME settings type
/// `RecordingCoordinator` reads at record time, so this window is never a
/// second, independently-correct opinion about where recordings go.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Internal (not private) so tests can confirm a second `show()` reuses
    /// this instance instead of creating another window.
    private(set) static var shared: SettingsWindowController?

    let window: NSWindow
    private let updater: UpdaterController
    private let defaults: UserDefaults
    private let hotkeyRegistrar: HotkeyRegistrar
    private let onChange: (() -> Void)?
    private let eventLoggingToggle: (Bool, UserDefaults) -> Bool
    private let microphoneToggle: (Bool, UserDefaults) -> Bool
    private let hotkeyConflictAlert: @MainActor (HotkeyAction, HotkeyCombination) -> Void
    private let outputDirectoryUnwritableAlert: @MainActor (URL) -> Void
    private var hotkeyButtons: [HotkeyAction: HotkeyRecorderButton] = [:]
    private var outputDirectoryLabel: NSTextField?

    static let agentRecordingTitle = "Allow agent recording"
    static let eventLoggingTitle = "Log input events"
    static let microphoneTitle = "Record voiceover"
    static let automaticUpdatesTitle = "Check for updates automatically"
    static let crashReportsTitle = "Include crash reports in diagnostics"
    static let outputDirectoryCaption = "Save recordings to"
    static let outputDirectoryButtonTitle = "Choose…"

    /// - Parameters:
    ///   - updater: the app's one `UpdaterController`. The automatic-updates
    ///     checkbox is routed through its `automaticChecksEnabled` setter,
    ///     not straight to `UserDefaults` — M5b's R22 caught exactly that
    ///     bug: a value stored but never forwarded to Sparkle's own
    ///     `automaticallyChecksForUpdates`, so the setting read back
    ///     correctly and changed nothing.
    ///   - defaults: the store all settings types (five checkboxes' worth,
    ///     plus `HotkeySettings` and `OutputDirectorySettings`) load from and
    ///     save to. Defaults to `.standard`, the same store the status item uses
    ///     in production, so both surfaces agree without either one naming
    ///     the other. Tests inject a `UserDefaults(suiteName:)` fixture here
    ///     instead, so nothing touches the real preference domain.
    ///   - onChange: invoked after any toggle so the caller (the app
    ///     delegate) can refresh the status item's own cached checkmark
    ///     state from the same store — the menu's checkmarks are cached
    ///     properties, refreshed only when the menu's own handlers run,
    ///     so without this a change made in the window would not show up
    ///     in the menu until the next launch.
    ///   - hotkeyRegistrar: owns the app's two REAL hotkey registrations
    ///     (D55); the record/marker recorder buttons re-register through it
    ///     rather than writing `HotkeySettings` directly. Defaults to a
    ///     fresh, inert registrar — fine for any test that never interacts
    ///     with a hotkey button — so existing callers need not be touched;
    ///     production (`AppDelegate.showSettings`) always passes the SAME
    ///     registrar `applicationDidFinishLaunching` created, so a recorded
    ///     combination re-registers the hotkey that is actually live.
    static func show(updater: UpdaterController,
                      defaults: UserDefaults = .standard,
                      hotkeyRegistrar: HotkeyRegistrar = HotkeyRegistrar(onRecord: {}, onMarker: {}),
                      onChange: (() -> Void)? = nil) {
        show(updater: updater, defaults: defaults, hotkeyRegistrar: hotkeyRegistrar,
             onChange: onChange, activate: true)
    }

    /// `activate` is `false` only from tests. Two real front-ordered,
    /// activated windows created concurrently by two different test suites
    /// (this one and `EditorWindowControllerTests`) crashed the process
    /// outside any `#expect` — `swift test` reported exit 0 with no summary
    /// line, the exact silent-segfault shape this project has already been
    /// bitten by. The window is still real and still gets its real content
    /// view and delegate; tests just never ask AppKit to put it on screen or
    /// steal focus, which is the part that was racing.
    ///
    /// `eventLoggingToggle` is also test-only. Production always uses the
    /// default, which forwards to `EventLoggingToggle.apply` against the
    /// real `PermissionOnboarding`/`InputMonitoringAccess` — real AppKit
    /// alert and real per-machine TCC state, neither of which a test can
    /// drive. Tests substitute a fake that reports the grant as refused, so
    /// the checkbox's return-to-off behavior can be pinned without a real
    /// dialog appearing.
    ///
    /// `hotkeyConflictAlert` is also test-only, mirroring
    /// `eventLoggingToggle` immediately above: production always uses the
    /// default, which raises a real `NSAlert` (D55 — a combination another
    /// app owns must say so, the same rule `main.swift`'s launch-time
    /// registration already follows). A test substitutes a spy so the
    /// button's revert-on-failure behavior can be pinned without a real,
    /// blocking dialog appearing.
    ///
    /// `microphoneToggle` mirrors `eventLoggingToggle` exactly, one rung
    /// down the ladder: production forwards to `MicrophoneToggle.apply`
    /// against the real `PermissionOnboarding`/`MicrophoneAccess`; a test
    /// substitutes a fake for the same reason.
    ///
    /// `outputDirectoryUnwritableAlert` is also test-only, mirroring
    /// `hotkeyConflictAlert` immediately above: production always uses the
    /// default, which raises a real `NSAlert` naming the folder that was
    /// rejected. A test substitutes a spy so `applyOutputDirectory`'s
    /// reject-and-keep-the-old-value behavior can be pinned without a real,
    /// blocking dialog appearing.
    static func show(updater: UpdaterController,
                      defaults: UserDefaults = .standard,
                      hotkeyRegistrar: HotkeyRegistrar = HotkeyRegistrar(onRecord: {}, onMarker: {}),
                      onChange: (() -> Void)? = nil,
                      activate: Bool,
                      eventLoggingToggle: @escaping (Bool, UserDefaults) -> Bool = {
                          EventLoggingToggle.apply($0, defaults: $1)
                      },
                      microphoneToggle: @escaping (Bool, UserDefaults) -> Bool = {
                          MicrophoneToggle.apply($0, defaults: $1)
                      },
                      hotkeyConflictAlert: @escaping @MainActor (HotkeyAction, HotkeyCombination) -> Void =
                          SettingsWindowController.presentHotkeyConflictAlert,
                      outputDirectoryUnwritableAlert: @escaping @MainActor (URL) -> Void =
                          SettingsWindowController.presentOutputDirectoryUnwritableAlert) {
        // A second Command-comma focuses the existing window rather than
        // opening a second one — two Settings windows can disagree on
        // screen.
        if let existing = shared {
            if activate {
                existing.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        let controller = SettingsWindowController(updater: updater, defaults: defaults,
                                                  hotkeyRegistrar: hotkeyRegistrar, onChange: onChange,
                                                  eventLoggingToggle: eventLoggingToggle,
                                                  microphoneToggle: microphoneToggle,
                                                  hotkeyConflictAlert: hotkeyConflictAlert,
                                                  outputDirectoryUnwritableAlert: outputDirectoryUnwritableAlert)
        shared = controller
        if activate {
            controller.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The production `hotkeyConflictAlert`: a real, modal `NSAlert` naming
    /// the combination that failed and which hotkey it was for — D55's
    /// "must say so", the Settings-window half of what `main.swift`'s
    /// launch-time registration already does for the same failure.
    static func presentHotkeyConflictAlert(action: HotkeyAction, combination: HotkeyCombination) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snitt could not use \(combination.displayString) for the "
                           + "\(action.label) — another app may already be using it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The production `outputDirectoryUnwritableAlert`: a real, modal
    /// `NSAlert` naming the folder that was rejected. Checked and reported
    /// HERE, at the moment a person picks a folder, for the same reason
    /// `RecordingCoordinator.prepareOutputDirectory` checks again before a
    /// recording starts: better to find out a folder will not work the
    /// moment it is chosen than the next time the record hotkey is pressed.
    static func presentOutputDirectoryUnwritableAlert(_ directory: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snitt cannot save recordings to \(directory.path)."
        alert.informativeText = "Choose a folder Snitt can write to."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Test-only: tears the singleton down between tests, so each test gets
    /// its own window built against its own fixture rather than inheriting
    /// whatever a previous test's `show()` left behind.
    ///
    /// Deliberately drops the reference rather than calling the real
    /// `window.close()`: this test target runs suites concurrently, and a
    /// real close racing another suite's real window close crashed the
    /// process outside any `#expect` (see `SettingsWindowTests`). Dropping
    /// the reference still releases the window through ordinary
    /// deinitialization; it just does not additionally invoke AppKit's
    /// close machinery from a test.
    static func resetForTesting() {
        shared = nil
    }

    private init(updater: UpdaterController, defaults: UserDefaults, hotkeyRegistrar: HotkeyRegistrar,
                onChange: (() -> Void)?,
                eventLoggingToggle: @escaping (Bool, UserDefaults) -> Bool,
                microphoneToggle: @escaping (Bool, UserDefaults) -> Bool,
                hotkeyConflictAlert: @escaping @MainActor (HotkeyAction, HotkeyCombination) -> Void,
                outputDirectoryUnwritableAlert: @escaping @MainActor (URL) -> Void) {
        self.updater = updater
        self.defaults = defaults
        self.hotkeyRegistrar = hotkeyRegistrar
        self.onChange = onChange
        self.eventLoggingToggle = eventLoggingToggle
        self.microphoneToggle = microphoneToggle
        self.hotkeyConflictAlert = hotkeyConflictAlert
        self.outputDirectoryUnwritableAlert = outputDirectoryUnwritableAlert
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
        window.title = "Settings"
        // A programmatically created NSWindow defaults `isReleasedWhenClosed`
        // to TRUE. Under ARC that is an over-release: this controller holds a
        // strong reference, and AppKit's own window-animation objects hold one
        // too, so closing the window frees it out from under both. The dangling
        // object then surfaces as EXC_BAD_ACCESS in `objc_release` inside
        // `-[_NSWindowTransformAnimation dealloc]` during a CATransaction
        // commit — which is exactly the crash a user hit by toggling
        // "Log input events" in this window on v0.1.0.
        //
        // EditorWindowController has set this since M4a; this window was added
        // in M5c and never did. `WindowLifetimeTests` now pins BOTH, so a third
        // window cannot repeat it.
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
        window.contentView = makeContentView()
    }

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(checkbox(
            title: Self.agentRecordingTitle,
            isOn: AgentSettings.load(defaults).agentRecordingEnabled,
            action: #selector(toggleAgentRecording(_:))))

        stack.addArrangedSubview(checkbox(
            title: Self.eventLoggingTitle,
            isOn: EventLoggingSettings.load(defaults).enabled,
            action: #selector(toggleEventLogging(_:))))

        stack.addArrangedSubview(checkbox(
            title: Self.microphoneTitle,
            isOn: MicrophoneSettings.load(defaults).enabled,
            action: #selector(toggleMicrophone(_:))))

        stack.addArrangedSubview(checkbox(
            title: Self.automaticUpdatesTitle,
            isOn: UpdateSettings.load(defaults).automaticChecksEnabled,
            action: #selector(toggleAutomaticUpdates(_:))))

        stack.addArrangedSubview(checkbox(
            title: Self.crashReportsTitle,
            isOn: CrashReportSettings.load(defaults).enabled,
            action: #selector(toggleCrashReports(_:))))

        stack.addArrangedSubview(hotkeyRecorderButton(for: .record))
        stack.addArrangedSubview(hotkeyRecorderButton(for: .marker))

        stack.addArrangedSubview(outputDirectoryRow())

        return stack
    }

    private func checkbox(title: String, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        return button
    }

    /// Test-only: looks a checkbox up by its title so a test can simulate a
    /// click without reaching into `NSStackView` internals.
    func checkbox(titled title: String) -> NSButton? {
        (window.contentView as? NSStackView)?.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .first { $0.title == title }
    }

    /// Builds one hotkey recorder button, wired to re-register through
    /// `hotkeyRegistrar` (D55) rather than writing `HotkeySettings`
    /// directly — see this type's own doc comment on why the two must move
    /// together.
    private func hotkeyRecorderButton(for action: HotkeyAction) -> HotkeyRecorderButton {
        let button = HotkeyRecorderButton(hotkeyAction: action)
        button.setDisplayedCombination(HotkeySettings.load(defaults)[action])
        button.onCapture = { [weak self] combination in
            self?.applyHotkey(combination, for: action)
        }
        // Escape cancels the recording — restore whatever is CURRENTLY
        // registered/stored rather than leaving the "press keys…" prompt
        // showing.
        button.onCancel = { [weak self] in
            self?.refreshHotkeyButton(for: action)
        }
        hotkeyButtons[action] = button
        return button
    }

    /// Test-only: looks a hotkey recorder button up by its action, mirroring
    /// `checkbox(titled:)` above.
    func hotkeyButton(for action: HotkeyAction) -> HotkeyRecorderButton? {
        hotkeyButtons[action]
    }

    /// A key was captured for `action` (D55). Re-registers through
    /// `hotkeyRegistrar` FIRST — `apply` persists the new combination to
    /// `defaults` only once it is confirmed live, so this can trust
    /// `refreshHotkeyButton` below to show the right thing either way: the
    /// NEW combination on success, or the unchanged OLD one (`apply`
    /// restores the previous registration and writes nothing) on failure.
    /// M5b's R22 defect — a setting that reads back correctly and changes
    /// nothing — is exactly what skipping `hotkeyRegistrar` in favor of a
    /// plain `HotkeySettings(...).save(to:)` here would reintroduce.
    private func applyHotkey(_ combination: HotkeyCombination, for action: HotkeyAction) {
        // `hotkeyConflictAlert` (invoked by `apply` on failure, via
        // `reportFailure`) already tells the user why; nothing else to
        // branch on here — `refreshHotkeyButton` below shows the right
        // thing either way, and `onChange?()` still fires so the status
        // item stays in sync with whatever else might be pending.
        hotkeyRegistrar.apply(combination, to: action, defaults: defaults,
                              reportFailure: hotkeyConflictAlert)
        refreshHotkeyButton(for: action)
        onChange?()
    }

    private func refreshHotkeyButton(for action: HotkeyAction) {
        hotkeyButtons[action]?.setDisplayedCombination(HotkeySettings.load(defaults)[action])
    }

    /// Builds the "Save recordings to" row: a caption, the current path
    /// (truncated in the middle, since a long path's END — the folder name
    /// actually chosen — matters more than its middle), and a button that
    /// opens `NSOpenPanel`.
    private func outputDirectoryRow() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let caption = NSTextField(labelWithString: "\(Self.outputDirectoryCaption):")
        container.addArrangedSubview(caption)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let pathLabel = NSTextField(labelWithString:
            OutputDirectorySettings.load(defaults).directory.path)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        outputDirectoryLabel = pathLabel

        let button = NSButton(title: Self.outputDirectoryButtonTitle,
                              target: self, action: #selector(chooseOutputDirectory(_:)))
        row.addArrangedSubview(pathLabel)
        row.addArrangedSubview(button)
        container.addArrangedSubview(row)
        return container
    }

    /// Test-only: reads the currently displayed path, mirroring
    /// `checkbox(titled:)`/`hotkeyButton(for:)` above.
    func outputDirectoryPathText() -> String? {
        outputDirectoryLabel?.stringValue
    }

    /// Opens the real, modal `NSOpenPanel` (D56/M5d's deferred item, per the
    /// brief: directories only, no files). Not reachable from a test — see
    /// `SettingsWindowController.show`'s `activate: false` doc comment for
    /// the same class of AppKit-modal limitation `HotkeyRecorderButton`'s
    /// `capture(_:)` test seam already works around; `applyOutputDirectory`
    /// below is that seam for this control.
    @objc private func chooseOutputDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = OutputDirectorySettings.load(defaults).directory
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        applyOutputDirectory(url)
    }

    /// Test seam alongside `chooseOutputDirectory` above: production reaches
    /// this only via a real, un-drivable `NSOpenPanel`; a test calls this
    /// directly with a synthetic URL instead.
    ///
    /// Checked for writability HERE, before saving — not merely round-tripped
    /// through `UserDefaults` — for the same reason
    /// `RecordingCoordinator.prepareOutputDirectory` checks again
    /// immediately before a recording starts: telling someone their chosen
    /// folder will not work the moment they pick it is far more useful than
    /// only discovering it the next time the record hotkey is pressed. A
    /// rejected folder changes nothing — the previously stored value (or the
    /// default) stays in effect, exactly like `applyHotkey`'s revert-on-
    /// failure above.
    func applyOutputDirectory(_ url: URL, fileManager: FileManager = .default) {
        guard fileManager.isWritableFile(atPath: url.path) else {
            outputDirectoryUnwritableAlert(url)
            return
        }
        OutputDirectorySettings(directory: url).save(to: defaults)
        refreshOutputDirectoryLabel()
        onChange?()
    }

    private func refreshOutputDirectoryLabel() {
        outputDirectoryLabel?.stringValue = OutputDirectorySettings.load(defaults).directory.path
    }

    @objc private func toggleAgentRecording(_ sender: NSButton) {
        var settings = AgentSettings.load(defaults)
        settings.agentRecordingEnabled = (sender.state == .on)
        settings.save(to: defaults)
        onChange?()
    }

    @objc private func toggleEventLogging(_ sender: NSButton) {
        // Routed through the SAME §4.10 ladder the status item runs — see
        // `EventLoggingToggle`'s doc comment. `apply` returns the state
        // actually persisted, which is `false` whenever the pre-explain is
        // declined or the Input Monitoring grant is unavailable, even
        // though the user just checked this box; the checkbox is set back
        // to match, so it never shows a state the setting does not have.
        let applied = eventLoggingToggle(sender.state == .on, defaults)
        sender.state = applied ? .on : .off
        onChange?()
    }

    @objc private func toggleMicrophone(_ sender: NSButton) {
        // Same ladder, one rung down — see `MicrophoneToggle`'s doc comment
        // and `toggleEventLogging` immediately above for why this is not a
        // plain `MicrophoneSettings(...).save(to:)`.
        let applied = microphoneToggle(sender.state == .on, defaults)
        sender.state = applied ? .on : .off
        onChange?()
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSButton) {
        let enabled = sender.state == .on
        var settings = UpdateSettings.load(defaults)
        settings.automaticChecksEnabled = enabled
        settings.save(to: defaults)
        // Through UpdaterController's own setter, NOT straight to
        // UserDefaults — see the `updater` parameter doc above.
        updater.automaticChecksEnabled = enabled
        onChange?()
    }

    @objc private func toggleCrashReports(_ sender: NSButton) {
        CrashReportSettings(enabled: sender.state == .on).save(to: defaults)
        onChange?()
    }

    /// Re-reads all five checkbox settings, both hotkeys, and the output
    /// directory from the store (whole-branch review F7).
    ///
    /// `refreshStatusItemFromSettings` syncs window → menu; there was no
    /// menu → window direction, and these handlers derive the new value from
    /// `sender.state` rather than from the store. So with the Settings
    /// window left open, a status-item toggle changed the store without
    /// changing this checkbox, and the next click on it wrote a value
    /// derived from the stale checkmark — silently reverting what the user
    /// had just done from the menu.
    func refreshFromStore() {
        checkbox(titled: Self.agentRecordingTitle)?.state =
            AgentSettings.load(defaults).agentRecordingEnabled ? .on : .off
        checkbox(titled: Self.eventLoggingTitle)?.state =
            EventLoggingSettings.load(defaults).enabled ? .on : .off
        checkbox(titled: Self.microphoneTitle)?.state =
            MicrophoneSettings.load(defaults).enabled ? .on : .off
        checkbox(titled: Self.automaticUpdatesTitle)?.state =
            UpdateSettings.load(defaults).automaticChecksEnabled ? .on : .off
        checkbox(titled: Self.crashReportsTitle)?.state =
            CrashReportSettings.load(defaults).enabled ? .on : .off
        // Hotkeys have no status-item equivalent to drift from, but a
        // future launch (or another window, if one ever exists) could still
        // change `HotkeySettings` underneath this one — refresh for the
        // same reason the five checkboxes above do.
        refreshHotkeyButton(for: .record)
        refreshHotkeyButton(for: .marker)
        // Same reasoning: the output-directory row has no status-item
        // equivalent either, but nothing stops the value underneath from
        // changing (a future second surface, or a test poking `defaults`
        // directly) while this window is key.
        refreshOutputDirectoryLabel()
    }

    /// The window coming forward is the moment a stale checkbox is about to
    /// be believed — and, on macOS, the moment right after the user was
    /// somewhere else (the status menu, for instance) changing the same
    /// setting.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshFromStore()
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

/// A button that shows a hotkey combination (D55) and, once clicked, waits
/// for the next key combination pressed anywhere in this window and reports
/// it — the Settings-window half of customizable hotkeys.
///
/// Overrides `performKeyEquivalent(with:)` rather than `keyDown(with:)` or
/// an `NSEvent` local monitor: AppKit gives every view in a window's
/// content-view hierarchy a chance at `performKeyEquivalent` for EVERY
/// keyDown — the same mechanism menu-bar key equivalents use — before
/// ordinary first-responder `keyDown` dispatch ever runs, so this control
/// needs no first-responder juggling to see a keypress typed anywhere in
/// the window while armed. Guarded by `isRecording`: while not recording,
/// this returns `false` immediately, so ordinary window shortcuts (⌘W, ⌘,)
/// are completely unaffected.
@MainActor
final class HotkeyRecorderButton: NSButton {
    let hotkeyAction: HotkeyAction
    private(set) var isRecording = false
    var onCapture: ((HotkeyCombination) -> Void)?
    var onCancel: (() -> Void)?

    init(hotkeyAction: HotkeyAction) {
        self.hotkeyAction = hotkeyAction
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(handleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HotkeyRecorderButton does not support NSCoding")
    }

    func setDisplayedCombination(_ combination: HotkeyCombination) {
        isRecording = false
        title = "\(hotkeyAction.label): \(combination.displayString)"
    }

    @objc private func handleClick(_ sender: Any?) {
        beginRecording()
    }

    /// Test seam alongside `capture(_:)`: arms recording without a real
    /// click event. Production always reaches this through `handleClick`.
    func beginRecording() {
        isRecording = true
        title = "\(hotkeyAction.label): press keys… (Esc to cancel)"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        capture(event)
        return true
    }

    /// Test seam: production keypresses arrive via `performKeyEquivalent`
    /// above while this window is key; a test calls this directly with a
    /// synthetic `NSEvent` (`NSEvent.keyEvent(with:...)`) instead of routing
    /// one through a real key window, which this concurrent test target
    /// cannot safely share (see `SettingsWindowController.show`'s own
    /// `activate: false` seam for the same reason).
    func capture(_ event: NSEvent) {
        // Escape cancels rather than recording ⎋ itself as the new
        // combination — the one key someone pressing this button is more
        // likely to mean "never mind" than "bind this".
        guard event.keyCode != UInt16(kVK_Escape) else {
            isRecording = false
            onCancel?()
            return
        }
        let combination = HotkeyCombination(fromKeyEvent: event)
        // A bare key with no modifier would hijack ordinary typing anywhere
        // else in macOS — the same reasoning `HotkeyCombination
        // .defaultCombination`'s own doc comment gives for shipping with a
        // modifier at all. Stay in recording mode rather than accept it, so
        // the next real attempt still lands here instead of silently
        // failing registration a moment later.
        guard combination.modifiers != 0 else { return }
        isRecording = false
        onCapture?(combination)
    }
}
