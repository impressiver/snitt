// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp
import SnittAutomation

/// What a person finds when an unattended recording did not happen.
///
/// D95 records one limit that no opt-in removes: macOS re-prompts for Screen
/// Recording on its own schedule and that prompt needs a human, so the feature
/// "has to degrade honestly at that moment rather than fail silently
/// mid-session". This is that moment. The message is the entire degradation —
/// there is nobody watching a dialog, so what ends up in the failure text is
/// what the person reads when they get back.
struct UnattendedDenialMessageTests {

    @Test("With unattended off, the message is unchanged")
    func offIsTheOriginalMessage() {
        // Every existing caller and every existing expectation about this text
        // belongs to this case. Adding a paragraph for everyone would have
        // told a human who pressed the hotkey about a feature they never
        // turned on.
        #expect(RecordingCoordinator.screenRecordingDeniedMessage(unattended: .off)
                == RecordingCoordinator.screenRecordingDeniedMessage)
    }

    @Test("With a live grant, it says macOS withdrew access and a person is needed")
    func activeGrantExplainsTheExternalLimit() {
        let message = RecordingCoordinator.screenRecordingDeniedMessage(
            unattended: .active(daysRemaining: 12))
        // Still carries the instructions — the extra paragraph must ADD to the
        // remedy, never replace it.
        #expect(message.hasPrefix(RecordingCoordinator.screenRecordingDeniedMessage))
        #expect(message.contains("Unattended agent recording is on"))
        #expect(message.lowercased().contains("someone at this Mac".lowercased()),
                "the message does not say a person is required: \(message)")
        // And must NOT tell them to renew: the grant has not lapsed, so
        // renewing it would change nothing and would send them to the wrong
        // place.
        #expect(!message.contains("switch unattended recording back on"),
                "a live grant was described as needing renewal")
    }

    @Test("With a lapsed grant, it names how long ago and how to renew")
    func lapsedGrantExplainsTheRenewal() {
        let message = RecordingCoordinator.screenRecordingDeniedMessage(
            unattended: .lapsed(daysAgo: 4))
        #expect(message.hasPrefix(RecordingCoordinator.screenRecordingDeniedMessage))
        #expect(message.contains("lapsed 4 days ago"))
        #expect(message.contains("\(UnattendedRecordingGrant.renewalDays) days"),
                "the renewal period is missing from the one message that explains a renewal")
        #expect(message.contains("switch unattended recording back on"))
    }

    @Test("A grant that lapsed today does not read as '0 days ago'")
    func lapsedTodayReadsAsToday() {
        let message = RecordingCoordinator.screenRecordingDeniedMessage(unattended: .lapsed(daysAgo: 0))
        #expect(message.contains("lapsed today"))
        // Scoped to the phrase, not the digits: the renewal sentence in this
        // same message says "every 30 days", and a bare `contains("0 days")`
        // matches that — a test that fails on the correct implementation.
        #expect(!message.contains("lapsed 0 days"))
    }

    @Test("One day is singular")
    func oneDayIsSingular() {
        let message = RecordingCoordinator.screenRecordingDeniedMessage(unattended: .lapsed(daysAgo: 1))
        #expect(message.contains("lapsed 1 day ago"))
    }

    @Test("The three cases are genuinely different text")
    func casesAreDistinct() {
        // Guards the shape a `switch` returning the same base message from
        // every arm would take — which satisfies "contains the instructions"
        // in all three tests above and communicates nothing.
        let off = RecordingCoordinator.screenRecordingDeniedMessage(unattended: .off)
        let active = RecordingCoordinator.screenRecordingDeniedMessage(unattended: .active(daysRemaining: 3))
        let lapsed = RecordingCoordinator.screenRecordingDeniedMessage(unattended: .lapsed(daysAgo: 3))
        #expect(Set([off, active, lapsed]).count == 3)
    }
}
