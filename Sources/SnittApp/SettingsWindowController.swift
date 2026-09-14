// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import AppKit
import Carbon.HIToolbox
import SnittAutomation

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
/// D95 adds a sixth checkbox — unattended agent recording — with NO status-item
/// equivalent, deliberately. The menu is the fast path, and this is the
/// opposite of a fast path: it is a grant a person renews about once a month,
/// after reading what it costs. Putting it one click from the menu bar would
/// make a deliberate decision feel like a preference. The single-store
/// discipline still applies — it reads and writes the same `AgentSettings` the
/// menu's agent-recording toggle does.
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
    private let unattendedToggle: (Bool, UserDefaults) -> Bool
    private let hotkeyConflictAlert: @MainActor (HotkeyAction, HotkeyCombination) -> Void
    private let outputDirectoryUnwritableAlert: @MainActor (URL) -> Void
    private var hotkeyButtons: [HotkeyAction: HotkeyRecorderButton] = [:]
    private var outputDirectoryLabel: NSTextField?
    private var unattendedStatusLabel: NSTextField?

    /// Wide enough for an explanation to be a sentence rather than a column
    /// of two-word lines. The 420pt window predated the explanations.
    static let contentWidth: Double = 520

    // Short titles, because each now sits under a section header supplying
    // the noun the old ones carried: "Allow agent recording" under a heading
    // that already says Agent read as a stutter.
    //
    // The full name survives as the ACCESSIBILITY label for both agent rows. A
    // section header is a visual grouping and nothing more — VoiceOver moving
    // between controls announces "Allow recording" with no hint of what it
    // permits, and for the two controls on this window that decide whether
    // software may watch the screen, that is the disclosure failing exactly
    // where it is needed most.
    static let agentRecordingTitle = "Allow recording"
    static let agentRecordingAccessibilityLabel = "Allow agent recording"
    static let unattendedRecordingTitle = "Allow unattended"
    static let unattendedRecordingAccessibilityLabel = "Allow unattended agent recording"
    static let eventLoggingTitle = "Capture events"
    static let microphoneTitle = "Record microphone"
    static let automaticUpdatesTitle = "Check for updates automatically"
    static let crashReportsTitle = "Include crash reports in diagnostics"

    // The explanations (rev 5, W6). Several of these settings cannot be
    // understood from a label alone — what "Allow agent recording" actually
    // permits, what an input event is — and a checkbox has nowhere to say so,
    // which is how a privacy-relevant control ends up looking like a
    // preference. The agent-recording sentence is the consent-relevant one
    // and a test pins it: it is the disclosure, not decoration.
    static let agentRecordingDetail = "Lets Claude Code or Codex start a recording "
        + "without you at the keyboard. Every agent-initiated recording is disclosed "
        + "in the UI and logged."
    // D95. The renewal period is INTERPOLATED, never typed as a literal: the
    // number is the whole point of this sentence — a person plans around it —
    // and a help text that says thirty while the grant expires at forty-five
    // is worse than no help text, because they would leave the machine
    // believing it.
    static let unattendedRecordingDetail = "Confirms Screen Recording now, while you are "
        + "here, so an agent can keep recording after you leave. macOS makes Snitt "
        + "re-confirm about every \(UnattendedRecordingGrant.renewalDays) days and that "
        + "prompt needs a person, so this switches itself off after "
        + "\(UnattendedRecordingGrant.renewalDays) days until you renew it."
    static let eventLoggingDetail = "Records which keys and clicks happened, so "
        + "auto-trim can tell working from idle. Keystrokes are stored as "
        + "content-free beats — never the characters."
    static let microphoneDetail = "Captures the microphone alongside system audio. "
        + "Snitt warns you if your speakers will bleed into the mic."
    static let automaticUpdatesDetail = "Looks for a newer version in the background. "
        + "Nothing is downloaded or installed until you choose it."
    static let crashReportsDetail = "Attaches recent crash logs when you export a "
        + "diagnostics bundle. Nothing is sent anywhere — the bundle is a file you "
        + "choose to share."
    /// The line under the unattended checkbox saying where the grant stands.
    ///
    /// Pure and static so the wording is testable without building a window —
    /// and separate from `unattendedRecordingDetail` because the two answer
    /// different questions: the detail says what the setting DOES and never
    /// changes, this says what it is doing RIGHT NOW and changes daily.
    ///
    /// Empty for `.off`: a status line under an unchecked box would be
    /// describing a grant that does not exist.
    static func unattendedStatusText(for status: UnattendedRecordingGrant.Status) -> String {
        switch status {
        case .off:
            return ""
        case .active(let daysRemaining):
            return "Confirmed. Renew within \(daysRemaining) "
                 + "\(daysRemaining == 1 ? "day" : "days"), while you are at the keyboard."
        case .lapsed(let daysAgo):
            let when = daysAgo == 0 ? "today" : "\(daysAgo) \(daysAgo == 1 ? "day" : "days") ago"
            return "Renewal overdue — it lapsed \(when). Switch it back on to renew."
        }
    }

    /// Section headers.
    ///
    /// "What gets recorded" rather than "Capture", which is what this app calls
    /// everything it does — a heading that could sit over any row on this
    /// window is not a heading. This one names the question its two checkboxes
    /// answer: the screen is always recorded, and these decide what goes in
    /// alongside it.
    static let captureSectionTitle = "What gets recorded"
    static let agentSectionTitle = "Agent"
    static let updatesSectionTitle = "Updates & Diagnostics"
    static let shortcutsSectionTitle = "Keyboard Shortcuts"

    /// Named for exactly what it governs.
    ///
    /// It was briefly "Default path", which read as the app's one folder for
    /// everything. It is not: `RecordingCoordinator` is its only consumer, so
    /// this is where RECORDINGS land and nothing else. Export deliberately
    /// does not consult it — `defaultExportURL(forBundle:)` puts an export
    /// beside the bundle it came from, "because a `.snitt` bundle already
    /// lives where its owner put it". With this folder unchanged the two
    /// coincide, which is what made the broader name look true.
    ///
    /// A noun phrase, like every other heading on this window, rather than the
    /// original "Save recordings to" — a sentence fragment left hanging over a
    /// path and a button.
    static let outputDirectoryCaption = "Recordings folder"
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
    /// `unattendedToggle` mirrors both (D95): production forwards to
    /// `UnattendedRecordingToggle.apply`, which runs the real Screen Recording
    /// ladder — a real modal and real per-machine TCC state. A test
    /// substitutes a fake, because a headless runner does not fail on
    /// `NSAlert.runModal()`, it HANGS.
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
                      unattendedToggle: @escaping (Bool, UserDefaults) -> Bool = {
                          UnattendedRecordingToggle.apply($0, defaults: $1)
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
                                                  unattendedToggle: unattendedToggle,
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
                unattendedToggle: @escaping (Bool, UserDefaults) -> Bool,
                hotkeyConflictAlert: @escaping @MainActor (HotkeyAction, HotkeyCombination) -> Void,
                outputDirectoryUnwritableAlert: @escaping @MainActor (URL) -> Void) {
        self.updater = updater
        self.defaults = defaults
        self.hotkeyRegistrar = hotkeyRegistrar
        self.onChange = onChange
        self.eventLoggingToggle = eventLoggingToggle
        self.microphoneToggle = microphoneToggle
        self.unattendedToggle = unattendedToggle
        self.hotkeyConflictAlert = hotkeyConflictAlert
        self.outputDirectoryUnwritableAlert = outputDirectoryUnwritableAlert
        // Height 0: `sizeToFitContent` below replaces it with what the
        // content actually needs. A guessed height is how the first version
        // ended up several hundred points taller than its rows, which the
        // stack then had to put somewhere.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                              width: Self.contentWidth, height: 0),
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
        super.init()
        window.delegate = self
        let content = makeContentView()
        window.contentView = content
        // One place decides whether the sub-option is live, and this is the
        // call that makes the WINDOW AS BUILT agree with it. `unattendedRow`
        // sets the checkmark from the same grant, but `isEnabled` depends on
        // the parent opt-in, and a row that only learned that on the next
        // toggle would open fully clickable over a permission it cannot grant.
        // It has to run here rather than inside `makeContentView`, because
        // `checkbox(titled:)` searches `window.contentView` and that is the
        // line above.
        refreshUnattendedStatus()
        // Fit the window to the rows, then centre — in that order, or it
        // centres the wrong size and jumps.
        let fitted = content.fittingSize
        window.setContentSize(NSSize(width: Self.contentWidth,
                                     height: max(fitted.height, 1)))
        window.center()
    }

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        // No `distribution` setting here on purpose. The first fix for the
        // stretched-row bug set `.fill`, and a mutant swapping it for
        // `.fillEqually` survived every test — because once the window is
        // sized to its content (below) there is no spare height for any
        // distribution to distribute. The window's height was the whole
        // defect; the stack was only where it showed.
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Application-wide, at the top with no header of their own: a heading
        // saying "Application" over the first thing in an app's Settings
        // window is a heading saying "Settings".
        //
        // The default path leads because it is the one row that is neither a
        // permission nor a preference — it is where the app puts things, and
        // somebody who came here looking for it is usually looking for it
        // first.
        // Both keep their own headings; what they do NOT get is an
        // "Application" one above them. `leadingRule: false` on the first,
        // because a hairline across the very top of the window is a rule
        // dividing a heading from the title bar.
        addGroup(to: stack, titled: Self.outputDirectoryCaption,
                 rows: [outputDirectoryRow()], leadingRule: false)
        addGroup(to: stack, titled: Self.shortcutsSectionTitle,
                 rows: [HotkeyAction.record, .marker].map(hotkeyRow(for:)))

        // Then the checkboxes, grouped by what the setting is ABOUT: what
        // Snitt captures, what an agent may do, and what leaves the machine.
        // Six ungrouped checkboxes in a column made "Allow agent recording" —
        // the one with real consequences — look like the same sort of thing as
        // "Check for updates automatically".
        addGroup(to: stack, titled: Self.captureSectionTitle, rows: [
            settingRow(title: Self.microphoneTitle, detail: Self.microphoneDetail,
                       isOn: MicrophoneSettings.load(defaults).enabled,
                       action: #selector(toggleMicrophone(_:))),
            settingRow(title: Self.eventLoggingTitle, detail: Self.eventLoggingDetail,
                       isOn: EventLoggingSettings.load(defaults).enabled,
                       action: #selector(toggleEventLogging(_:))),
        ])
        addGroup(to: stack, titled: Self.agentSectionTitle, rows: [
            settingRow(title: Self.agentRecordingTitle, detail: Self.agentRecordingDetail,
                       isOn: AgentSettings.load(defaults).agentRecordingEnabled,
                       action: #selector(toggleAgentRecording(_:)),
                       accessibilityLabel: Self.agentRecordingAccessibilityLabel),
            unattendedRow(),
        ])
        addGroup(to: stack, titled: Self.updatesSectionTitle, rows: [
            settingRow(title: Self.automaticUpdatesTitle, detail: Self.automaticUpdatesDetail,
                       isOn: UpdateSettings.load(defaults).automaticChecksEnabled,
                       action: #selector(toggleAutomaticUpdates(_:))),
            settingRow(title: Self.crashReportsTitle, detail: Self.crashReportsDetail,
                       isOn: CrashReportSettings.load(defaults).enabled,
                       action: #selector(toggleCrashReports(_:))),
        ])

        return stack
    }

    /// A titled group, under a rule, with the air a rule needs on both sides.
    ///
    /// The spacing is the whole of this function. A separator inheriting the
    /// stack's row spacing sits almost touching the heading under it and the
    /// paragraph above it, which reads as a line that fell over rather than as
    /// a division — the screenshot that prompted this showed exactly that.
    /// The space on each side of a group's rule.
    ///
    /// ONE constant used for both sides, so they cannot drift apart. They were
    /// 20 above and 10 below, on the reasoning that a heading belongs to what
    /// follows it. Measured on the laid-out window that came out as 18 and 8 —
    /// an `NSBox` separator is 5pt tall with its hairline centred, so each gap
    /// loses about 2pt to the box itself — and the rule visibly sat twice as
    /// far from the content above it as from the heading below it.
    static let ruleMargin: Double = 16

    private func addGroup(to stack: NSStackView, titled title: String,
                          rows: [NSView], leadingRule: Bool = true) {
        if leadingRule {
            let rule = separator()
            stack.addArrangedSubview(rule)
            stack.setCustomSpacing(Self.ruleMargin, after: rule)
        }

        let header = groupHeader(title)
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)

        addRows(to: stack, rows)
    }

    /// Rows with no header — the top-of-window group, and the body of every
    /// headed one, so the spacing rule lives in a single place.
    ///
    /// `rowSpacing` rather than the stack's own 2: a checkbox row is a
    /// checkbox stacked on its own explanation, so the gap BETWEEN two settings
    /// has to clear the gap inside one, or the explanation reads as belonging
    /// to the box underneath it.
    static let rowSpacing: Double = 14

    private func addRows(to stack: NSStackView, _ rows: [NSView]) {
        for row in rows {
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(Self.rowSpacing, after: row)
        }
        // The other half of the rule's margin. The same constant as the gap
        // below it, which is the whole point: a divider with more air on one
        // side than the other reads as belonging to the group it sits nearer.
        if let last = rows.last { stack.setCustomSpacing(Self.ruleMargin, after: last) }
    }

    /// A hairline the full width of the content, so a group reads as a group.
    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth - 40).isActive = true
        return line
    }

    private func groupHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// A named hotkey and its recorder, on one line.
    ///
    /// The recorder button used to carry the name itself ("Record hotkey:
    /// ⌥⌘5"), so the control was as wide as its own label and the two hotkeys
    /// were two differently-sized buttons floating in the margin. Name on the
    /// left, control on the right, both of them aligned with everything else.
    private func hotkeyRow(for action: HotkeyAction) -> NSView {
        let label = NSTextField(labelWithString: action.label)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let row = NSStackView(views: [label, hotkeyRecorderButton(for: action)])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    /// One setting: a bold label, and underneath it the sentence that says
    /// what turning it on actually does (rev 5, W6).
    ///
    /// The explanation is reachable without eyes as well as with them — set as
    /// the checkbox's accessibility help AND left as a real static text in the
    /// hierarchy. A subtitle that exists only as pixels tells a VoiceOver user
    /// nothing, which for the agent-recording row would mean the disclosure is
    /// not disclosed.
    ///
    /// - Parameter accessibilityLabel: what VoiceOver announces INSTEAD of the
    ///   visible title, for rows whose titles were shortened because a section
    ///   header now carries their noun. Nil leaves the title, which is right
    ///   whenever the title already stands on its own.
    func settingRow(title: String, detail: String,
                    isOn: Bool, action: Selector,
                    accessibilityLabel: String? = nil) -> NSView {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.setAccessibilityHelp(detail)
        if let accessibilityLabel { button.setAccessibilityLabel(accessibilityLabel) }

        let explanation = NSTextField(wrappingLabelWithString: detail)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = Self.contentWidth - 60
        explanation.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [button, explanation])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        NSLayoutConstraint.activate([
            // Hangs under the title rather than under the box, so the two
            // read as one thing.
            explanation.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            explanation.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.contentWidth - 60),
        ])
        return row
    }

    private func checkbox(title: String, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        return button
    }

    /// Test-only: looks a checkbox up by its title so a test can simulate a
    /// click without reaching into `NSStackView` internals.
    func checkbox(titled title: String) -> NSButton? {
        // Searches the whole tree, not just the top row. Each setting is
        // now a small stack — checkbox plus its explanation (rev 5, W6) —
        // so a direct-children scan finds nothing and every test that
        // reaches a checkbox through here goes quietly nil.
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for child in view.subviews {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        return window.contentView.flatMap(find)
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

        // No caption here: the group header above the row carries it, and two
        // labels reading "Default path" one above the other is what the first
        // version of this grouping shipped.

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

    /// D95's row: the standard checkbox-plus-explanation, with a third line
    /// underneath saying where the grant stands today.
    ///
    /// The checkbox reads the STATUS, not the stored flag. A grant that has
    /// lapsed shows unchecked, because it is authorizing nothing — the same
    /// rule `EventLoggingToggle`'s history states for a refused grant: a
    /// checkmark on a feature that cannot produce anything is the lie. The
    /// status line underneath is what stops that reading as the setting having
    /// forgotten itself.
    private func unattendedRow() -> NSView {
        let status = AgentSettings.load(defaults).unattendedGrant.status(now: Date())
        let row = settingRow(title: Self.unattendedRecordingTitle,
                             detail: Self.unattendedRecordingDetail,
                             isOn: status.isActive,
                             action: #selector(toggleUnattendedRecording(_:)),
                             accessibilityLabel: Self.unattendedRecordingAccessibilityLabel)

        let label = NSTextField(wrappingLabelWithString: Self.unattendedStatusText(for: status))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = Self.contentWidth - 60
        unattendedStatusLabel = label

        if let stack = row as? NSStackView {
            stack.addArrangedSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth - 60),
            ])
        }
        // Indented under "Allow recording", because it is subordinate to it
        // rather than beside it: `AgentSettings.unattendedGrant` composes the
        // two, so this one authorizes nothing on its own. Two checkboxes at
        // the same indent read as two independent permissions, which is the
        // one thing this pair is not.
        return Self.indenting(row, by: Self.subOptionIndent)
    }

    /// How far a sub-option sits in from its parent.
    ///
    /// Aligned with the parent's own explanation text, which hangs 20pt in
    /// from the checkbox — so the child lines up with the sentence explaining
    /// what it is a child OF, rather than at some indent of its own.
    static let subOptionIndent: Double = 20

    /// `row`, shifted right, without touching the constraints inside it.
    ///
    /// A wrapper rather than `edgeInsets` on the row itself: the rows here
    /// pin their own subviews to their own `leadingAnchor`, and an inset would
    /// leave those constraints fighting the stack's layout for the same edge —
    /// ambiguous rather than wrong, which is the kind that renders fine until
    /// it does not.
    private static func indenting(_ row: NSView, by inset: Double) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: inset).isActive = true
        let wrapper = NSStackView(views: [spacer, row])
        wrapper.orientation = .horizontal
        wrapper.alignment = .top
        wrapper.spacing = 0
        return wrapper
    }

    @objc private func toggleUnattendedRecording(_ sender: NSButton) {
        // Through the ladder, exactly like event logging and the microphone —
        // and for a reason specific to this one: turning it on is the ONLY
        // moment a person is guaranteed to be present, so it is the only
        // moment the Screen Recording grant can be confirmed. `apply` returns
        // the state actually reached, which is `false` whenever the grant is
        // refused, and the checkbox is set back to match.
        let applied = unattendedToggle(sender.state == .on, defaults)
        sender.state = applied ? .on : .off
        refreshUnattendedStatus()
        onChange?()
    }

    private func refreshUnattendedStatus() {
        let settings = AgentSettings.load(defaults)
        let status = settings.unattendedGrant.status(now: Date())
        unattendedStatusLabel?.stringValue = Self.unattendedStatusText(for: status)
        // DISABLED when the parent opt-in is off, not merely unchecked. An
        // enabled-looking checkbox that cannot be turned on is a control that
        // lies about what it will do — and turning this on while agent
        // recording is off would run the whole Screen Recording ladder, ask a
        // person for a permission, and then authorize nothing.
        unattendedStatusLabel?.isHidden = !settings.agentRecordingEnabled
        checkbox(titled: Self.unattendedRecordingTitle)?.isEnabled = settings.agentRecordingEnabled
        checkbox(titled: Self.unattendedRecordingTitle)?.state = status.isActive ? .on : .off
    }

    @objc private func toggleAgentRecording(_ sender: NSButton) {
        var settings = AgentSettings.load(defaults)
        settings.agentRecordingEnabled = (sender.state == .on)
        settings.save(to: defaults)
        // §5.3's opt-in is what D95's grant hangs off, so turning it off
        // withdraws unattended recording as well. Only the DISPLAY is updated
        // here: `unattendedGrant` composes the two flags, so there is no second
        // stored value that could be left disagreeing with this one.
        refreshUnattendedStatus()
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

    /// Re-reads all six checkbox settings, both hotkeys, and the output
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
        // Reads the STATUS, not the stored flag — a grant that lapsed while
        // this window sat open must come back unchecked, and the line under it
        // must say why.
        refreshUnattendedStatus()
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
        // The keys alone. The row beside this carries the name now, and a
        // button reading "Record hotkey: ⌥⌘5" next to a label reading
        // "Record hotkey" says it twice and makes the two recorders different
        // widths for no reason.
        title = combination.displayString
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
