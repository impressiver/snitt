// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import SnittAutomation
import SnittCapture

/// Reconciles a starting Snitt with a Snitt already running.
///
/// Runs BEFORE `NSApplication.run()`, so an instance that stands down never
/// installs a status item, never registers a hotkey and never appears. Doing it
/// in `applicationDidFinishLaunching` would put a second icon in the menu bar
/// for as long as the probe takes, which is the thing being fixed.
///
/// See `InstanceDecision` for the policy and why it lands where it does. This
/// type is the part that has to touch AppKit and the clock, and is therefore
/// the part `SnittAppTests` cannot run headless — the decision it enacts is
/// tested in `SnittAutomationTests`, where CI reaches it.
enum SingleInstanceGuard {
    private static let log = SnittLog.logger(.automation, target: "SnittApp")

    /// How long to let an incumbent quit of its own accord.
    ///
    /// Nothing happens after it but standing down. An orderly quit is the path
    /// that runs `applicationShouldTerminate`, and an idle app takes it
    /// promptly; one that does not is telling us something we asked about and
    /// got no answer to.
    private static let gracePeriod: TimeInterval = 6

    /// How long to wait for the incumbent to say whether it is recording.
    ///
    /// The probe reaches the recorder actor through the main actor, and during
    /// real capture both are busy. Three seconds read a working app under load
    /// as unreachable, and the old rule then treated unreachable as fair game.
    /// The rule is fixed; the timeout is widened anyway, because the useful
    /// answer is the one that arrives.
    private static let probeTimeout: TimeInterval = 10

    /// Whether this process should go on to run.
    ///
    /// `false` means the caller must exit immediately, without starting the app.
    static func reconcile() -> Bool {
        let others = otherInstances()
        let decision = InstanceDecision.decide(
            otherInstancesRunning: !others.isEmpty,
            incumbentIsRecording: others.isEmpty ? nil : incumbentIsRecording())

        switch decision {
        case .proceed:
            return true

        case .deferToIncumbent:
            // Deliberately a log line and not an alert. A person who just
            // double-clicked Snitt while it was recording gets the running app
            // brought forward, which answers the question they were asking; a
            // modal would interrupt the recording's own window.
            log.notice("Another Snitt is recording. Standing down so the take survives.")
            others.first?.activate()
            return false

        case .replaceIncumbent:
            log.notice("Taking over from \(others.count, privacy: .public) idle instance(s).")
            let stubborn = others.filter { !retire($0) }
            guard stubborn.isEmpty else {
                // It said it was idle and then would not quit. Whatever it is
                // doing, it is not something to end from here.
                log.notice("An instance would not quit. Standing down rather than forcing it.")
                return false
            }
            return true
        }
    }

    /// Every OTHER process of this bundle identifier.
    ///
    /// By identifier, not by path: the whole defect is that LaunchServices
    /// treats two paths as two apps, so matching on path here would agree with
    /// it and find nothing.
    private static func otherInstances() -> [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// Asks the incumbent over the automation socket. `nil` when it will not say.
    ///
    /// `launchIfNeeded: false` is load-bearing — the default would have this
    /// launch a fourth Snitt while deciding what to do about the second.
    private static func incumbentIsRecording() -> Bool? {
        let client = AutomationClient(timeout: probeTimeout, launchIfNeeded: false)
        let answer = Locked<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard case .status(let info)? = try? await client.send(.status) else { return }
            answer.set(info.recording)
        }
        // Blocking the main thread, on purpose: nothing is on screen yet, and
        // every branch below this depends on the answer. Bounded well above the
        // client's own 3-second timeout so this cannot outlive it.
        _ = done.wait(timeout: .now() + probeTimeout + 2)
        return answer.get()
    }

    /// Ask an idle incumbent to quit. `false` if it did not.
    ///
    /// `terminate()` posts a Quit event, which is what lets the incumbent flush
    /// pending saves on the way out. It is the only thing tried.
    ///
    /// **No force.** An earlier version escalated to `forceTerminate()` after
    /// the grace period, on the reasoning that this branch is only reached for
    /// an incumbent known to be idle. That knowledge has a shelf life: the
    /// probe answered some seconds ago, and a recording can begin in between —
    /// a hotkey, a person, the other agent on the machine. SIGKILL on a
    /// recording app loses the take outright, and it would do so precisely when
    /// the app was too busy to take the polite exit, which is what being mid
    /// capture looks like. Nothing here is worth that: if the incumbent will
    /// not go, the NEWCOMER goes instead.
    private static func retire(_ instance: NSRunningApplication) -> Bool {
        instance.terminate()
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            if instance.isTerminated { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

/// A box a detached task can write and the waiting thread can read.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}
