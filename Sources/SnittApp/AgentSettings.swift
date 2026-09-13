// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittAutomation

/// The agent-recording opt-in (§5.3), and D95's unattended grant.
///
/// Every flag defaults to FALSE for defaults that have never been written. That
/// is the safety rule, not a preference: an opt-in whose default reads as
/// enabled is decorative. They are separate because agreeing that agents may
/// record is not agreeing to hand over the whole screen — nor to let one record
/// while nobody is watching.
public struct AgentSettings: Sendable, Equatable {
    public var agentRecordingEnabled: Bool
    public var fullDisplayAllowed: Bool
    /// D95's opt-in. Meaningless on its own — see `unattendedGrant`, which is
    /// the only thing that should be asked whether unattended recording is
    /// permitted right now.
    public var unattendedRecordingEnabled: Bool
    /// When a person last confirmed the unattended opt-in while standing in
    /// front of the machine. Stored as a Date rather than a Bool because the
    /// grant EXPIRES: §5.4's staleness objection is the reason D95 is allowed
    /// to exist at all, and an unexpiring flag would simply reinstate it.
    public var unattendedConfirmedAt: Date?

    private static let enabledKey = "com.impressiver.snitt.agentRecordingEnabled"
    private static let displayKey = "com.impressiver.snitt.agentFullDisplayAllowed"
    private static let unattendedKey = "com.impressiver.snitt.unattendedRecordingEnabled"
    private static let confirmedKey = "com.impressiver.snitt.unattendedRecordingConfirmedAt"

    public init(agentRecordingEnabled: Bool = false, fullDisplayAllowed: Bool = false,
                unattendedRecordingEnabled: Bool = false,
                unattendedConfirmedAt: Date? = nil) {
        self.agentRecordingEnabled = agentRecordingEnabled
        self.fullDisplayAllowed = fullDisplayAllowed
        self.unattendedRecordingEnabled = unattendedRecordingEnabled
        self.unattendedConfirmedAt = unattendedConfirmedAt
    }

    /// The three stored values read as one question: may an agent record right
    /// now with nobody here?
    ///
    /// Composed rather than stored, so the subordination to §5.3's global
    /// opt-in cannot drift: turning agent recording off has to withdraw this
    /// too, and a second stored Bool would be a second opinion that a later
    /// edit could leave behind. Nothing clears the confirmation when agent
    /// recording goes off — the person's deliberate grant is recorded and
    /// simply authorizes nothing while dormant, so re-enabling restores exactly
    /// the grant they set, still inside the window they set it in.
    public var unattendedGrant: UnattendedRecordingGrant {
        UnattendedRecordingGrant(agentRecordingEnabled: agentRecordingEnabled,
                                 enabled: unattendedRecordingEnabled,
                                 confirmedAt: unattendedConfirmedAt)
    }

    public static func load(_ defaults: UserDefaults = .standard) -> AgentSettings {
        AgentSettings(agentRecordingEnabled: defaults.bool(forKey: enabledKey),
                      fullDisplayAllowed: defaults.bool(forKey: displayKey),
                      unattendedRecordingEnabled: defaults.bool(forKey: unattendedKey),
                      // `object(forKey:)`, not a TimeInterval read: `double`
                      // returns 0 for a missing key, and 0 is 1 January 1970 —
                      // a confirmation so old it reads as lapsed rather than
                      // as absent, which are different states with different
                      // words in front of a person.
                      unattendedConfirmedAt: defaults.object(forKey: confirmedKey) as? Date)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(agentRecordingEnabled, forKey: Self.enabledKey)
        defaults.set(fullDisplayAllowed, forKey: Self.displayKey)
        defaults.set(unattendedRecordingEnabled, forKey: Self.unattendedKey)
        if let unattendedConfirmedAt {
            defaults.set(unattendedConfirmedAt, forKey: Self.confirmedKey)
        } else {
            // REMOVED, not written as nil-ish: leaving the old date behind
            // would let a renewal that was declined keep authorizing the
            // window the previous one bought.
            defaults.removeObject(forKey: Self.confirmedKey)
        }
    }
}
