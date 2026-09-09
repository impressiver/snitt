// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

// Every `NSWindow` this app creates must set `isReleasedWhenClosed = false`.
//
// The property defaults to TRUE for a programmatically created window. Under
// ARC that is an over-release: the owning controller holds a strong reference,
// and AppKit's window-animation machinery holds one too, so closing the window
// frees it out from under both. The dangling object surfaces later as
// EXC_BAD_ACCESS in `objc_release` inside `-[_NSWindowTransformAnimation
// dealloc]` during a CATransaction commit — a stack that names the animation
// rather than the real cause, which is why a first attempt at this crash
// disabled window animations instead of fixing the lifetime.
//
// `EditorWindowController` has set it since M4a. `SettingsWindowController` was
// added in M5c and did not, and a user hit the crash on shipped v0.1.0 by
// toggling "Log input events" in that window.
//
// This suite asserts the property on every window type rather than on the one
// that broke, because the defect is a default nobody overrode — a third window
// would inherit it exactly the same way.
@Suite(.serialized)
@MainActor
struct WindowLifetimeTests {
    init() { _ = NSApplication.shared }

    @Test("The Settings window is not released when closed")
    func settingsWindowIsNotReleasedWhenClosed() async throws {
        try await EditorWindowTestGate.run {
            let suiteName = "com.snitt.test.windowlifetime.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            SettingsWindowController.resetForTesting()
            defer { SettingsWindowController.resetForTesting() }

            SettingsWindowController.show(
                updater: UpdaterController(settings: UpdateSettings(automaticChecksEnabled: false)),
                defaults: defaults,
                activate: false)

            let controller = try #require(SettingsWindowController.shared)
            // Asserting the property, not "closing it did not crash". A
            // use-after-free is nondeterministic: a test that closes the window
            // and survives passes against the bug most of the time, which is
            // worse than no test, because it reads as coverage.
            #expect(controller.window.isReleasedWhenClosed == false)
        }
    }

    @Test("The editor window is not released when closed")
    func editorWindowIsNotReleasedWhenClosed() async throws {
        try await EditorWindowTestGate.run {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "window-lifetime-\(UUID().uuidString).snitt")
            let bundle = try SnittBundle(creatingAt: root)
            defer { try? FileManager.default.removeItem(at: root) }
            try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0)
            try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
            try EventLog(events: []).write(to: bundle)
            try EditDecisionList.fullRange().write(to: bundle)

            let controller = try await DocumentOpener.open(bundleURL: root)
            defer { controller.close() }

            #expect(controller.window.isReleasedWhenClosed == false)
        }
    }
}
