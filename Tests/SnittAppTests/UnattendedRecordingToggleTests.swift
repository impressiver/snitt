// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
import SnittAutomation

/// D95's opt-in, and specifically the part `PermissionLadder` does not already
/// cover: the CONFIRMATION STAMP.
///
/// The ladder's own sequence is pinned exhaustively by `EventLoggingToggleTests`
/// and `MicrophoneToggleTests`, and this toggle shares it rather than keeping a
/// third copy — so the tests here are the ones that would still pass against a
/// correct ladder wired to a wrong `persist`. That distinction is the whole
/// value of this file: an `apply` that stores `unattendedRecordingEnabled =
/// true` and forgets the date satisfies every sibling assertion and produces a
/// grant that reads `.off` forever.
@Suite(.serialized)
@MainActor
struct UnattendedRecordingToggleTests {
    init() { _ = NSApplication.shared }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixtureDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.snitt.test.unattended.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        // §5.3's global opt-in is a precondition, not part of what is tested
        // here — `unattendedGrant` is deliberately subordinate to it, so
        // without this every assertion below would read `.off` for the wrong
        // reason and the file would pass against any implementation at all.
        var agent = AgentSettings.load(defaults)
        agent.agentRecordingEnabled = true
        agent.save(to: defaults)
        return (defaults, suiteName)
    }

    @Test("Turning it on stamps the confirmation, so the grant is actually active")
    func enablingStampsTheConfirmation() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let applied = UnattendedRecordingToggle.apply(
            true, defaults: defaults, now: { epoch },
            preExplain: { _ in true }, hasRequested: { _ in false }, markRequested: { _ in },
            ensureGranted: { true }, showAlreadyDenied: {})

        #expect(applied == true)
        let stored = AgentSettings.load(defaults)
        #expect(stored.unattendedRecordingEnabled == true)
        #expect(stored.unattendedConfirmedAt == epoch)
        // The assertion that matters. Checking the two stored fields
        // separately is exactly the adjacent-property trap this project has
        // found twenty-six times: what the app asks at record time is the
        // STATUS, and only this line fails against a `persist` that stores the
        // flag and leaves the date nil.
        #expect(stored.unattendedGrant.status(now: epoch)
                == .active(daysRemaining: UnattendedRecordingGrant.renewalDays))
    }

    @Test("Confirming resets the clock rather than inheriting the old window")
    func renewalBuysAFullPeriod() throws {
        // Renewing IS turning it off and on again, so the second confirmation
        // has to be worth a full thirty days. An implementation that only wrote
        // the date when there was not one already would leave a renewal
        // expiring on the original schedule — the person would do the ritual
        // and get nothing for it.
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        UnattendedRecordingToggle.apply(true, defaults: defaults, now: { epoch },
                                        preExplain: { _ in true }, hasRequested: { _ in true },
                                        markRequested: { _ in }, ensureGranted: { true },
                                        showAlreadyDenied: {})
        UnattendedRecordingToggle.apply(false, defaults: defaults, now: { epoch },
                                        preExplain: { _ in true }, ensureGranted: { true },
                                        showAlreadyDenied: {})

        let later = epoch.addingTimeInterval(29 * 86_400)
        UnattendedRecordingToggle.apply(true, defaults: defaults, now: { later },
                                        preExplain: { _ in true }, hasRequested: { _ in true },
                                        markRequested: { _ in }, ensureGranted: { true },
                                        showAlreadyDenied: {})

        let stored = AgentSettings.load(defaults)
        #expect(stored.unattendedConfirmedAt == later)
        #expect(stored.unattendedGrant.status(now: later)
                == .active(daysRemaining: UnattendedRecordingGrant.renewalDays))
    }

    @Test("Turning it off clears the confirmation, not just the flag")
    func disablingClearsTheConfirmation() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        UnattendedRecordingToggle.apply(true, defaults: defaults, now: { epoch },
                                        preExplain: { _ in true }, hasRequested: { _ in false },
                                        markRequested: { _ in }, ensureGranted: { true },
                                        showAlreadyDenied: {})
        UnattendedRecordingToggle.apply(false, defaults: defaults, now: { epoch },
                                        preExplain: { _ in true }, ensureGranted: { true },
                                        showAlreadyDenied: {})

        let stored = AgentSettings.load(defaults)
        #expect(stored.unattendedRecordingEnabled == false)
        #expect(stored.unattendedConfirmedAt == nil,
                "a cleared opt-in that keeps its date lets the next enable inherit a window nobody confirmed")
    }

    @Test("A refused Screen Recording grant leaves no confirmation behind")
    func refusedGrantStampsNothing() throws {
        // The honesty rule, at the point it matters most: a stamp written
        // without the OS grant behind it is a promise that an unattended
        // machine will keep recording, made by an app that cannot record at
        // all. `EventLoggingToggle`'s history is the same rule for a checkmark.
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let applied = UnattendedRecordingToggle.apply(
            true, defaults: defaults, now: { epoch },
            preExplain: { _ in true }, hasRequested: { _ in true }, markRequested: { _ in },
            ensureGranted: { false }, showAlreadyDenied: {})

        #expect(applied == false)
        let stored = AgentSettings.load(defaults)
        #expect(stored.unattendedRecordingEnabled == false)
        #expect(stored.unattendedConfirmedAt == nil)
        #expect(stored.unattendedGrant.status(now: epoch) == .off)
    }

    @Test("Declining the pre-explain leaves no confirmation behind")
    func decliningPreExplainStampsNothing() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let applied = UnattendedRecordingToggle.apply(
            true, defaults: defaults, now: { epoch },
            preExplain: { _ in false }, ensureGranted: { true }, showAlreadyDenied: {})

        #expect(applied == false)
        #expect(AgentSettings.load(defaults).unattendedConfirmedAt == nil)
    }

    @Test("It asks for Screen Recording, not one of the other two services")
    func itConfirmsTheRightPermission() throws {
        // The service is the reason this toggle exists — confirming Microphone
        // or Input Monitoring here would satisfy every other assertion in this
        // file and leave the actual unattended blocker unconfirmed. The
        // `hasRequested`/`markRequested` are the production defaults here,
        // un-overridden on purpose — they route through `PermissionOnboarding`,
        // which records WHICH service was asked for, in the fixture store.
        //
        // `preExplain` is always overridden, in every test in this file:
        // the real one calls `NSAlert.runModal()`, which on a headless runner
        // does not fail, it HANGS — and `swift test` exits 0 on a hung or
        // crashed bundle with no summary line, so the first draft of this test
        // burned ten minutes looking like nothing at all.
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        UnattendedRecordingToggle.apply(true, defaults: defaults, now: { epoch },
                                        preExplain: { _ in true },
                                        ensureGranted: { true }, showAlreadyDenied: {})

        #expect(PermissionOnboarding.hasRequested(.screenRecording, defaults: defaults),
                "Screen Recording was never asked for, so this toggle confirmed the wrong permission")
        #expect(PermissionOnboarding.hasRequested(.microphone, defaults: defaults) == false)
        #expect(PermissionOnboarding.hasRequested(.inputMonitoring, defaults: defaults) == false)
    }
}
