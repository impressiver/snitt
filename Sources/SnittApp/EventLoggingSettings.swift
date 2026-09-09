// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The opt-in for logging input events (§4.2, §4.10 rung 3).
///
/// Defaults to FALSE for defaults that have never been written. That is the
/// safety rule rather than a preference: enabling it costs the user a third
/// TCC dialog, and the only consumer of the log ships in a later milestone.
public struct EventLoggingSettings: Sendable, Equatable {
    public var enabled: Bool

    private static let enabledKey = "com.impressiver.snitt.eventLoggingEnabled"

    public init(enabled: Bool = false) { self.enabled = enabled }

    public static func load(_ defaults: UserDefaults = .standard) -> EventLoggingSettings {
        EventLoggingSettings(enabled: defaults.bool(forKey: enabledKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
