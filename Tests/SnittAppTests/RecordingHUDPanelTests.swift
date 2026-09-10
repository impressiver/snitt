// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// The recording HUD's window behaviour.
///
/// §4.11 is binding: the hotkey and the menu-bar item start a recording with
/// NO window opening and no focus stolen. The HUD *is* a window, so it earns
/// its place only by never doing what that rule protects against. Each
/// property below is asserted on its own rather than trusting the initialiser
/// — every one of them is a single line away from breaking the constraint, and
/// a HUD that stole focus mid-recording would put the interruption INTO the
/// recording, where the user finds it afterwards.
@Suite(.serialized)
@MainActor
struct RecordingHUDPanelTests {
    init() { _ = NSApplication.shared }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("The HUD can never become key — §4.11")
    func neverBecomesKey() {
        // The single most important assertion in this file. `canBecomeKey`
        // returning true takes the keyboard from whatever is being recorded.
        #expect(RecordingHUDPanel().canBecomeKey == false)
    }

    @Test("The HUD can never become main — §4.11")
    func neverBecomesMain() {
        #expect(RecordingHUDPanel().canBecomeMain == false)
    }

    @Test("The HUD is a non-activating panel, so clicking it does not raise Snitt")
    func isNonActivating() {
        // Without `.nonactivatingPanel`, pressing Mark brings Snitt forward
        // and pushes the app being demonstrated behind it — visible in the
        // finished recording.
        #expect(RecordingHUDPanel().styleMask.contains(.nonactivatingPanel))
    }

    @Test("The HUD is not released when closed")
    func isNotReleasedWhenClosed() {
        // The property defaults to TRUE for a programmatically created window,
        // which is an over-release under ARC. A shipped v0.1.0 crash came from
        // exactly this on the Settings window; `WindowLifetimeTests` exists
        // because it was a default nobody overrode, and this is a third window
        // that would inherit it the same way.
        #expect(RecordingHUDPanel().isReleasedWhenClosed == false)
    }

