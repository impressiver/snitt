// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// The app binary run as if it were the CLI.
///
/// macOS volumes are case-insensitive by default, so `Contents/MacOS/snitt` and
/// `Contents/MacOS/Snitt` are the same 11 MB AppKit application; the CLI is a
/// different binary in `Contents/Helpers/`. Reaching for the obvious-looking
/// path gets one that exists, is executable, and runs — then starts a run loop,
/// prints nothing, and never exits.
///
/// A real caller lost hours to it and filed a detailed bug report against the
/// CLI. They could not find the answer because `snitt help` was the app binary
/// too, printing nothing — so the trap also hid the documentation that would
/// have explained it.
@Suite("CLI misuse")
struct CLIMisuseTests {

    @Test("A CLI verb aimed at the app binary is refused with somewhere to go")
    func aVerbIsRefused() throws {
        let complaint = try #require(
            CLIMisuse.complaint(forArguments: ["/A.app/Contents/MacOS/Snitt", "status"]))
        // The message has one job: get the reader to the other binary. A
        // refusal that only said "this is the app" would end the hang and
        // leave them no better off than before.
        #expect(complaint.contains("Contents/Helpers/snitt"),
                "the refusal does not say where the CLI is: \(complaint)")
        #expect(complaint.contains("status"), "it should name the verb they typed")
    }

    @Test("An ordinary app launch is left alone")
    func anOrdinaryLaunchPasses() {
        // The guard's own trap, if it over-matched: refusing to start the app
        // somebody actually wanted is worse than the bug being fixed.
        #expect(CLIMisuse.complaint(forArguments: ["/A.app/Contents/MacOS/Snitt"]) == nil)
        #expect(CLIMisuse.complaint(
            forArguments: ["/A.app/Contents/MacOS/Snitt", "--launched-by-agent"]) == nil)
        #expect(CLIMisuse.complaint(
            forArguments: ["/A.app/Contents/MacOS/Snitt", "-psn_0_12345"]) == nil,
                "LaunchServices' own argument must not look like a CLI verb")
        #expect(CLIMisuse.complaint(
            forArguments: ["/A.app/Contents/MacOS/Snitt", "/Users/x/a.snitt"]) == nil,
                "a document path must not be mistaken for a verb")
    }

    @Test("Every verb the guard knows is a verb the parser knows")
    func theVerbListDoesNotDrift() {
        // The drift this list would otherwise suffer: a verb renamed in
        // `CommandLineParser` leaves the trap silently in place for exactly
        // that verb, which is the one somebody was typing.
        //
        // Direction covered here is verb-removed-or-renamed. The reverse — a
        // verb ADDED to the parser and not to this set — is not mechanically
        // checkable without reflection over a switch, and is stated rather than
        // pretended: `CLIMisuse.verbs` names that risk in its own doc comment.
        var unknown: [String] = []
        for verb in CLIMisuse.verbs {
            if case .failure(let failure) = CommandLineParser.parse([verb]),
               failure.message.contains("Unknown command") {
                unknown.append(verb)
            }
        }
        #expect(unknown.isEmpty,
                "the guard claims these are CLI verbs and the parser disagrees: \(unknown)")
    }

    @Test("A word the parser does not know is not claimed by the guard either")
    func anUnknownWordIsNotClaimed() {
        // Keeps the set honest in the other direction: if it grew to "anything
        // that is not a flag", the previous test would still pass while the
        // guard started refusing ordinary launches.
        for word in ["wibble", "Snitt", "open", "-NSDocumentRevisionsDebugMode"] {
            #expect(CLIMisuse.complaint(forArguments: ["/A.app", word]) == nil,
                    "the guard claimed \(word) as a CLI verb")
        }
    }
}
