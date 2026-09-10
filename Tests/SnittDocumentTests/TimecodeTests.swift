// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Reading a time somebody typed into the transport's field.
@Suite
struct TimecodeTests {
    @Test("Minutes and seconds")
    func minutesAndSeconds() {
        #expect(Timecode.parse("1:30") == 90)
        #expect(Timecode.parse("0:08") == 8)
    }

    @Test("A bare number is seconds")
    func bareSeconds() {
        // What someone types when the answer is under a minute, and refusing
        // it to accept only "0:45" is the strictness that makes a field feel
        // broken.
        #expect(Timecode.parse("45") == 45)
        #expect(Timecode.parse("90") == 90)
    }

    @Test("Fractions of a second survive")
    func fractions() {
        // The readout shows hundredths, so the field must accept what it
        // displays — a field that cannot read its own output is a defect.
        #expect(Timecode.parse("0:08.27") == 8.27)
        #expect(Timecode.parse("1:30.5") == 90.5)
    }

    @Test("Hours work")
    func hours() {
        #expect(Timecode.parse("1:02:03") == 3723)
    }

    @Test("Whitespace is forgiven")
    func whitespace() {
        #expect(Timecode.parse("  1:30 ") == 90)
    }

    @Test("Nonsense is nil, never zero")
    func nonsenseIsNil() {
        // Nil rather than 0 is the whole contract. A caller that could not
        // tell "they typed nonsense" from "they typed the start" would jump
        // to the beginning on a typo — a destructive-feeling surprise in the
        // middle of an edit.
        #expect(Timecode.parse("banana") == nil)
        #expect(Timecode.parse("") == nil)
        #expect(Timecode.parse("   ") == nil)
        #expect(Timecode.parse("1:2:3:4") == nil)
        #expect(Timecode.parse("-5") == nil)
    }

    @Test("A minutes field over 59 is refused rather than quietly carried")
    func overflowingComponentIsRefused() {
        // "1:90" is not a time. Accepting it would silently mean 2:30 — the
        // field would land the playhead somewhere the user did not name.
        #expect(Timecode.parse("1:90") == nil)
        #expect(Timecode.parse("1:60") == nil)
        // But a LEADING component may exceed 59: 90 seconds, or 75 minutes.
        #expect(Timecode.parse("75:00") == 4500)
    }

    @Test("A fraction is only allowed on the last component")
    func fractionOnlyOnSeconds() {
        // "1.5:30" is not something anyone means, and guessing at it is worse
        // than refusing it.
        #expect(Timecode.parse("1.5:30") == nil)
    }
}
