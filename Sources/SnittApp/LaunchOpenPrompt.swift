// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Whether launching Snitt should offer an Open dialog.
///
/// Opening the app from the Dock or Spotlight with nothing else going on used
/// to land you in an app with no windows and no obvious next step — a menu-bar
/// icon and an empty screen. Offering Open there is the answer to "I launched
/// this to work on a recording".
///
/// **Every other way in must NOT get the dialog**, which is why this is a
/// decision rather than a line of code at launch:
///
/// - Finishing a recording opens the editor itself. A panel over it would be
///   in front of the thing the recording was for.
/// - Double-clicking a `.snitt` bundle, `open(1)`, or a drag onto the Dock
///   all arrive as URLs to open — the document IS the answer to "what did you
///   want", and asking again would be absurd.
/// - **§4.11**: the hotkey and the menu-bar item start a recording with no
///   window opening. An app launched into recording must stay silent, and a
///   modal Open panel is the loudest possible violation of that.
///
/// Kept pure, in the shape `DockReopen` already established, so all four of
/// those cases are testable without an `NSOpenPanel` — which would block a
/// headless run on user input that never comes.
enum LaunchOpenPrompt {

    /// Why a launch did or did not get the dialog. Returned rather than a
    /// bare `Bool` so the reason can be asserted: "did not prompt" is the
    /// correct answer to four different situations, and a test that only
    /// checked the boolean would pass on the right answer for the wrong one.
    enum Decision: Equatable {
        case prompt
        case documentAlreadyOpening
        case windowAlreadyOpen
        case recording
    }

    /// - Parameters:
    ///   - openingDocument: a `.snitt` bundle arrived with the launch — from
    ///     Finder, `open(1)`, or a Dock drop. Note this can arrive either side
    ///     of `applicationDidFinishLaunching`, which is why the caller defers
    ///     the decision by a runloop pass rather than asking immediately.
    ///   - hasVisibleWindows: anything already on screen, including an editor
    ///     that a just-finished recording opened.
    ///   - isRecording: a capture is running or stopping.
    static func decide(openingDocument: Bool,
                       hasVisibleWindows: Bool,
                       isRecording: Bool) -> Decision {
        // Recording first: it is the §4.11 case, and it outranks the others
        // even if a window happens to be up as well.
        if isRecording { return .recording }
        if openingDocument { return .documentAlreadyOpening }
        if hasVisibleWindows { return .windowAlreadyOpen }
        return .prompt
    }
}
