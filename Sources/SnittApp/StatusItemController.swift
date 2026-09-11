// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import SnittCapture

public enum RecordingState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    /// An agent paused this recording (M5e, D53). A distinct state rather than
    /// a flag on `.recording`, because §5.3's indicator obligation is about
    /// what a PERSON can tell at a glance: "recording" and "paused but still
    /// holding the camera" are different situations, and D53 names a human at
    /// the machine as the only fallback when an agent forgets to resume.
    case paused(startedAt: Date, pausedSeconds: Double)
    case stopping
}

public extension RecordingState {
    /// Seconds of FOOTAGE captured so far — wall clock minus any time spent
    /// paused.
    ///
    /// Lives on the state rather than in either surface that shows it. The
    /// menu-bar item and the recording HUD both display an elapsed time, and
    /// two implementations of this arithmetic would be two clocks wearing one
    /// name: the menu bar says 0:42, the HUD says 0:51, and neither is
    /// obviously the wrong one. Same discipline as the settings surfaces
    /// reading one `UserDefaults` rather than each keeping their own.
    ///
    /// The paused case subtracts deliberately: a counter that kept climbing
    /// while nothing was being filmed would say the recording is fine when it
    /// is frozen.
    func footageSeconds(at now: Date) -> Double {
        switch self {
        case .idle: return 0
        case .recording(let startedAt): return max(0, now.timeIntervalSince(startedAt))
        case .paused(let startedAt, let pausedSeconds):
            return max(0, now.timeIntervalSince(startedAt) - pausedSeconds)
        case .stopping: return 0
        }
    }

    /// `0:42`, and the one format both surfaces use.
    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

public struct StatusItemPresentation: Equatable {
    public var symbolName: String
    public var title: String
    public var isStopEnabled: Bool
    /// What to tint the glyph, or nil to leave it a template that follows the
    /// menu bar's own appearance (rev 5, W8).
    ///
    /// Colour is the SECOND channel here, never the only one: the glyph
    /// already differs per state (`record.circle` / `stop.circle.fill` /
    /// `pause.circle.fill` / `stop.circle`), and it still does. The tint is
    /// what makes "this machine is recording right now" legible in a crowded
    /// menu bar at a glance, without asking anyone to tell two small circles
    /// apart — and it degrades to the shipped behaviour for anyone who cannot
    /// separate the hues.
    public var tint: NSColor?
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
                                          isStopEnabled: false,
                                          tint: nil)
        case .recording:
            return StatusItemPresentation(symbolName: "stop.circle.fill",
                                          title: RecordingState.clock(state.footageSeconds(at: now)),
                                          isStopEnabled: true,
                                          tint: SnittPalette.recordRed)
        case .paused:
            // The FOOTAGE, not the wall clock — see `footageSeconds(at:)`,
            // which both this and the HUD now read. The word "Paused" carries
            // the state; a filled circle would read as still recording.
            return StatusItemPresentation(symbolName: "pause.circle.fill",
                                          title: "Paused " + RecordingState.clock(state.footageSeconds(at: now)),
                                          isStopEnabled: true,
                                          // Amber, not red: a paused recording is not
                                          // recording, and the menu bar should not claim
                                          // it is. Distinct from both the live red and
                                          // the untinted idle state.
                                          tint: SnittPalette.signal)
        case .stopping:
            return StatusItemPresentation(symbolName: "stop.circle",
                                          title: "Saving…",
                                          isStopEnabled: false,
                                          tint: nil)
        }
    }

    /// The menu-bar title, with digits that do not change width.
    ///
    /// Separate and `nonisolated` so the choice is assertable without a menu
    /// bar to hang it on — the title is the only part of this controller that
    /// changes twenty times a minute, and the only part where a font choice
    /// is visible as movement rather than as typography.
    nonisolated static func attributedTitle(_ title: String) -> NSAttributedString {
        guard !title.isEmpty else { return NSAttributedString(string: "") }
        let size = NSFont.systemFontSize
        return NSAttributedString(
            string: " " + title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size,
                                                                 weight: .regular)])
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

    /// The speaker-bleed warning to show, or nil when there is nothing to warn
    /// about (D73).
    ///
    /// Separated from the menu because a menu item is untestable and this
    /// decision is not. `captureSystemAudio` is read from `CaptureOptions`'s
    /// own default rather than written as `true` here: that default is what
    /// `RecordingCoordinator.humanCaptureOptions` actually leaves in place, and
    /// duplicating it as a literal is how the warning would keep firing after
    /// someone made system audio opt-in.
    nonisolated static func speakerBleedWarning(route: AudioOutputRoute,
                                                microphoneEnabled: Bool) -> String? {
        guard AudioOutputRoute.bleedRisk(
            route: route,
            capturingMicrophone: microphoneEnabled,
            capturingSystemAudio: CaptureOptions().captureSystemAudio)
        else { return nil }
        return "⚠︎ Speakers will be recorded by the mic — use headphones"
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

        // D73. Built here rather than cached because this menu is constructed
        // fresh on every right-click, so it reflects whatever is plugged in at
        // the moment someone is about to record — which is the only moment the
        // warning is worth anything.
        if let warning = Self.speakerBleedWarning(route: AudioOutputRoute.current(),
                                                  microphoneEnabled: microphoneEnabled) {
            let item = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
            // Informational, not actionable: there is nothing for Snitt to DO
            // about it, and §4.11 forbids putting a dialog in front of the
            // fast path. Telling the truth at the moment of the decision is
            // the whole intervention.
            item.isEnabled = false
            menu.addItem(item)
        }

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
        // nil restores the template, which follows the menu bar's own light
        // or dark appearance — so idle and "Saving…" look exactly as they did.
        button.contentTintColor = p.tint
        // Tabular digits (rev 5, W9). The menu-bar title is a running clock,
        // and in the proportional system font every tick changes the width of
        // the whole item — so the icon and everything left of it twitch once a
        // second, for the entire length of a recording. A monospaced-digit
        // font at the same size fixes the width without looking different.
        button.attributedTitle = Self.attributedTitle(p.title)
    }
}
