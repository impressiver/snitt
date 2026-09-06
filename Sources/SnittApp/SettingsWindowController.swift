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
    static func show(updater: UpdaterController,
                      defaults: UserDefaults = .standard,
                      onChange: (() -> Void)? = nil,
                      activate: Bool) {
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
        let controller = SettingsWindowController(updater: updater, defaults: defaults, onChange: onChange)
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

    private init(updater: UpdaterController, defaults: UserDefaults, onChange: (() -> Void)?) {
        self.updater = updater
        self.defaults = defaults
        self.onChange = onChange
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
        window.title = "Settings"
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
        EventLoggingSettings(enabled: sender.state == .on).save(to: defaults)
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

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
