// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// A standing, revocable, EXPIRING permission for an agent to record while
/// nobody is at the keyboard (D95).
///
/// §5.4 deleted a persistent per-application grant and gave three reasons.
/// One of them — staleness — still bites, and this type is the answer to it:
/// "a standing grant cannot know what the target is showing six weeks later,
/// which is the incidental-leak class §5.1 exists to prevent — and unattended
/// is precisely when nobody is watching." A grant that EXPIRES cannot go six
/// weeks stale, because at thirty days it stops authorizing anything until a
/// person renews it deliberately. That is what keeps "nothing recorded without
/// explicit permission" true when the permission moves from per-recording to
/// standing.
///
/// **The renewal period is not a taste decision.** macOS re-confirms Screen
/// Recording roughly monthly for any app on the bypass path (§5.2, §5.5, and
/// `ConsentExplainer`'s own copy says "about once a month"), and that prompt
/// needs a human. Expiring the grant on the same cadence means the two
/// renewals coincide instead of interleaving, so a person who renews before
/// leaving has renewed BOTH.
///
/// Pure, with the clock injected, so every boundary is testable — the OS
/// permission itself is per-machine and one-shot, and nothing here touches it.
public struct UnattendedRecordingGrant: Sendable, Equatable {
    /// Thirty days, to match the OS cadence above. Exposed because the
    /// Settings window's help text must state the number rather than say
    /// "periodically" — a renewal a person cannot plan for is one they
    /// discover by finding a recording that never happened.
    public static let renewalDays = 30
    public static let validity: TimeInterval = Double(renewalDays) * 24 * 60 * 60

    /// What the grant authorizes RIGHT NOW.
    ///
    /// Three cases rather than a Bool, because "never turned on" and "turned
    /// on and lapsed" need opposite words in front of a person: one is an
    /// invitation, the other is a renewal that is overdue.
    public enum Status: Equatable, Sendable {
        case off
        case active(daysRemaining: Int)
        case lapsed(daysAgo: Int)

        /// Whether unattended recording is permitted RIGHT NOW.
        ///
        /// Named rather than left as `status != .off`, because that is the
        /// wrong test and it reads as the right one: `.lapsed` is also not
        /// `.off`, so the negative form quietly treats an expired grant as a
        /// live one — which is the whole failure this type exists to prevent.
        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    /// §5.3's global opt-in. Unattended recording is subordinate to it: an
    /// agent that may not record at all certainly may not record unwatched.
    public let agentRecordingEnabled: Bool
    public let enabled: Bool
    /// When a person last confirmed it, in front of the machine. `nil` means
    /// never — and `enabled` with no confirmation authorizes NOTHING, which is
    /// deliberate: a flag set without a person present is the decorative
    /// opt-in `AgentSettings` already refuses to have.
    public let confirmedAt: Date?

    public init(agentRecordingEnabled: Bool, enabled: Bool, confirmedAt: Date?) {
        self.agentRecordingEnabled = agentRecordingEnabled
        self.enabled = enabled
        self.confirmedAt = confirmedAt
    }

    public var expiresAt: Date? { confirmedAt.map { $0.addingTimeInterval(Self.validity) } }

    public func status(now: Date) -> Status {
        guard agentRecordingEnabled, enabled, let expiresAt else { return .off }

        if now < expiresAt {
            let remaining = expiresAt.timeIntervalSince(now)
            // CEILING, and never zero: with an hour left this must read "1
            // day", not "0 days remaining", which is a sentence that means
            // lapsed. And clamped to the period itself, because a clock moved
            // backwards puts `confirmedAt` in the future and would otherwise
            // promise a renewal four hundred days out.
            let days = Int(ceil(remaining / 86_400))
            return .active(daysRemaining: max(1, min(Self.renewalDays, days)))
        }
        // FLOOR here, and zero is meaningful: it lapsed today.
        let elapsed = now.timeIntervalSince(expiresAt)
        return .lapsed(daysAgo: Int(floor(elapsed / 86_400)))
    }
}
