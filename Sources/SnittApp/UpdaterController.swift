// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import OSLog
import Sparkle
import SnittCapture
import SnittDocument

/// Wraps Sparkle so the rest of the app touches one type, not
/// `SPUStandardUpdaterController` directly.
///
/// Ruling R3: Info.plist's `SUEnableAutomaticChecks = false` is only the
/// cold-start default for a fresh install with no stored preference.
/// `UpdateSettings` is the user's actual choice, and this type is what
/// applies it to Sparkle at construction and on every change — never the
/// other way around.
///
/// `@MainActor`, not `@unchecked Sendable`: `SPUUpdater` and
/// `SPUUpdaterDelegate` are themselves main-actor-bound in this SDK (the
/// delegate protocol is `NS_SWIFT_UI_ACTOR`), so isolating this wrapper to
/// the main actor is what Sparkle already requires, not an extra
/// restriction layered on top.
@MainActor
public final class UpdaterController: NSObject {
    private let controller: SPUStandardUpdaterController
    private let bridge: DelegateBridge
    private static let log = SnittLog.logger(.updates, target: "SnittApp")

    /// A scheduling decision Sparkle's own delegate callbacks can report.
    /// `UpdaterController` itself no longer records these — the R3
    /// discriminator this type existed for (proving a check was or wasn't
    /// actually scheduled, not merely that a boolean setting reads back
    /// correctly) is now observed directly against a raw `SPUUpdater` in
    /// `UpdaterControllerTests`' own `SchedulingSpy`, which is what still
    /// reuses this enum. Kept only for that shared vocabulary between the
    /// production delegate and the test's.
    public enum ScheduleEvent: Sendable, Equatable {
        case willSchedule
        case willNotSchedule
    }

    /// `SPUUpdater.delegate` can only be set at construction, and `self`
    /// isn't available before `super.init()` — this exists as a separate
    /// object so Sparkle has something to hold as its delegate before
    /// `UpdaterController` itself has finished being constructed.
    @MainActor
    private final class DelegateBridge: NSObject, SPUUpdaterDelegate {
        /// §5's diagnostics posture: an update check failure must be
        /// visible, not swallowed. Logs `domain` and `code` at `.public` —
        /// never `String(describing:)` on the `NSError` (its `userInfo` can
        /// carry `NSFilePath` or other user-identifying detail). `domain`
        /// and `code` alone are already enough to look up which of
        /// Sparkle's own failures this is.
        ///
        /// `localizedDescription` is deliberately `.private`, not `.public`:
        /// several of Sparkle's own error strings interpolate filesystem
        /// paths (e.g. `SUInvalidUpdaterError`'s XPC-service message
        /// includes the app bundle path), which for an app run from
        /// `~/Desktop` would put a home directory in a public log entry —
        /// the same shape as the two prior leaks through `os_log` this
        /// project has already had, so it stays `.private` here rather than
        /// becoming a third.
        func updater(_ updater: SPUUpdater,
                     didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                     error: Error?) {
            guard let error else { return }
            let nsError = error as NSError
            UpdaterController.log.error("update check failed domain: \(nsError.domain, privacy: .public) code: \(nsError.code, privacy: .public) reason: \(nsError.localizedDescription, privacy: .private)")
        }
    }

    /// Whether Sparkle will check for updates on its own schedule, without
    /// anyone asking. Forwards straight to `SPUUpdater` rather than tracking
    /// a duplicate value: Sparkle already persists this in the host bundle's
    /// user defaults and resets its own scheduling cycle (cancelling any
    /// timer already pending) whenever it changes, which is exactly the
    /// "turning it off must genuinely stop future checks" behaviour — this
    /// wrapper adding its own scheduler on top would only risk fighting it.
    public var automaticChecksEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    public init(settings: UpdateSettings) {
        let bridge = DelegateBridge()
        self.bridge = bridge
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                   updaterDelegate: bridge,
                                                   userDriverDelegate: nil)
        super.init()
        controller.updater.automaticallyChecksForUpdates = settings.automaticChecksEnabled
        // System profiling attaches a hardware/OS report to every update
        // check (Sparkle's `SUEnableSystemProfiling`). §5 draws the line at
        // an update check being the bare minimum Snitt tells anyone about
        // itself — leave this off explicitly so it can't get switched on
        // later "for analytics" without someone re-reading this comment.
        controller.updater.sendsSystemProfile = false
    }

    /// Actually starts Sparkle's update machinery. Deliberately not called
    /// from `init`: constructing this type (and setting
    /// `automaticallyChecksForUpdates`, which is inert until started — see
    /// Sparkle's own `updateAutomaticCheckSettingChanged:`, which no-ops
    /// unless `_startedUpdater`) must stay side-effect-free enough to run in
    /// a unit test against a host bundle Sparkle was never configured for.
    /// Only a real app launch, against a bundle carrying `SUFeedURL` and a
    /// valid version, should call this.
    public func start() {
        controller.startUpdater()
    }

    /// A manual check, always allowed regardless of `automaticChecksEnabled`
    /// — the user asking is exactly the consent §5 requires.
    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
