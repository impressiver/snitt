// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// Which launches get an Open dialog (2026-09-11).
///
/// Opening Snitt from the Dock with nothing else going on used to leave you
/// in an app with no windows and no next step. Offering Open there is the
/// answer — and getting it wrong in the other direction is much worse than
/// leaving it out, which is why each way in is stated separately rather than
/// as one boolean.
@Suite
struct LaunchOpenPromptTests {

    @Test("Launched on its own, with nothing going on, offers Open")
    func bareLaunchPrompts() {
        #expect(LaunchOpenPrompt.decide(openingDocument: false,
                                        hasVisibleWindows: false,
                                        isRecording: false) == .prompt)
    }

    @Test("A recording in progress is never interrupted — §4.11")
    func recordingIsNeverInterrupted() {
        // The one that matters most. The hotkey and the menu-bar item start a
        // recording with NO window opening, and a modal Open panel is the
        // loudest possible way to break that: it would appear over whatever is
        // being demonstrated, in the recording.
        #expect(LaunchOpenPrompt.decide(openingDocument: false,
                                        hasVisibleWindows: false,
                                        isRecording: true) == .recording)
    }

    @Test("Recording outranks everything, even with a window already up")
    func recordingOutranksTheOtherCases() {
        // Ordering, asserted rather than left to the order the `if`s happen to
        // be in: a decision that returned `.windowAlreadyOpen` here would
        // still not prompt, so a boolean-only test could not tell the two
        // apart — and the next person to reorder the checks would not be
        // warned by anything.
        #expect(LaunchOpenPrompt.decide(openingDocument: true,
                                        hasVisibleWindows: true,
                                        isRecording: true) == .recording)
    }

    @Test("Double-clicking a .snitt does not ask what to open")
    func openingADocumentDoesNotPrompt() {
        // Finder, `open(1)` and a Dock drop all arrive as URLs. The document
        // IS the answer to "what did you want".
        #expect(LaunchOpenPrompt.decide(openingDocument: true,
                                        hasVisibleWindows: false,
                                        isRecording: false) == .documentAlreadyOpening)
    }

    @Test("A recording that just finished opens its editor, not a panel")
    func finishingARecordingDoesNotPrompt() {
        // The case named in the request. Capture has stopped — so `isRecording`
        // is already false — and the editor is on screen. A panel over it would
        // be in front of the thing the recording was made for.
        #expect(LaunchOpenPrompt.decide(openingDocument: false,
                                        hasVisibleWindows: true,
                                        isRecording: false) == .windowAlreadyOpen)
    }
}

// Menu validation (2026-09-11).
@Suite(.serialized)
@MainActor
struct ExportMenuValidationTests {
    init() { _ = NSApplication.shared }

    @Test("Export is disabled when no editor is in front")
    func exportDisabledWithNothingOpen() {
        // Reported from use. With no document open the item did nothing when
        // picked — `exportDocument(_:)` resolves its editor from
        // `NSApp.keyWindow` and returns early when there is none — so the menu
        // offered an action and then silently declined it, which reads as a
        // broken app rather than as "nothing is open".
        //
        // No editor windows exist in this host, and no key window, so this is
        // the "launched, nothing open" state exactly.
        let delegate = AppDelegate()
        let item = NSMenuItem(title: "Export…",
                              action: #selector(AppDelegate.exportDocument(_:)),
                              keyEquivalent: "e")
        #expect(delegate.validateMenuItem(item) == false)
    }

    @Test("Validation leaves items it does not own alone")
    func unrelatedItemsStayEnabled() {
        // The guard that keeps this from disabling the rest of the menu bar:
        // an item whose action is not one of the two handled here must come
        // back enabled, not swept up by a broadening condition.
        let delegate = AppDelegate()
        let item = NSMenuItem(title: "Close",
                              action: #selector(NSWindow.performClose(_:)),
                              keyEquivalent: "w")
        #expect(delegate.validateMenuItem(item))
    }
}
