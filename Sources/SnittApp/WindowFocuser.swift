// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import SnittCapture

/// Brings the target's application forward before capture starts (§4.13).
///
/// **Limitation, deliberate.** §4.13 asks Snitt to bring the chosen *window*
/// to the front and activate its application. This raises only the
/// application half: fronting one specific window among several requires
/// `AXUIElement`, which needs the Accessibility TCC grant — broader than
/// anything in §4.10's permission ladder, and one this milestone is not
/// allowed to add. Activating the application is free and needs no grant.
///
/// So: the target's app comes forward; if it has several windows, the one
/// macOS fronts may not be the captured one. Recording is unaffected either
/// way — ScreenCaptureKit captures occluded windows correctly (§4.13) — only
/// the "watchable first frames" goal is partly met. Raising the exact window
/// is deferred to whenever Accessibility is on the table.
///
/// Focus happens BEFORE `startCapture`, never after: activating a window can
/// dismiss a menu, close a popover, or move a focus ring, and that transition
/// must not be the first thing in the recording (§4.13).
public struct WindowFocuser: Sendable {
    private let activate: @Sendable (pid_t) -> Bool

    public init(activate: @Sendable @escaping (pid_t) -> Bool) {
        self.activate = activate
    }

    /// Activates via `NSRunningApplication`, which needs no permission grant.
    public static let system = WindowFocuser { pid in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    /// Returns whether anything was actually activated.
    ///
    /// Displays never auto-focus — there is nothing to bring forward — and a
    /// window with no owning process is skipped rather than guessed at.
    public func focus(descriptor: CaptureTargetDescriptor) -> Bool {
        guard descriptor.kind == CaptureTargetDescriptor.Kind.window.rawValue else {
            return false
        }
        guard let pid = descriptor.processID else { return false }
        return activate(pid)
    }
}
