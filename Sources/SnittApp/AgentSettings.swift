// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The agent-recording opt-in (§5.3).
///
/// Both flags default to FALSE for defaults that have never been written. That is
/// the safety rule, not a preference: an opt-in whose default reads as enabled is
/// decorative. They are separate because agreeing that agents may record is not
/// agreeing to hand over the whole screen.
public struct AgentSettings: Sendable, Equatable {
    public var agentRecordingEnabled: Bool
    public var fullDisplayAllowed: Bool

    private static let enabledKey = "com.impressiver.snitt.agentRecordingEnabled"
    private static let displayKey = "com.impressiver.snitt.agentFullDisplayAllowed"

    public init(agentRecordingEnabled: Bool = false, fullDisplayAllowed: Bool = false) {
        self.agentRecordingEnabled = agentRecordingEnabled
        self.fullDisplayAllowed = fullDisplayAllowed
    }

    public static func load(_ defaults: UserDefaults = .standard) -> AgentSettings {
        AgentSettings(agentRecordingEnabled: defaults.bool(forKey: enabledKey),
                      fullDisplayAllowed: defaults.bool(forKey: displayKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(agentRecordingEnabled, forKey: Self.enabledKey)
        defaults.set(fullDisplayAllowed, forKey: Self.displayKey)
    }
}
