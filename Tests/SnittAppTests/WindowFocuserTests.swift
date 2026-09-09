// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp
@testable import SnittCapture

/// Thread-safe recorder of activated pids, since `WindowFocuser`'s closure
/// is `@Sendable` and a plain captured `var` cannot cross that boundary
/// under strict concurrency.
private final class ActivationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [pid_t] = []

    func record(_ pid: pid_t) {
        lock.lock()
        pids.append(pid)
        lock.unlock()
    }

    var all: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return pids
    }
}

private func descriptor(kind: String, pid: pid_t?) -> CaptureTargetDescriptor {
    CaptureTargetDescriptor(id: 1, kind: kind, title: "t",
                            applicationName: "App", width: 100, height: 100,
                            processID: pid)
}

@Test("A window target activates its owning application")
func windowTargetActivates() {
    let activated = ActivationLog()
    let focuser = WindowFocuser { pid in activated.record(pid); return true }
    #expect(focuser.focus(descriptor: descriptor(kind: "window", pid: 42)) == true)
    #expect(activated.all == [42])
}

@Test("A display target is never focused — there is nothing to bring forward")
func displayTargetDoesNotActivate() {
    let activated = ActivationLog()
    let focuser = WindowFocuser { pid in activated.record(pid); return true }
    // A non-nil pid on a display shouldn't occur in practice (`descriptor`
    // never sets one for the `.display` arm), but it is used here on purpose:
    // it isolates the kind check from the nil-pid check so this test cannot
    // pass against a focuser that skips a display only because its pid was
    // nil rather than because it checked `kind`.
    #expect(focuser.focus(descriptor: descriptor(kind: "display", pid: 99)) == false)
    #expect(activated.all.isEmpty)
}

@Test("A window with no owning process is skipped rather than guessed at")
func missingProcessIsSkipped() {
    let activated = ActivationLog()
    let focuser = WindowFocuser { pid in activated.record(pid); return true }
    #expect(focuser.focus(descriptor: descriptor(kind: "window", pid: nil)) == false)
    #expect(activated.all.isEmpty)
}
