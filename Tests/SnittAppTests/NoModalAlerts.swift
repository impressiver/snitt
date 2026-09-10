// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
@testable import SnittApp

/// Makes it impossible for a test to raise a modal alert.
///
/// `NSAlert.runModal()` blocks the main thread until a human clicks OK. In a
/// test run that is not one slow test — it is the WHOLE RUN stopped, with no
/// output and no failing test, because a modal run loop starves the MainActor
/// every other test needs. The bounded test gates cannot catch it either:
/// their polling loop needs the same MainActor the modal is holding.
///
/// This is what actually caused the ten-minute hang investigated on
/// 2026-09-09. `DockReopenTests` calls the real
/// `AppDelegate.applicationShouldHandleReopen`, whose "most recent document"
/// comes from `NSDocumentController.recentDocumentURLs` — machine-global
/// state that `AppShellTests` and `DocumentOpenerTests` each clear in a
/// `defer`. Lose that race and the reopen path finds no recents and raises
/// "Snitt has no recent recordings to reopen." The dialog was photographed
/// mid-run before anyone identified it.
///
/// Installed rather than asserted: the point is to remove the possibility, not
/// to notice it afterwards. `silence()` is idempotent and safe to call from
/// any suite's `init`.
@MainActor
enum NoModalAlerts {
    private static var installed = false

    /// The messages tests would have shown, most recent last. Lets a test
    /// assert WHAT would have been presented without presenting it.
    private(set) static var presented: [String] = []

    static func silence() {
        guard !installed else { return }
        installed = true
        AppDelegate.presentMessage = { message in
            presented.append(message)
        }
    }

    static func reset() { presented.removeAll() }
}
