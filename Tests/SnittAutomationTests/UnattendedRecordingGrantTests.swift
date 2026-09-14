// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// D95's expiring grant, at every boundary.
///
/// The whole point of the type is that it STOPS authorizing after thirty days
/// — §5.4's staleness objection is the reason it exists — so the assertions
/// that matter are the ones a fixed `true` would walk through. A test that only
/// checked a fresh grant is active would pass against a `status` that never
/// lapses at all.
struct UnattendedRecordingGrantTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func grant(agent: Bool = true, on: Bool = true,
                       confirmed: Date?) -> UnattendedRecordingGrant {
        UnattendedRecordingGrant(agentRecordingEnabled: agent, enabled: on,
                                 confirmedAt: confirmed)
    }

    @Test("A grant confirmed just now is active for the whole renewal period")
    func freshGrantIsActive() {
        let g = grant(confirmed: epoch)
        #expect(g.status(now: epoch) == .active(daysRemaining: UnattendedRecordingGrant.renewalDays))
    }

    @Test("The day before expiry it is still active, and says one day")
    func lastDayReadsAsOneDay() {
        // The rounding case. With twelve hours left, FLOOR would say "0 days
        // remaining" — a sentence that means lapsed, printed next to a feature
        // that is still working. Ceiling is the only honest direction here.
        let g = grant(confirmed: epoch)
        let twelveHoursLeft = epoch.addingTimeInterval(UnattendedRecordingGrant.validity - 12 * 3600)
        #expect(g.status(now: twelveHoursLeft) == .active(daysRemaining: 1))

        // And one second before the instant of expiry — still active, still 1.
        let aSecondLeft = epoch.addingTimeInterval(UnattendedRecordingGrant.validity - 1)
        #expect(g.status(now: aSecondLeft) == .active(daysRemaining: 1))
    }

    @Test("At the exact instant of expiry it has lapsed, not expiring")
    func expiryInstantIsLapsed() {
        // `<` versus `<=` is one character and decides whether a grant
        // authorizes recording on the day it runs out. Pinned at the instant
        // rather than a day either side, which both mutants survive.
        let g = grant(confirmed: epoch)
        let atExpiry = epoch.addingTimeInterval(UnattendedRecordingGrant.validity)
        #expect(g.status(now: atExpiry) == .lapsed(daysAgo: 0))
    }

    @Test("Well past expiry it reports how long ago, not just that it lapsed")
    func lapsedCountsDays() {
        let g = grant(confirmed: epoch)
        let sixWeeks = epoch.addingTimeInterval(42 * 86_400)
        // Six weeks is §5.4's own example of the staleness this type answers.
        #expect(g.status(now: sixWeeks) == .lapsed(daysAgo: 12))
    }

    @Test("Turning agent recording off makes an unexpired grant authorize nothing")
    func agentOptInGatesTheGrant() {
        // Subordination, checked against a stored grant that is otherwise
        // perfectly valid — the case where reading only `enabled` and
        // `confirmedAt` would return `.active` and hand an agent a recording
        // the §5.3 opt-in forbids.
        let g = grant(agent: false, confirmed: epoch)
        #expect(g.status(now: epoch) == .off)
    }

    @Test("A flag set with no confirmation authorizes nothing")
    func enabledWithoutConfirmationIsOff() {
        // The decorative-opt-in state. `AgentSettings`' own doc comment says
        // "an opt-in whose default reads as enabled is decorative"; this is the
        // same rule for a flag that was written without a person ever having
        // stood in front of the permission dialog.
        #expect(grant(confirmed: nil).status(now: epoch) == .off)
        #expect(grant(confirmed: nil).expiresAt == nil)
    }

    @Test("Switched off, a still-valid confirmation authorizes nothing")
    func disabledIsOffEvenWhenUnexpired() {
        #expect(grant(on: false, confirmed: epoch).status(now: epoch) == .off)
    }

    @Test("A clock moved backwards cannot promise a renewal further out than the period")
    func futureConfirmationIsClamped() {
        // Not hypothetical: a timezone change, a corrected clock, or a restored
        // preference file all put `confirmedAt` ahead of now. Unclamped, the
        // help text would offer a renewal date a year away and the grant would
        // outlive the OS permission it is supposed to track.
        let g = grant(confirmed: epoch.addingTimeInterval(400 * 86_400))
        #expect(g.status(now: epoch) == .active(daysRemaining: UnattendedRecordingGrant.renewalDays))
    }

    @Test("The renewal period matches the OS re-consent cadence it exists to track")
    func periodIsAMonth() {
        // Pinned with a reason rather than left to taste: the number is in the
        // help text a person plans around, and the point of choosing thirty was
        // that it coincides with the macOS prompt (§5.5) instead of
        // interleaving with it. Changing it should have to argue with this.
        #expect(UnattendedRecordingGrant.renewalDays == 30)
        #expect(UnattendedRecordingGrant.validity == 30 * 86_400)
    }

    @Test("expiresAt is the confirmation plus exactly the period")
    func expiryIsDerivedFromConfirmation() {
        let g = grant(confirmed: epoch)
        #expect(g.expiresAt == epoch.addingTimeInterval(UnattendedRecordingGrant.validity))
    }
}
