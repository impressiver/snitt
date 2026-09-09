// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The opt-in for local crash-report collection (§12).
///
/// The maintainer's ruling for §12's "opt-in crash reporting, surfaced in
/// settings" is local-only: no signal handler, no network, no dependency.
/// This setting controls only whether `snitt diagnostics export` reads
/// Snitt's own `.ips` files out of `~/Library/Logs/DiagnosticReports/` and
/// folds redacted summaries of them into the bundle it already writes.
///
/// Defaults to FALSE for defaults that have never been written, mirroring
/// `UpdateSettings`/`EventLoggingSettings`: a crash report can carry more of
/// the machine's state than an ordinary log line, so collecting it — even
/// locally, even only into a bundle the user chooses to export — is a
/// decision made for them if it defaults on.
///
/// `UserDefaults.bool(forKey:)` is the discriminator that keeps a corrupt or
/// absent stored value reading as off: it returns `false` both when the key
/// is missing and when the stored value isn't one it can coerce to a bool
/// (an array, a dictionary, garbage). An implementation that instead read
/// `object(forKey:) as? Bool ?? true` would flip a corrupt value to enabled
/// — the exact shape of silent coercion this project has been bitten by
/// four times now. Absent and invalid are different states, but neither is
/// "on".
public struct CrashReportSettings: Sendable, Equatable {
    public var enabled: Bool

    private static let enabledKey = "com.impressiver.snitt.crashReportingEnabled"

    public init(enabled: Bool = false) { self.enabled = enabled }

    public static func load(_ defaults: UserDefaults = .standard) -> CrashReportSettings {
        CrashReportSettings(enabled: defaults.bool(forKey: enabledKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
