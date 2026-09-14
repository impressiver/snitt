// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import CoreGraphics
@testable import SnittCapture
import SnittDocument

@Test("Key and mouse events map to the kinds the log stores")
func eventTypesMapToKinds() {
    #expect(InputEventMonitor.kind(for: .keyDown) == .keystroke)
    #expect(InputEventMonitor.kind(for: .leftMouseDown) == .click)
    #expect(InputEventMonitor.kind(for: .rightMouseDown) == .click)
}

@Test("Key UP is not logged — one keystroke must not count as two")
func keyUpIsIgnored() {
    // Down and up both arrive. Logging both would double every keystroke,
    // which matters because M3c's --auto-trim reasons about event density.
    #expect(InputEventMonitor.kind(for: .keyUp) == nil)
    #expect(InputEventMonitor.kind(for: .leftMouseUp) == nil)
}

@Test("Tap-disabled notifications are not logged as input")
func tapDisabledIsNotAnEvent() {
    // macOS sends these THROUGH the tap callback. Treating them as input
    // would put phantom events in the log at the moment the tap broke.
    #expect(InputEventMonitor.kind(for: .tapDisabledByTimeout) == nil)
    #expect(InputEventMonitor.kind(for: .tapDisabledByUserInput) == nil)
}

@Test("The event mask covers exactly the types that map to a kind")
func maskMatchesTheMappedTypes() {
    // A mask that requested types we then drop would wake the callback for
    // nothing on every keypress; a mask missing a mapped type would silently
    // never log it.
    let mapped: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
    for type in mapped {
        #expect(InputEventMonitor.eventMask & (1 << type.rawValue) != 0,
                "\(type) maps to a kind but is not in the mask")
    }
    let unmapped: [CGEventType] = [.keyUp, .leftMouseUp, .mouseMoved]
    for type in unmapped {
        #expect(InputEventMonitor.eventMask & (1 << type.rawValue) == 0,
                "\(type) is in the mask but maps to no kind")
    }
}

// MARK: - Lifetime
//
// The Input Monitoring grant is per-machine, so these cover BOTH branches
// rather than bailing out on one. An earlier round called them untestable;
// they are not — what they cannot do is force the branch, so each says what it
// expects in either state instead of silently inverting on a dev machine that
// has granted the test runner.

@Test("A monitor is released once its tap is gone, however start() went")
func monitorIsReleasedAfterStop() {
    // The tap holds a +1 on the monitor. A failed tapCreate that forgot to
    // release it, or a stop() that forgot to, would keep the object alive
    // forever with no way to reach it — deinit would never run, so the thread
    // and the mach port would leak with it.
    weak var weakMonitor: InputEventMonitor?
    do {
        let monitor = InputEventMonitor { _, _ in }
        weakMonitor = monitor
        // The return value is DELIBERATELY not compared against
        // `InputMonitoringAccess.isGranted()`, which is what this test used to
        // do and what made it flaky — it failed three separate full-gate runs
        // on 2026-09-14 and passed in isolation every time.
        //
        // The two are not equivalent and the platform never promised they
        // would be. `isGranted()` is `CGPreflightListenEventAccess()`, a
        // cached answer about the CURRENT process's TCC record;
        // `CGEventTapCreate` is a live kernel call that can succeed while the
        // preflight still reports false — most reliably for a test binary,
        // which is not the registered app the grant is recorded against. So
        // the assertion was testing an agreement between two independent
        // system calls, not anything in this file.
        //
        // What this test is FOR is the line below: the tap holds a +1 on the
        // monitor, and a failed `tapCreate` that forgot to release it — or a
        // `stop()` that forgot to — keeps the object alive for ever with no
        // way to reach it. `deinit` never runs, so the thread and the mach
        // port leak with it. That holds however `start()` went, which is what
        // the test's own name says.
        _ = monitor.start()
        monitor.stop()
    }
    #expect(weakMonitor == nil, "the tap's +1 must have been released")
}

@Test("stop() before start() is a no-op rather than a crash or a hang")
func stopBeforeStartIsSafe() {
    // stop() now WAITS for the tap thread before releasing the +1, because
    // invalidating the mach port does not synchronise with a callback already
    // running. Two things keep that wait from blocking on nothing: the
    // `guard let tap` at the top of stop(), and the semaphore being nil until
    // a thread is actually launched. This pins the observable half — a stop
    // with no thread returns promptly — which is what a caller depends on.
    // It does NOT discriminate the semaphore's shape: the tap guard alone
    // would also make this path fast.
    let monitor = InputEventMonitor { _, _ in }
    let began = Date()
    monitor.stop()
    #expect(Date().timeIntervalSince(began) < 0.5,
            "stop() with no thread must not wait on a semaphore nothing will signal")
}

@Test("stop() twice neither double-releases nor waits a second time")
func stopTwiceIsSafe() {
    // The second stop must find `tap` already nil and return immediately:
    // releasing the +1 twice is an over-release, and the join must not be
    // re-attempted against a thread that has already gone.
    weak var weakMonitor: InputEventMonitor?
    let began: Date
    do {
        let monitor = InputEventMonitor { _, _ in }
        weakMonitor = monitor
        _ = monitor.start()
        monitor.stop()
        began = Date()
        monitor.stop()
    }
    #expect(Date().timeIntervalSince(began) < 0.5,
            "a second stop must not wait again")
    #expect(weakMonitor == nil)
}
