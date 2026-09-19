// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation
import SnittDocument

/// The human-readable half of D104's two fields, shared by both frontends for
/// the same reason `healthFields` and `sizeBudgetNote` are (§4.8: the CLI and
/// the MCP server must not diverge).
///
/// The structured field is what an agent branches on; these sentences are what
/// a person reads in a log, and this project has already shipped one defect
/// where the JSON was honest and the prose beside it was silent
/// (`exportNoteReportsAMissedBudget`).
@Suite
struct ResponseNoteTests {

    @Test("Vocabulary that was all kept produces no note at all")
    func silentWhenNothingWasDropped() {
        // Discriminates against an implementation that always appends a clause,
        // which would put "0 vocabulary terms did not reach the recogniser" on
        // the overwhelming majority of recordings: noise that trains a reader
        // to skip the line that matters.
        #expect(vocabularyNote(nil) == nil)
        #expect(vocabularyNote(0) == nil)
    }

    @Test("A truncated vocabulary says how many terms were lost")
    func reportsTheCount() throws {
        // Discriminates against the pre-D104 behaviour, which is the absence of
        // any note: `AutomationHost` read `Vocabulary.prepare(...).terms` and
        // threw `.dropped` away, so 50 terms vanished behind an ordinary
        // success. A note that omits the number fails here too: knowing
        // something was dropped without knowing how much does not tell a caller
        // whether to trim two terms or a hundred.
        let note = try #require(vocabularyNote(50))
        #expect(note.contains("50"))
        #expect(note.contains("\(Vocabulary.limit)"))
    }

    @Test("One dropped term is singular")
    func singularReadsCorrectly() {
        #expect(vocabularyNote(1)?.contains("1 vocabulary term ") == true)
        #expect(vocabularyNote(2)?.contains("2 vocabulary terms ") == true)
    }

    private func consent(agent: Bool, fullDisplay: Bool, unattended: Bool,
                         confirmedDaysAgo: Int?) -> ConsentInfo {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return ConsentInfo(
            grant: UnattendedRecordingGrant(
                agentRecordingEnabled: agent, enabled: unattended,
                confirmedAt: confirmedDaysAgo.map {
                    now.addingTimeInterval(-Double($0) * 86_400)
                }),
            fullDisplay: fullDisplay, now: now)
    }

    @Test("Everything granted says nothing")
    func silentWhenEverythingIsPermitted() {
        // Same discrimination as the vocabulary case: a status line that
        // recited its grants on every call would be skipped, and the one call
        // where a grant is missing is the one that needed reading.
        #expect(consentNote(consent(agent: true, fullDisplay: true,
                                    unattended: true, confirmedDaysAgo: 1)) == nil)
    }

    @Test("An app that cannot report grants says nothing rather than guessing")
    func silentWhenTheBlockIsAbsent() {
        // Discriminates against treating nil as "nothing is permitted", which
        // would make a newer CLI print an alarming refusal notice against every
        // older app while all the tools kept working fine.
        #expect(consentNote(nil) == nil)
    }

    @Test("Agent recording off is reported, and the other grants are not piled on")
    func agentRecordingOffIsTheOnlyThingSaid() throws {
        // Discriminates against listing every ungranted permission at once. With
        // the global switch off nothing else is actionable. A person has to
        // turn agent recording on first, and naming two more switches they
        // cannot usefully reach yet buries the one they can.
        let note = try #require(consentNote(consent(agent: false, fullDisplay: false,
                                                    unattended: false,
                                                    confirmedDaysAgo: nil)))
        #expect(note.contains("agent recording is off"))
        #expect(!note.contains("unattended"))
        #expect(!note.contains("full-display"))
    }

    @Test("A missing full-display grant names the alternative that works")
    func fullDisplayRefusalSuggestsAWindow() throws {
        // Discriminates against a bare "not allowed": every other refusal in
        // this surface names the way forward, and recording a window needs no
        // extra opt-in at all.
        let note = try #require(consentNote(consent(agent: true, fullDisplay: false,
                                                    unattended: true,
                                                    confirmedDaysAgo: 1)))
        #expect(note.contains("full-display"))
        #expect(note.contains("window"))
    }

    @Test("A lapsed unattended grant reads as a renewal, not as an invitation")
    func lapsedAndOffGetDifferentWords() throws {
        // Discriminates against one sentence for both states, which is the same
        // conflation `ConsentInfo` splits `unattended` out to avoid, one layer
        // up: "never enabled" asks a person to opt in, "lapsed" asks them to
        // renew something they already chose.
        let lapsed = try #require(consentNote(
            consent(agent: true, fullDisplay: true, unattended: true,
                    confirmedDaysAgo: UnattendedRecordingGrant.renewalDays + 5)))
        let never = try #require(consentNote(
            consent(agent: true, fullDisplay: true, unattended: false,
                    confirmedDaysAgo: nil)))
        #expect(lapsed.contains("lapsed"))
        #expect(never.contains("never"))
        #expect(lapsed != never)
    }
}
