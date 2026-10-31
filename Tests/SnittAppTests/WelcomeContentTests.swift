// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// What the welcome window decides, asserted without the window.
///
/// `WelcomeContent` exists to be testable at all: the window itself cannot
/// run in a headless suite, which is the same reason `LaunchOpenPrompt` and
/// `DockReopen` are pure decisions with thin AppKit around them.
@Suite
struct WelcomeContentTests {

    // MARK: - Which guidance shows

    @Test("With no recordings, the window explains how to make one")
    func noRecordingsGetsGettingStarted() {
        #expect(WelcomeContent.guidance(hasRecordings: false,
                                        recordShortcut: "⌥⌘5",
                                        tipIndex: 0) == .gettingStarted)
    }

    @Test("Once there are recordings, it switches to a tip")
    func recordingsGetATip() {
        let guidance = WelcomeContent.guidance(hasRecordings: true,
                                               recordShortcut: "⌥⌘5",
                                               tipIndex: 0)
        guard case .tip(let text) = guidance else {
            Issue.record("expected a tip, got \(guidance)")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test("Deleting every recording puts the getting-started copy back")
    func emptyingTheListRestoresGettingStarted() {
        // The consequence of deriving this from state rather than from a
        // one-shot flag, asserted rather than left implicit. Somebody with no
        // recordings is starting over, and a flag spent on the first launch
        // would have meant the help was gone for good the moment the window
        // was closed by reflex.
        #expect(WelcomeContent.guidance(hasRecordings: true, recordShortcut: "⌥⌘5",
                                        tipIndex: 0) != .gettingStarted)
        #expect(WelcomeContent.guidance(hasRecordings: false, recordShortcut: "⌥⌘5",
                                        tipIndex: 0) == .gettingStarted)
    }

    @Test("Tips rotate, and an ever-growing index keeps wrapping")
    func tipsRotate() {
        let count = WelcomeContent.tips(recordShortcut: "⌥⌘5").count
        let first = WelcomeContent.guidance(hasRecordings: true, recordShortcut: "⌥⌘5", tipIndex: 0)
        let second = WelcomeContent.guidance(hasRecordings: true, recordShortcut: "⌥⌘5", tipIndex: 1)
        #expect(first != second, "a different index must give a different tip")
        // A caller handing this a launch counter must never crash or repeat
        // the first tip early, including once the counter passes the list.
        #expect(WelcomeContent.guidance(hasRecordings: true, recordShortcut: "⌥⌘5",
                                        tipIndex: count) == first)
        #expect(WelcomeContent.guidance(hasRecordings: true, recordShortcut: "⌥⌘5",
                                        tipIndex: count * 7 + 1) == second)
    }

    @Test("A negative index still names a tip rather than trapping")
    func negativeIndexIsSafe() {
        // `%` in Swift keeps the sign of the dividend, so a bare modulo would
        // index with a negative number and trap. Worth pinning because the
        // obvious caller — some counter — can go negative by underflow.
        let guidance = WelcomeContent.guidance(hasRecordings: true,
                                               recordShortcut: "⌥⌘5",
                                               tipIndex: -3)
        guard case .tip = guidance else {
            Issue.record("expected a tip, got \(guidance)")
            return
        }
    }

    @Test("The hotkey tip reports the hotkey the user actually has")
    func tipsReflectAReboundShortcut() {
        // The hotkey is rebindable in Settings, so a literal ⌥⌘5 in the copy
        // would lie to anyone who changed it. A mutant that hardcodes the
        // shipped default fails here and nowhere else.
        let rebound = WelcomeContent.tips(recordShortcut: "⌃⇧9")
        #expect(rebound.contains { $0.contains("⌃⇧9") })
        #expect(!rebound.contains { $0.contains("⌥⌘5") })
    }

    @Test("Every tip is a move, not a feature")
    func tipsTeachAnAction() {
        // The house rule for this slot: a tip has to be useless to somebody
        // who has not installed Snitt. Enforced structurally rather than by
        // eye — each one names a control, a key or a gesture.
        let verbs = ["Hold", "Press", "Select", "Double-click", "Auto-Trim"]
        for tip in WelcomeContent.tips(recordShortcut: "⌥⌘5") {
            #expect(verbs.contains { tip.hasPrefix($0) },
                    "tip does not start with an action: \(tip)")
        }
    }

    // MARK: - Reading a bundle's name

    @Test("An app-led name splits into the app and its git context")
    func nameSplitsAppFromGit() {
        let parts = WelcomeContent.name(forStem: "Safari-main-a1b2c3d-1788464616")
        #expect(parts.title == "Safari")
        #expect(parts.detail == "main · a1b2c3d")
    }

    @Test("The timestamp never shows")
    func timestampIsDropped() {
        let parts = WelcomeContent.name(forStem: "Xcode-feat-hover-9f2c1ab-1788451002")
        #expect(parts.title == "Xcode")
        #expect(parts.detail?.contains("1788451002") == false)
    }

    @Test("A name with nothing but an app and a timestamp has no detail")
    func appOnlyHasNoDetail() {
        let parts = WelcomeContent.name(forStem: "Snitt-1788464616")
        #expect(parts.title == "Snitt")
        #expect(parts.detail == nil)
    }

    @Test("A commit is not mistaken for a timestamp")
    func commitSurvives() {
        // Only an all-digit trailing run is the timestamp. "a1b2c3d" is not,
        // and a mutant that strips the last component unconditionally loses
        // the commit — the more identifying half of the git context.
        let parts = WelcomeContent.name(forStem: "Safari-main-a1b2c3d")
        #expect(parts.detail == "main · a1b2c3d")
    }

    @Test("A name that does not match the shape comes back whole")
    func unparseableNameIsKeptIntact() {
        // An imported video or a hand-renamed bundle. Degrading to the whole
        // stem beats guessing at a structure that is not there.
        #expect(WelcomeContent.name(forStem: "Standup").title == "Standup")
        #expect(WelcomeContent.name(forStem: "Standup").detail == nil)
    }

    // MARK: - Recents

    @Test("A bundle that is no longer on disk is not offered")
    func missingBundlesAreFiltered() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let real = folder.appendingPathComponent("Safari-main-a1b2c3d-100.snitt")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let gone = folder.appendingPathComponent("Xcode-main-d4e5f6g-200.snitt")

        // `NSDocumentController.recentDocumentURLs` keeps entries whose files
        // have moved or been deleted, and `RecentDocuments` passes them
        // through raw. A row that errors when clicked is worse than a short
        // list, and this is the only thing standing between the two.
        let entries = WelcomeContent.recents(from: [gone, real])
        #expect(entries.count == 1)
        #expect(entries.first?.url == real)
    }

    @Test("Recents are newest first, whatever order they arrive in")
    func recentsAreSortedByDate() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [URL] = []
        for (index, name) in ["Old", "Newest", "Middle"].enumerated() {
            let url = folder.appendingPathComponent("\(name)-main-abc-\(index).snitt")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let stamp = Date(timeIntervalSince1970: 1_700_000_000
                             + Double(["Old": 0, "Newest": 9_000, "Middle": 4_000][name]!))
            try FileManager.default.setAttributes([.modificationDate: stamp],
                                                  ofItemAtPath: url.path)
            urls.append(url)
        }

        // Deliberately NOT the order they were handed over. `recentDocumentURLs`
        // is most-recently-OPENED, which on a list captioned with dates shows a
        // visibly non-monotonic column.
        let titles = WelcomeContent.recents(from: urls).map(\.title)
        #expect(titles == ["Newest", "Middle", "Old"])
    }

    @Test("The list is capped")
    func recentsAreCapped() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [URL] = []
        for index in 0..<9 {
            let url = folder.appendingPathComponent("App\(index)-main-abc-\(index).snitt")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            urls.append(url)
        }
        #expect(WelcomeContent.recents(from: urls, limit: 4).count == 4)
        #expect(WelcomeContent.recents(from: urls, limit: 0).isEmpty)
    }

    // MARK: - Permissions

    @Test("A plain install is asked about Screen Recording and nothing else")
    func onlyScreenRecordingByDefault() {
        // Microphone matters only with voiceover on, Input Monitoring only
        // with input logging on — `PermissionOnboarding.Service.why` says so
        // in as many words. Listing all three unconditionally would show a
        // fresh install two warnings for features nobody switched on.
        let rows = WelcomeContent.permissionRows(screenRecordingGranted: true,
                                                 microphoneGranted: false,
                                                 inputMonitoringGranted: false,
                                                 microphoneEnabled: false,
                                                 inputLoggingEnabled: false)
        #expect(rows.map(\.service) == [.screenRecording])
        #expect(WelcomeContent.needsAttention(rows) == false)
    }

    @Test("Turning on voiceover adds the microphone row")
    func microphoneAppearsWithVoiceover() {
        let rows = WelcomeContent.permissionRows(screenRecordingGranted: true,
                                                 microphoneGranted: false,
                                                 inputMonitoringGranted: false,
                                                 microphoneEnabled: true,
                                                 inputLoggingEnabled: false)
        #expect(rows.map(\.service) == [.screenRecording, .microphone])
        #expect(WelcomeContent.needsAttention(rows))
    }

    @Test("Turning on input logging adds the Input Monitoring row")
    func inputMonitoringAppearsWithLogging() {
        let rows = WelcomeContent.permissionRows(screenRecordingGranted: true,
                                                 microphoneGranted: true,
                                                 inputMonitoringGranted: true,
                                                 microphoneEnabled: true,
                                                 inputLoggingEnabled: true)
        #expect(rows.map(\.service) == [.screenRecording, .microphone, .inputMonitoring])
        #expect(WelcomeContent.needsAttention(rows) == false)
    }

    @Test("Only the two launch-gated services claim a relaunch is needed")
    func relaunchIsClaimedOnlyWhereItIsTrue() {
        // Spike S5 measured `CGRequestScreenCaptureAccess()` returning false
        // while the user was granting; Screen Recording and Input Monitoring
        // both document that the grant lands on the NEXT launch. Microphone
        // explicitly does not — "AVFoundation reports Microphone
        // authorization live" — so telling someone to relaunch for it would
        // be busywork.
        let rows = WelcomeContent.permissionRows(screenRecordingGranted: false,
                                                 microphoneGranted: false,
                                                 inputMonitoringGranted: false,
                                                 microphoneEnabled: true,
                                                 inputLoggingEnabled: true)
        let relaunch = Dictionary(uniqueKeysWithValues:
            rows.map { ($0.service, $0.requiresRelaunch) })
        #expect(relaunch[.screenRecording] == true)
        #expect(relaunch[.inputMonitoring] == true)
        #expect(relaunch[.microphone] == false)
    }

    @Test("A missing permission is what shows the section")
    func attentionTracksTheMissingOnes() {
        // Nothing missing means no section at all, rather than a row of green
        // ticks on the app's front door.
        let healthy = WelcomeContent.permissionRows(screenRecordingGranted: true,
                                                    microphoneGranted: true,
                                                    inputMonitoringGranted: true,
                                                    microphoneEnabled: true,
                                                    inputLoggingEnabled: true)
        #expect(WelcomeContent.needsAttention(healthy) == false)

        let denied = WelcomeContent.permissionRows(screenRecordingGranted: false,
                                                   microphoneGranted: true,
                                                   inputMonitoringGranted: true,
                                                   microphoneEnabled: true,
                                                   inputLoggingEnabled: true)
        #expect(WelcomeContent.needsAttention(denied))
    }
}
