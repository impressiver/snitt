// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreGraphics

/// The one place Snitt asks for Input Monitoring (§4.10's third rung).
///
/// Mirrors `ScreenRecordingAccess` deliberately: preflight READS the grant,
/// request RAISES the dialog. Code that only preflights silently measures
/// nothing — a mistake made three times in this project before each service
/// was given a single home and a conformance test.
///
/// Spike S1 established that this is the grant `CGEventTap` needs
/// (`kTCCServiceListenEvent`), and that `NSEvent.addGlobalMonitorForEvents`
/// is gated by **Accessibility** instead — a broader grant, and one users
/// refuse more often. S1 measured global NSEvent keyDown at ZERO even with
/// Input Monitoring granted, which is why this API is not optional.
///
/// As with Screen Recording, a request returns `false` the first time even
/// when the user grants it; the grant takes effect on the next launch.
public enum InputMonitoringAccess {
    /// Reads the current grant without raising any dialog.
    public static func isGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func ensureGranted() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }
}
