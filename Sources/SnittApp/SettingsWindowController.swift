import Foundation
import AppKit

/// The Settings window (§4.14, Command-comma).
///
/// Consolidates four settings that accumulated as status-item toggles across
/// M2b–M5b. The status-item toggles STAY — they are the fast path — so both
/// surfaces read and write the same `UserDefaults` keys through the same
/// settings types (`AgentSettings`, `EventLoggingSettings`, `UpdateSettings`,
/// `CrashReportSettings`). A settings window with its own storage would be
/// two settings wearing one name: the menu says off, the window says on, and
/// the user cannot tell which one the app obeys.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Internal (not private) so tests can confirm a second `show()` reuses
    /// this instance instead of creating another window.
    private(set) static var shared: SettingsWindowController?

    let window: NSWindow
    private let updater: UpdaterController
    private let defaults: UserDefaults
    private let onChange: (() -> Void)?
    private let eventLoggingToggle: (Bool, UserDefaults) -> Bool

    static let agentRecordingTitle = "Allow agent recording"
    static let eventLoggingTitle = "Log input events"
    static let automaticUpdatesTitle = "Check for updates automatically"
    static let crashReportsTitle = "Include crash reports in diagnostics"

    /// - Parameters:
    ///   - updater: the app's one `UpdaterController`. The automatic-updates
    ///     checkbox is routed through its `automaticChecksEnabled` setter,
    ///     not straight to `UserDefaults` — M5b's R22 caught exactly that
    ///     bug: a value stored but never forwarded to Sparkle's own
    ///     `automaticallyChecksForUpdates`, so the setting read back
    ///     correctly and changed nothing.
    ///   - defaults: the store all four settings types load from and save
    ///     to. Defaults to `.standard`, the same store the status item uses
    ///     in production, so both surfaces agree without either one naming
    ///     the other. Tests inject a `UserDefaults(suiteName:)` fixture here
    ///     instead, so nothing touches the real preference domain.
    ///   - onChange: invoked after any toggle so the caller (the app
    ///     delegate) can refresh the status item's own cached checkmark
    ///     state from the same store — the menu's checkmarks are cached
    ///     properties, refreshed only when the menu's own handlers run,
    ///     so without this a change made in the window would not show up
    ///     in the menu until the next launch.
    static func show(updater: UpdaterController,
                      defaults: UserDefaults = .standard,
                      onChange: (() -> Void)? = nil) {
        show(updater: updater, defaults: defaults, onChange: onChange, activate: true)
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
    static func show(updater: UpdaterController,
                      defaults: UserDefaults = .standard,
                      onChange: (() -> Void)? = nil,
                      activate: Bool,
                      eventLoggingToggle: @escaping (Bool, UserDefaults) -> Bool = {
                          EventLoggingToggle.apply($0, defaults: $1)
                      }) {
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
                                                  onChange: onChange, eventLoggingToggle: eventLoggingToggle)
        shared = controller
        if activate {
            controller.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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

    private init(updater: UpdaterController, defaults: UserDefaults, onChange: (() -> Void)?,
                eventLoggingToggle: @escaping (Bool, UserDefaults) -> Bool) {
        self.updater = updater
        self.defaults = defaults
        self.onChange = onChange
        self.eventLoggingToggle = eventLoggingToggle
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
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
            title: Self.automaticUpdatesTitle,
            isOn: UpdateSettings.load(defaults).automaticChecksEnabled,
            action: #selector(toggleAutomaticUpdates(_:))))

        stack.addArrangedSubview(checkbox(
            title: Self.crashReportsTitle,
            isOn: CrashReportSettings.load(defaults).enabled,
            action: #selector(toggleCrashReports(_:))))

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

    /// Re-reads all four settings from the store into the checkboxes
    /// (whole-branch review F7).
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
        checkbox(titled: Self.automaticUpdatesTitle)?.state =
            UpdateSettings.load(defaults).automaticChecksEnabled ? .on : .off
        checkbox(titled: Self.crashReportsTitle)?.state =
            CrashReportSettings.load(defaults).enabled ? .on : .off
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
