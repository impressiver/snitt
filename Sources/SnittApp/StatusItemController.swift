import AppKit
import Foundation

public enum RecordingState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case stopping
}

public struct StatusItemPresentation: Equatable {
    public var symbolName: String
    public var title: String
    public var isStopEnabled: Bool
}

/// Owns the menu-bar item: the recording indicator and the kill switch.
///
/// §5.3 requires a visible indicator for the whole duration of a recording and
/// a control that stops it immediately. Both live here, and both exist before
/// anything can start a recording without a visible window.
///
/// `NSObject` subclass because the click handler is an `@objc` selector target.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private(set) var state: RecordingState = .idle

    /// What the menu-bar item should show. Pure, so it can be tested without UI.
    ///
    /// `nonisolated` deliberately: the class is `@MainActor` because it mutates
    /// AppKit, but this function reads nothing and touches no UI, so isolating it
    /// would force every caller — including tests — onto the main actor for no
    /// safety benefit.
    nonisolated public static func presentation(for state: RecordingState,
                                                now: Date) -> StatusItemPresentation {
        switch state {
        case .idle:
            return StatusItemPresentation(symbolName: "record.circle",
                                          title: "",
                                          isStopEnabled: false)
        case .recording(let startedAt):
            let elapsed = Int(now.timeIntervalSince(startedAt))
            let text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            return StatusItemPresentation(symbolName: "stop.circle.fill",
                                          title: text,
                                          isStopEnabled: true)
        case .stopping:
            return StatusItemPresentation(symbolName: "stop.circle",
                                          title: "Saving…",
                                          isStopEnabled: false)
        }
    }

    /// Invoked when the user clicks the menu-bar item. This is §5.3's kill
    /// switch: a control that stops a recording immediately. Wired by the app
    /// delegate; without it the item would be a display-only indicator and the
    /// safety guarantee would be unmet.
    var onClick: (() -> Void)?

    /// Invoked by the "Quit Snitt" menu item. Routed through the app delegate
    /// rather than calling `NSApp.terminate` here, so an in-flight recording can
    /// be stopped and its bundle finished before the process goes away.
    var onQuit: (() -> Void)?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        // Receive right-clicks as well, so a context menu can be shown WITHOUT
        // assigning `statusItem.menu` — assigning it would replace the button's
        // action entirely, and that action is §5.3's kill switch.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        apply(.idle)
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        onClick?()
    }

    /// Right-click menu. Attached only for the duration of the click, then
    /// detached, so left-click keeps invoking `onClick` (the kill switch).
    private func showContextMenu() {
        guard let statusItem, let button = statusItem.button else { return }

        let menu = NSMenu()
        let agentItem = NSMenuItem(title: "Allow agent recording",
                                   action: #selector(toggleAgentRecording),
                                   keyEquivalent: "")
        agentItem.target = self
        agentItem.state = agentRecordingEnabled ? .on : .off
        menu.addItem(agentItem)

        let eventsItem = NSMenuItem(title: "Log input events",
                                    action: #selector(toggleEventLogging),
                                    keyEquivalent: "")
        eventsItem.target = self
        eventsItem.state = eventLoggingEnabled ? .on : .off
        menu.addItem(eventsItem)

        // §4.10 rung 2 — off by default, the mic prompt is paid only when
        // someone deliberately turns this on. Read at record time (not
        // cached at launch) by `RecordingCoordinator.humanCaptureOptions`,
        // mirroring `eventsItem` above exactly.
        let microphoneItem = NSMenuItem(title: "Record voiceover",
                                        action: #selector(toggleMicrophone),
                                        keyEquivalent: "")
        microphoneItem.target = self
        microphoneItem.state = microphoneEnabled ? .on : .off
        menu.addItem(microphoneItem)

        // §12's opt-in: with this off, `snitt diagnostics export` never reads
        // `~/Library/Logs/DiagnosticReports/` at all. This menu item is the
        // ONLY way a user can ever turn it on — a setting nothing can set is
        // not a setting (M5b).
        let crashReportsItem = NSMenuItem(title: "Include crash reports in diagnostics",
                                          action: #selector(toggleCrashReporting),
                                          keyEquivalent: "")
        crashReportsItem.target = self
        crashReportsItem.state = crashReportingEnabled ? .on : .off
        menu.addItem(crashReportsItem)
        menu.addItem(.separator())

        // A manual check must always be available regardless of the
        // automatic-checks setting — the user clicking this IS the consent
        // §5 requires for an update check to happen at all.
        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…",
                                             action: #selector(checkForUpdatesSelected),
                                             keyEquivalent: "")
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        // Ruling R3's third clause ("turning the setting off must stop
        // future automatic checks") governs nothing without a way to turn
        // it ON in the first place — Sparkle's own permission prompt never
        // appears, because the plist's `SUEnableAutomaticChecks` cold-start
        // default suppresses it permanently (see `startUpdateCycle`'s
        // `shouldPrompt` check). This is the only route by which a user can
        // ever opt in.
        let automaticUpdatesItem = NSMenuItem(title: "Automatically check for updates",
                                              action: #selector(toggleAutomaticUpdateChecks),
                                              keyEquivalent: "")
        automaticUpdatesItem.target = self
        automaticUpdatesItem.state = automaticUpdateChecksEnabled ? .on : .off
        menu.addItem(automaticUpdatesItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Snitt",
                                  action: #selector(quitSelected),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quitSelected() {
        onQuit?()
    }

    /// Invoked when the user selects "Check for Updates…" from the menu.
    var onCheckForUpdates: (() -> Void)?

    @objc private func checkForUpdatesSelected() {
        onCheckForUpdates?()
    }

    /// Mirrors the persisted setting so the menu can show a checkmark.
    var automaticUpdateChecksEnabled = false

    /// Invoked when the user toggles automatic update checks from the menu.
    var onToggleAutomaticUpdateChecks: ((Bool) -> Void)?

    @objc private func toggleAutomaticUpdateChecks() {
        onToggleAutomaticUpdateChecks?(!automaticUpdateChecksEnabled)
    }

    /// Mirrors the persisted setting so the menu can show a checkmark.
    var agentRecordingEnabled = false

    /// Invoked when the user toggles agent recording from the menu.
    var onToggleAgentRecording: ((Bool) -> Void)?

    @objc private func toggleAgentRecording() {
        onToggleAgentRecording?(!agentRecordingEnabled)
    }

    /// Mirrors the persisted setting so the menu can show a checkmark.
    var eventLoggingEnabled = false

    /// Invoked when the user toggles input-event logging from the menu.
    var onToggleEventLogging: ((Bool) -> Void)?

    @objc private func toggleEventLogging() {
        onToggleEventLogging?(!eventLoggingEnabled)
    }

    /// Mirrors the persisted setting so the menu can show a checkmark.
    var microphoneEnabled = false

    /// Invoked when the user toggles microphone capture from the menu.
    var onToggleMicrophone: ((Bool) -> Void)?

    @objc private func toggleMicrophone() {
        onToggleMicrophone?(!microphoneEnabled)
    }

    /// Mirrors the persisted setting so the menu can show a checkmark.
    var crashReportingEnabled = false

    /// Invoked when the user toggles crash-report collection from the menu.
    var onToggleCrashReporting: ((Bool) -> Void)?

    @objc private func toggleCrashReporting() {
        onToggleCrashReporting?(!crashReportingEnabled)
    }

    func update(_ newState: RecordingState) {
        state = newState
        apply(newState)

        timer?.invalidate()
        timer = nil
        if case .recording = newState {
            // Refresh the elapsed-time readout once a second so the indicator
            // is visibly live rather than a static dot. Target/selector, not a
            // closure: `Timer.scheduledTimer`'s closure overload takes a plain
            // `@Sendable` closure in this SDK overlay, which can't touch
            // main-actor state, so this mirrors the button's target/action wiring.
            timer = Timer.scheduledTimer(timeInterval: 1,
                                         target: self,
                                         selector: #selector(tick),
                                         userInfo: nil,
                                         repeats: true)
        }
    }

    @objc private func tick() {
        guard case .recording = state else { return }
        apply(state)
    }

    private func apply(_ state: RecordingState) {
        let p = Self.presentation(for: state, now: Date())
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: p.symbolName,
                               accessibilityDescription: "Snitt")
        button.title = p.title.isEmpty ? "" : " \(p.title)"
    }
}
