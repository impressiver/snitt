// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Whether launching Snitt should show the welcome window.
///
/// Opening the app from the Dock or Spotlight with nothing else going on used
/// to land you in an app with no windows and no obvious next step — a menu-bar
/// icon and an empty screen. Showing the welcome window there is the answer
/// to "I launched this and have not said what I want yet": the recents list,
/// the two openers, and the record button are all sitting in one window
/// rather than behind a modal dialog that has to be dismissed before any of
/// them is reachable.
///
/// **Every other way in must NOT get the window**, which is why this is a
/// decision rather than a line of code at launch:
///
/// - Finishing a recording opens the editor itself. A window over it would be
///   in front of the thing the recording was for.
/// - Double-clicking a `.snitt` bundle, `open(1)`, or a drag onto the Dock
///   all arrive as URLs to open — the document IS the answer to "what did you
///   want", and asking again would be absurd.
/// - **§4.11**: the hotkey and the menu-bar item start a recording with no
///   window opening. An app launched into recording must stay silent, and a
///   window that activates the app is a worse violation of that than a modal
///   panel ever was — a panel at least fails obviously; a window stealing
///   focus over a live capture fails quietly, which is harder to notice and
///   harder to forgive.
///
/// Kept pure, in the shape `DockReopen` originally established, so all four
/// of those cases are testable without a real `NSWindow` — which would need
/// a live AppKit run loop a headless test does not have.
enum LaunchOpenPrompt {

    /// Why a launch did or did not show the welcome window. Returned rather
    /// than a bare `Bool` so the reason can be asserted: "did not show it" is
    /// the correct answer to four different situations, and a test that only
    /// checked the boolean would pass on the right answer for the wrong one.
    enum Decision: Equatable {
        case welcome
        case documentAlreadyOpening
        case windowAlreadyOpen
        case recording
        /// An agent's command started the app. Nobody asked for a window, and
        /// one that activates the app would block the main actor that agent
        /// is about to use.
        case agentLaunch
    }

    /// - Parameters:
    ///   - openingDocument: a `.snitt` bundle arrived with the launch — from
    ///     Finder, `open(1)`, or a Dock drop. Note this can arrive either side
    ///     of `applicationDidFinishLaunching`, which is why the caller defers
    ///     the decision by a runloop pass rather than asking immediately.
    ///   - hasVisibleWindows: anything already on screen, including an editor
    ///     that a just-finished recording opened.
    ///   - isRecording: a capture is running or stopping.
    ///   - launchedByAgent: the process was started by an agent's command
    ///     rather than by a person, which `AppLauncher.agentLaunchArgument`
    ///     marks.
    static func decide(openingDocument: Bool,
                       hasVisibleWindows: Bool,
                       isRecording: Bool,
                       launchedByAgent: Bool = false) -> Decision {
        // FIRST, above even recording. The others are about what the app is
        // already doing; this one is about the window being actively
        // harmful: showing it activates the app, which steals the main actor
        // every agent verb that touches a window needs, so the launch that
        // was supposed to make Snitt reachable is what makes it unreachable.
        // `snitt status` keeps answering, because it never hops, which makes
        // the app look alive and the surface look broken.
        //
        // It also steals focus. `offerToOpenADocumentIfLaunchedBare` calls
        // `NSApp.activate(ignoringOtherApps:)` so the window cannot open
        // behind something — correct for a person who double-clicked the
        // app, and exactly wrong for an agent working quietly behind their
        // work.
        if launchedByAgent { return .agentLaunch }
        // Recording next: it is the §4.11 case, and it outranks the rest
        // even if a window happens to be up as well.
        if isRecording { return .recording }
        if openingDocument { return .documentAlreadyOpening }
        if hasVisibleWindows { return .windowAlreadyOpen }
        return .welcome
    }
}
