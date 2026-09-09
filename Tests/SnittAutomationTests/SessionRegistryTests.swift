// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

@Test("A fresh registry reports not recording")
func freshRegistryIsIdle() async {
    let registry = SessionRegistry()
    let status = await registry.current(now: Date())
    #expect(status.recording == false)
    #expect(status.sessionID == nil)
}

@Test("Opening a session makes it current and reports elapsed time")
func openMakesSessionCurrent() async throws {
    let registry = SessionRegistry()
    let start = Date(timeIntervalSince1970: 1000)
    let id = try await registry.open(maxDuration: 60, now: start)

    let status = await registry.current(now: start.addingTimeInterval(5))
    #expect(status.recording == true)
    #expect(status.sessionID == id)
    #expect(status.elapsedSeconds == 5)
}

@Test("A second open is refused rather than replacing the first")
func secondOpenRefused() async throws {
    let registry = SessionRegistry()
    _ = try await registry.open(maxDuration: 60, now: Date())

    await #expect(throws: AutomationError.self) {
        _ = try await registry.open(maxDuration: 60, now: Date())
    }
}

@Test("Closing an unknown session id fails rather than succeeding quietly")
func closingUnknownSessionFails() async {
    let registry = SessionRegistry()
    await #expect(throws: AutomationError.self) {
        try await registry.close("not-a-session")
    }
}

@Test("A session past its maximum duration is reported as expired")
func expiredSessionIsReported() async throws {
    // §5.3: a hung agent must not record forever. Something has to notice.
    let registry = SessionRegistry()
    let start = Date(timeIntervalSince1970: 1000)
    let id = try await registry.open(maxDuration: 30, now: start)

    #expect(await registry.expiredSession(now: start.addingTimeInterval(29)) == nil)
    // Exactly at the cap is NOT yet expired — the comparison is strict. Without
    // this sample the test cannot tell `>` from `>=` and a mutant survives.
    #expect(await registry.expiredSession(now: start.addingTimeInterval(30)) == nil)
    #expect(await registry.expiredSession(now: start.addingTimeInterval(31)) == id)
}

@Test("After closing, a new session can open")
func closeThenReopen() async throws {
    let registry = SessionRegistry()
    let first = try await registry.open(maxDuration: 60, now: Date())
    try await registry.close(first)
    let second = try await registry.open(maxDuration: 60, now: Date())
    #expect(second != first, "each session gets its own id")
}
