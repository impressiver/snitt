// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// D104's pre-flight block: which grants are in force, reported before an agent
/// tries rather than discovered from a `consent_required` failure.
///
/// The whole suite exists around one trap. `UnattendedRecordingGrant.status`
/// returns `.off` for TWO different situations: a person who never enabled
/// unattended recording, and a person who did but whose agent-recording switch
/// is off. The obvious implementation of this block is to report that
/// status directly. It compiles, it reads right, and it sends an agent to fix
/// the wrong switch.
@Suite
struct ConsentInfoTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func grant(agent: Bool, unattended: Bool,
                       confirmedDaysAgo: Int?) -> UnattendedRecordingGrant {
        UnattendedRecordingGrant(
            agentRecordingEnabled: agent,
            enabled: unattended,
            confirmedAt: confirmedDaysAgo.map {
                Self.now.addingTimeInterval(-Double($0) * 86_400)
            })
    }

    @Test("A live unattended grant is still reported as live when agent recording is off")
    func unattendedIsReportedOnItsOwnTerms() {
        // THE discriminating test. The plausible wrong implementation is
        // `unattended = grant.status(now:)`, which folds the global opt-in in
        // and answers `.off` here. An agent reading that asks a person to
        // enable unattended recording, which they already did, instead of
        // asking for the switch that is actually off, and then fails again.
        let info = ConsentInfo(grant: grant(agent: false, unattended: true,
                                            confirmedDaysAgo: 1),
                               fullDisplay: false, now: Self.now)
        #expect(info.agentRecording == false)
        #expect(info.unattended == .active)
        #expect(info.unattendedDaysRemaining == UnattendedRecordingGrant.renewalDays - 1)
        // And the composed answer is still NO, because unattended recording is
        // subordinate to §5.3's opt-in. Reporting the grant honestly must not
        // become permitting the work.
        #expect(info.unattendedPermitted == false)
    }

    @Test("An unattended grant that was never set up reads as off, not as lapsed")
    func neverEnabledIsOff() {
        // Discriminates against deriving the state from `expiresAt` alone,
        // which would make a never-confirmed grant look like one that expired
        // in 1970: an overdue renewal rather than an invitation, which is the
        // distinction `Status` has three cases for in the first place.
        let info = ConsentInfo(grant: grant(agent: true, unattended: false,
                                            confirmedDaysAgo: nil),
                               fullDisplay: false, now: Self.now)
        #expect(info.agentRecording == true)
        #expect(info.unattended == .off)
        #expect(info.unattendedDaysRemaining == nil)
        #expect(info.unattendedPermitted == false)
    }

    @Test("A grant past its renewal window reads as lapsed, and permits nothing")
    func lapsedIsNotPermitted() {
        // Discriminates against `unattendedPermitted = unattended != .off`,
        // which is the exact wrong test `Status.isActive` was named to prevent:
        // a lapsed grant is also not `.off`, so that form quietly authorises an
        // expired grant.
        let info = ConsentInfo(
            grant: grant(agent: true, unattended: true,
                         confirmedDaysAgo: UnattendedRecordingGrant.renewalDays + 5),
            fullDisplay: false, now: Self.now)
        #expect(info.unattended == .lapsed)
        #expect(info.unattendedDaysRemaining == nil)
        #expect(info.unattendedPermitted == false)
    }

    @Test("A grant in force permits unattended work and says how long it has left")
    func activeGrantIsPermitted() {
        let info = ConsentInfo(grant: grant(agent: true, unattended: true,
                                            confirmedDaysAgo: 10),
                               fullDisplay: true, now: Self.now)
        #expect(info.unattended == .active)
        #expect(info.unattendedDaysRemaining == UnattendedRecordingGrant.renewalDays - 10)
        #expect(info.unattendedPermitted == true)
        #expect(info.fullDisplay == true)
    }

    @Test("Full display is its own grant, not implied by agent recording")
    func fullDisplayIsSeparate() {
        // Discriminates against reporting one permission for both, which is
        // what `ConsentPolicy` already refuses to do: agreeing that agents may
        // record is not agreeing to hand over the whole screen.
        let info = ConsentInfo(grant: grant(agent: true, unattended: false,
                                            confirmedDaysAgo: nil),
                               fullDisplay: false, now: Self.now)
        #expect(info.agentRecording == true)
        #expect(info.fullDisplay == false)
    }

    @Test("The standing status ignores the global switch; the authorising one does not")
    func standingStatusAndStatusAnswerDifferentQuestions() {
        // Pins the split directly, so a later simplification that collapses
        // `standingStatus` back into `status` fails here rather than silently
        // making the block lie again.
        let g = grant(agent: false, unattended: true, confirmedDaysAgo: 1)
        #expect(g.status(now: Self.now) == .off)
        #expect(g.standingStatus(now: Self.now)
                == .active(daysRemaining: UnattendedRecordingGrant.renewalDays - 1))

        // And with the switch on, the two agree: the split is a reporting
        // nuance, not two different rulebooks.
        let on = grant(agent: true, unattended: true, confirmedDaysAgo: 1)
        #expect(on.status(now: Self.now) == on.standingStatus(now: Self.now))
    }
}
