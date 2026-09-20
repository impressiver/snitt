// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
import SnittAutomation
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

// NOT TESTED, deliberately, and the reason is worth more than the test was.
//
// The launch prompt never appeared because `hasVisibleWindows` was read from
// `NSApp.windows`, which includes the `NSStatusBarWindow` the menu-bar item
// lives in — present from the moment `statusItem.install()` runs, so every
// launch looked like "something is already open". The decision was right and
// its INPUT was wrong, which is the harder half to see. It now asks
// `EditorWindowController.openEditors`, which is what "a document is open"
// actually means here.
//
// A test demonstrating the false positive was written and removed: it had to
// create a real `NSStatusBar` item, and mutating global UI state while the
// rest of the suite runs in parallel produced an unexplained failure on the
// very next run. A 1452-test suite that fails once in a while is worse than a
// missing demonstration — this project has spent whole sessions chasing
// exactly that, and the field notes say so.

// MARK: - An agent's launch must not open a panel

@Suite("An agent-initiated launch is silent")
struct AgentLaunchPromptTests {

    @Test("An agent's launch does not get the Open dialog")
    func agentLaunchDoesNotPrompt() {
        // WRONG IMPLEMENTATION: the shipped one, which had no notion of who
        // launched the app. Every agent command that found Snitt not running
        // launched it, got a bare launch, and ran a MODAL Open panel — which
        // blocks the MAIN ACTOR. `snitt status` kept answering, because it
        // never hops to it, so the app looked alive while every verb that
        // touches a window timed out. An unattended agent waits there forever.
        //
        // Found by driving the real demo: `snitt targets list` timed out three
        // times in a row against an app that answered `snitt status` instantly.
        #expect(LaunchOpenPrompt.decide(openingDocument: false,
                                        hasVisibleWindows: false,
                                        isRecording: false,
                                        launchedByAgent: true) == .agentLaunch)
    }

    @Test("A person's bare launch still gets it")
    func aPersonStillGetsThePrompt() {
        // THE CONTROL. Suppressing the panel outright would pass the test
        // above and delete a feature people rely on: launching Snitt from the
        // Dock with nothing open is how you get to your recordings.
        #expect(LaunchOpenPrompt.decide(openingDocument: false,
                                        hasVisibleWindows: false,
                                        isRecording: false,
                                        launchedByAgent: false) == .prompt)
    }

    @Test("The agent's launch outranks every other reason, including recording")
    func agentLaunchOutranksTheRest() {
        // WRONG IMPLEMENTATION: checking `launchedByAgent` last, after the
        // three existing reasons. The others describe what the app is already
        // doing; this one says the panel is actively harmful, so it cannot sit
        // downstream of a condition that merely happens to be false.
        //
        // Recording is the sharpest instance: an agent that starts a recording
        // on a cold launch would race the panel against its own capture, and
        // which reason won would depend on how fast the coordinator answered.
        #expect(LaunchOpenPrompt.decide(openingDocument: true,
                                        hasVisibleWindows: true,
                                        isRecording: true,
                                        launchedByAgent: true) == .agentLaunch)
    }

    @Test("The launch command carries the flag the app reads")
    func theLaunchCommandCarriesTheFlag() {
        // WRONG IMPLEMENTATION: teaching the app to read a flag nothing sends.
        // Both halves have to agree or the fix is decorative, and the app half
        // would still LOOK right in review. This is the half that is easy to
        // forget, because the app-side tests above pass without it.
        let command = AppLauncher.launchCommand(
            for: URL(fileURLWithPath: "/Applications/Snitt.app"))
        #expect(command.contains(AppLauncher.agentLaunchArgument),
                "the launcher must send what the app reads: \(command)")
        // `--args` must come before it, or `open` treats it as its own flag
        // and refuses the launch entirely.
        guard let argsIndex = command.firstIndex(of: "--args"),
              let flagIndex = command.firstIndex(of: AppLauncher.agentLaunchArgument) else {
            Issue.record("expected --args and the flag in \(command)"); return
        }
        #expect(argsIndex < flagIndex, "--args must precede the flag: \(command)")
        #expect(command.contains("-g"),
                "an agent's launch stays in the background: \(command)")
    }
}
