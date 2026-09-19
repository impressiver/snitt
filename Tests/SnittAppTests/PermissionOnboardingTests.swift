// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.onboarding.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("A service is pre-explained the first time and never again")
func preExplainHappensOnce() {
    // §4.10: the sheet exists so the system dialog is expected. Showing it on
    // every recording would be nagging, which is the thing it prevents.
    let defaults = emptyDefaults()
    #expect(PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults))
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(!PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults))
}

@Test("Services are tracked independently")
func servicesAreIndependent() {
    // Marking screen recording explained must not silently consume the
    // microphone's first-run explanation — that is the second rung of §4.10's
    // ladder and the user has not seen it yet.
    let defaults = emptyDefaults()
    PermissionOnboarding.markPreExplained(.screenRecording, defaults: defaults)
    #expect(PermissionOnboarding.shouldPreExplain(.microphone, defaults: defaults))
}

@Test("Every service deep-links to a distinct Settings pane")
func everyServiceHasADistinctSettingsPane() {
    let urls = PermissionOnboarding.Service.allCases.map {
        PermissionOnboarding.settingsURL(for: $0).absoluteString
    }
    #expect(urls.allSatisfy { $0.hasPrefix("x-apple.systempreferences:") })
    #expect(Set(urls).count == urls.count, "a shared pane would send users to the wrong list")
}

@Test("The system prompt is recorded as raised, per service")
func requestsAreTrackedPerService() {
    let defaults = emptyDefaults()
    #expect(!PermissionOnboarding.hasRequested(.screenRecording, defaults: defaults))
    PermissionOnboarding.markRequested(.screenRecording, defaults: defaults)
    #expect(PermissionOnboarding.hasRequested(.screenRecording, defaults: defaults))
    #expect(!PermissionOnboarding.hasRequested(.microphone, defaults: defaults),
            "asking for one service must not claim another was asked for")
}

@Test("A first-run denial is not reported as a denial")
func firstDenialMeansTheDialogIsUp() {
    // Spike S5: `CGRequestScreenCaptureAccess()` returns false WHILE the user
    // is granting in the dialog it just raised. So on a genuine first run the
    // sequence was pre-explain → system dialog appears → request returns false
    // → "Screen Recording is turned off for Snitt. macOS only asks once."
    // displayed ON TOP of the live dialog, telling the user their correct
    // action had failed.
    #expect(PermissionOnboarding.followUp(deniedHavingAskedBefore: false)
            == .awaitingRelaunch)
    // Only once Snitt has actually asked before does macOS refuse to ask
    // again — which is the state the already-denied sheet describes.
    #expect(PermissionOnboarding.followUp(deniedHavingAskedBefore: true)
            == .alreadyDenied)
}

/// Drops `//` line comments so a mention in prose is not read as a call.
///
/// Deliberately crude — it does not understand block comments or string
/// literals — because it errs toward seeing MORE code, which can only produce
/// a false failure a human then reads, never a silent pass.
private func withoutLineComments(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex..<range.lowerBound]
        }
        .joined(separator: "\n")
}

@Test("The coordinator raises no modal, because an agent shares that code path")
func theCoordinatorNeverBlocksOnAHuman() throws {
    // The discriminating check. `startRecording` used to call
    // `PermissionOnboarding.preExplain` and `showAlreadyDenied` — both
    // `NSAlert.runModal()` — inside the critical section that `toggle()` and
    // `startForAgent()` share, while `isTransitioning` was held. An agent's
    // `snitt record start` on an ungranted machine therefore put a modal on a
    // person's screen and blocked the socket until someone clicked it, with
    // the kill switch disabled meanwhile; and `swift test` hung, or trapped
    // with no `NSApplication`, on any machine without the grant.
    let url = URL(fileURLWithPath: #filePath)     // Tests/SnittAppTests/…
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/SnittApp/RecordingCoordinator.swift")
    let source = withoutLineComments(try String(contentsOf: url, encoding: .utf8))

    for offender in ["NSAlert", "runModal", "PermissionOnboarding"] {
        #expect(!source.contains(offender),
                "\(offender) in RecordingCoordinator blocks the agent path on a human click")
    }
}

@MainActor
@Test("Declining the explanation does not consume it")
func decliningPreExplainLeavesItUnspent() {
    // The bug this fixes: `markPreExplained` ran BEFORE `runModal`, so the
    // one-time explanation was spent the moment the sheet appeared, however
    // the person answered it. Snitt is a menu-bar app and its own comment on
    // `preExplain` says a background app's modal "can open behind whatever the
    // user is looking at" — so dismissing it, missing it, or choosing Not now
    // all burned the explanation, reverted the checkbox, and said nothing.
    // The setting then worked on the next attempt, which is what made it look
    // intermittent rather than broken.
    //
    // Discriminates against marking before the answer: that implementation
    // returns false here too, so only the SECOND expectation catches it.
    let defaults = emptyDefaults()
    let accepted = PermissionOnboarding.preExplain(.screenRecording,
                                                   defaults: defaults,
                                                   ask: { false })
    #expect(accepted == false, "Not now must refuse the toggle")
    #expect(PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults),
            "a declined explanation must still be owed, not silently spent")
}

@MainActor
@Test("Accepting the explanation spends it, so it is not shown twice")
func acceptingPreExplainSpendsIt() {
    // The other half, and the reason the fix is not simply "never mark":
    // §4.10's sheet exists so the system dialog is expected, and showing it on
    // every attempt is the nagging `preExplainHappensOnce` guards against.
    let defaults = emptyDefaults()
    #expect(PermissionOnboarding.preExplain(.screenRecording,
                                            defaults: defaults, ask: { true }))
    #expect(!PermissionOnboarding.shouldPreExplain(.screenRecording, defaults: defaults))
    // And a second call must not ask again: it short-circuits to true.
    var askedAgain = false
    #expect(PermissionOnboarding.preExplain(.screenRecording, defaults: defaults,
                                            ask: { askedAgain = true; return false }))
    #expect(!askedAgain, "an explanation already given must not be asked again")
}