    @Test("The HUD floats above full-screen apps and follows across Spaces")
    func staysVisibleOverTheSubject() {
        // You are usually recording something running full screen. A HUD
        // hidden behind the subject is a HUD that does not exist, and a HUD
        // that stays on Space 1 while you demonstrate on Space 2 is the same
        // failure with extra steps.
        let panel = RecordingHUDPanel()
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.level.rawValue > NSWindow.Level.normal.rawValue)
    }

    @Test("The HUD survives Snitt losing focus")
    func doesNotHideOnDeactivate() {
        // The recording keeps running when Snitt is not frontmost — that is
        // the normal case, not an edge one. A HUD that vanished with the app's
        // activation would disappear the instant you clicked the thing you are
        // recording.
        #expect(RecordingHUDPanel().hidesOnDeactivate == false)
    }

    @Test("Applying an idle presentation takes the HUD off screen")
    func idleOrdersOut() {
        let panel = RecordingHUDPanel()
        panel.apply(RecordingHUDModel.presentation(for: .recording(startedAt: start),
                                                   now: start.addingTimeInterval(5)))
        #expect(panel.isVisible)
        panel.apply(RecordingHUDModel.presentation(for: .idle, now: start))
        #expect(panel.isVisible == false)
    }

    @Test("The view shows what the model decided, not its own opinion")
    func viewMirrorsTheModel() {
        let panel = RecordingHUDPanel()
        panel.apply(RecordingHUDModel.presentation(
            for: .paused(startedAt: start, pausedSeconds: 40),
            now: start.addingTimeInterval(100)))
        #expect(panel.contentForTesting.clockForTesting == "1:00")
        #expect(panel.contentForTesting.statusForTesting == "Paused")
    }

    @Test("Saving disables every control")
    func savingDisablesControls() {
        let panel = RecordingHUDPanel()
        panel.apply(RecordingHUDModel.presentation(for: .stopping, now: start))
        let enabled = panel.contentForTesting.enabledForTesting
        #expect(enabled == (mark: false, pause: false, stop: false))
    }

    @Test("Paused is readable without colour: the dot goes hollow")
    func pausedChangesShape() {
        // Asserting the SHAPE, not the tint. Someone who cannot separate red
        // from grey still has to be able to tell a frozen recording from a
        // running one.
        let panel = RecordingHUDPanel()
        panel.apply(RecordingHUDModel.presentation(for: .recording(startedAt: start), now: start))
        #expect(panel.contentForTesting.dotIsHollowForTesting == false)
        panel.apply(RecordingHUDModel.presentation(
            for: .paused(startedAt: start, pausedSeconds: 0), now: start))
        #expect(panel.contentForTesting.dotIsHollowForTesting)
    }

    @Test("The pause control renames itself to Resume when paused")
    func pauseButtonBecomesResume() {
        // A VoiceOver user hears the button's label. One that still said
        // "Pause" while paused would describe the opposite of what it does.
        let panel = RecordingHUDPanel()
        panel.apply(RecordingHUDModel.presentation(for: .recording(startedAt: start), now: start))
        #expect(panel.contentForTesting.pauseLabelForTesting.hasPrefix("Pause"))
        panel.apply(RecordingHUDModel.presentation(
            for: .paused(startedAt: start, pausedSeconds: 0), now: start))
        #expect(panel.contentForTesting.pauseLabelForTesting.hasPrefix("Resume"))
    }

    @Test("Labels name the user's REAL bindings, not a hard-coded default")
    func labelsNameConfiguredShortcuts() {
        // The HUD cannot be tabbed to, so the hotkey IS the keyboard path and
        // the label is where it gets discovered. Hard-coding "⌥⌘M" would lie
        // to anyone who changed the binding — and D55 exists precisely because
        // these are configurable.
        let panel = RecordingHUDPanel(shortcuts: .init(mark: "⌃⌥1", pause: nil, stop: "⌃⌥2"))
        panel.apply(RecordingHUDModel.presentation(for: .recording(startedAt: start), now: start))
        let labels = panel.contentForTesting.accessibilityLabelsForTesting
        #expect(labels[0].contains("⌃⌥1"))
        #expect(labels[2].contains("⌃⌥2"))
    }

    @Test("A control with no shortcut claims none")
    func unboundControlClaimsNothing() {
        // Pause has no hotkey yet. A label reading "Pause recording, ⌥⌘P"
        // would send a keyboard user to a key that does nothing, which is
        // worse than admitting the control is pointer-only.
        let panel = RecordingHUDPanel(shortcuts: .init(mark: "⌃⌥1", pause: nil, stop: "⌃⌥2"))
        panel.apply(RecordingHUDModel.presentation(for: .recording(startedAt: start), now: start))
        #expect(panel.contentForTesting.pauseLabelForTesting == "Pause recording")
    }

    @Test("Every control still carries a non-empty label")
    func everyControlIsLabelled() {
        let panel = RecordingHUDPanel()
        panel.apply(RecordingHUDModel.presentation(for: .recording(startedAt: start), now: start))
        #expect(panel.contentForTesting.accessibilityLabelsForTesting.allSatisfy { !$0.isEmpty })
    }

    @Test("Controls clear the 24pt target floor")
    func controlsMeetTheTargetFloor() {
        // WCAG 2.5.8 AA. The timeline's lanes were raised to 24pt for the same
        // reason; a HUD button is no less a target for being small and pretty.
        let panel = RecordingHUDPanel()
        panel.apply(RecordingHUDModel.presentation(for: .recording(startedAt: start), now: start))
        panel.layoutIfNeeded()
        for size in panel.contentForTesting.buttonSizesForTesting {
            #expect(size.width >= 24 && size.height >= 24, "control is \(size)")
        }
    }

    @Test("Tapping a control runs its handler")
    func handlersFire() {
        let panel = RecordingHUDPanel()
        var marked = false, paused = false, stopped = false
        panel.onMark = { marked = true }
        panel.onTogglePause = { paused = true }
        panel.onStop = { stopped = true }
        let view = panel.contentForTesting
        view.onMark?(); view.onTogglePause?(); view.onStop?()
        #expect(marked && paused && stopped)
    }
}
