// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp

/// Covers the window File ▸ New opens, which is built on `WelcomeContent`
/// (see `WelcomeContentTests` for the decisions that layer owns). These
/// tests stay one level up: given a decision, did the window build the
/// right thing — a permission section or not, N recents rows or zero, the
/// real hotkey's caption rather than a hardcoded one — and does showing it
/// twice reuse the window rather than stacking a second one.
///
/// Per this suite's own house rule (see `SettingsWindowTests`), every test
/// that touches `UserDefaults` gets its own throwaway suite rather than
/// `.standard`, so one test's state can never leak into another's — and
/// `WelcomeWindow.resetForTesting()` plays the same role for the static
/// `open` list that `EmptyDocumentWindow.resetForTesting()` plays for that
/// window.
@Suite(.serialized)
@MainActor
struct WelcomeWindowTests {
    init() { _ = NSApplication.shared }

    private func fixtureDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.snitt.test.welcome.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private func noOpShow(defaults: UserDefaults,
                          recentURLs: [URL] = [],
                          screenRecordingGranted: Bool = true,
                          microphoneGranted: Bool = true,
                          inputMonitoringGranted: Bool = true) -> WelcomeWindow {
        WelcomeWindow.show(defaults: defaults,
                           recentURLs: recentURLs,
                           screenRecordingGranted: screenRecordingGranted,
                           microphoneGranted: microphoneGranted,
                           inputMonitoringGranted: inputMonitoringGranted,
                           onRecord: {}, onOpenExisting: {}, onImportVideo: { _ in },
                           onOpenRecent: { _ in }, onDroppedFiles: { _ in },
                           activate: false)
    }

    /// Depth-first walk of a built window's view tree.
    ///
    /// These layout tests need the real hierarchy: the defects they pin
    /// (a centred row title, a caption off the button baseline) are
    /// properties of laid-out frames, so a `private(set)` counter seam like
    /// `recentsRowCount` cannot see them.
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func laidOutContent(_ controller: WelcomeWindow) -> NSView? {
        guard let content = controller.window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func recentsFixture(_ names: [String]) throws -> (URL, [URL]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try names.map { name -> URL in
            let url = folder.appendingPathComponent("\(name).snitt")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return (folder, urls)
    }

    // MARK: - Recents row layout

    @Test("A recents row stacks its two lines against the left edge, clear of the icon")
    func recentsRowIsLeftAlignedAndClearOfTheIcon() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        let (folder, urls) = try recentsFixture(["feature-demos-and-cta-726d2ac-1788464616"])
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
            try? FileManager.default.removeItem(at: folder)
        }

        let controller = noOpShow(defaults: defaults, recentURLs: urls)
        let content = try #require(laidOutContent(controller))
        let row = try #require(descendants(of: content).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == urls[0].absoluteString })

        // The shape of the defect, not just its symptom. The row used to be
        // one `attributedTitle` with a newline in it plus an icon laid over
        // the top; `NSButtonCell` centres a title, so the name floated in
        // the middle of the row and the second line ran under the icon.
        #expect(row.title.isEmpty)
        #expect(row.attributedTitle.length == 0)

        let labels = descendants(of: row).compactMap { $0 as? NSTextField }
        #expect(labels.count == 2)
        let image = try #require(descendants(of: row).compactMap { $0 as? NSImageView }.first)
        for label in labels {
            let frame = label.convert(label.bounds, to: row)
            #expect(frame.minX >= image.convert(image.bounds, to: row).maxX)
        }
        // Both lines share one left edge, which is what "stacked, not
        // centred" means in a frame assertion.
        let lefts = labels.map { $0.convert($0.bounds, to: row).minX }
        #expect(abs((lefts.max() ?? 0) - (lefts.min() ?? 0)) < 0.5)
    }

    @Test("A recents row still announces itself after losing its title")
    func recentsRowKeepsAnAccessibilityLabel() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        let (folder, urls) = try recentsFixture(["Safari-main-a1b2c3d-1788464616"])
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
            try? FileManager.default.removeItem(at: folder)
        }

        // The title moved out of the cell and into sibling labels, which is
        // exactly the change that silently unlabels a button. Catches a
        // mutant that drops `setAccessibilityLabel`.
        let controller = noOpShow(defaults: defaults, recentURLs: urls)
        let content = try #require(laidOutContent(controller))
        let row = try #require(descendants(of: content).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == urls[0].absoluteString })
        let label = try #require(row.accessibilityLabel())
        // Asserted against the two things THIS layer puts in the label, not
        // against how `WelcomeContent.name(forStem:)` happens to split the
        // stem today — that is the content layer's concern and its own tests
        // pin it.
        #expect(label.hasPrefix("Safari"))
        #expect(label.contains("a1b2c3d"))
    }

    // MARK: - Row dates

    @Test("Two recordings on one afternoon do not read identically")
    func rowDatesTellCloseRecordingsApart() throws {
        // THE REGRESSION. `RelativeDateTimeFormatter` rendered both of these
        // as "last month", so the product owner's sidebar showed four
        // different bundles as four identical rows.
        let base = Date(timeIntervalSinceNow: -30 * 24 * 3600)
        let first = WelcomeContent.Entry(url: URL(fileURLWithPath: "/tmp/a.snitt"),
                                         title: "feature-demos-and-cta",
                                         detail: "726d2ac",
                                         modified: base)
        let second = WelcomeContent.Entry(url: URL(fileURLWithPath: "/tmp/b.snitt"),
                                          title: "feature-demos-and-cta",
                                          detail: "726d2ac",
                                          modified: base.addingTimeInterval(37 * 60))
        #expect(WelcomeWindow.rowDetail(first) != WelcomeWindow.rowDetail(second))
    }

    @Test("The row date still carries what the name said")
    func rowDetailKeepsTheCommit() throws {
        let entry = WelcomeContent.Entry(url: URL(fileURLWithPath: "/tmp/a.snitt"),
                                         title: "feature-demos-and-cta",
                                         detail: "726d2ac",
                                         modified: Date())
        // Catches a mutant that drops the name's own detail and leaves the
        // row with nothing but a date.
        #expect(WelcomeWindow.rowDetail(entry).hasPrefix("726d2ac · "))
    }

    @Test("A name with nothing to add gets a date and no stray separator")
    func rowDetailWithoutACommitHasNoSeparator() throws {
        let entry = WelcomeContent.Entry(url: URL(fileURLWithPath: "/tmp/a.snitt"),
                                         title: "Standup", detail: nil, modified: Date())
        let detail = WelcomeWindow.rowDetail(entry)
        #expect(!detail.contains("·"))
        #expect(!detail.isEmpty)
    }

    // MARK: - Bottom edge

    @Test("The menu-bar caption sits on the same line as the sidebar buttons")
    func captionCentresWithTheSidebarButtons() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
        }

        let controller = noOpShow(defaults: defaults)
        let content = try #require(laidOutContent(controller))
        let all = descendants(of: content)
        let caption = try #require(all.compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("Snitt looks like") })
        let open = try #require(all.compactMap { $0 as? NSButton }
            .first { $0.title == "Open…" })

        // Catches a mutant that pins the caption to its column's bottom edge
        // with a hardcoded inset again. A push button's height is a system
        // metric, so any constant that happens to line up today stops lining
        // up the moment AppKit changes it.
        let captionMid = caption.convert(caption.bounds, to: content).midY
        let buttonMid = open.convert(open.bounds, to: content).midY
        #expect(abs(captionMid - buttonMid) < 1.0)
    }

    // MARK: - Mascot keenness and nodding (pure)

    @Test("The mascot is calm when the pointer is nowhere near the button")
    func keennessFarAwayIsZero() {
        // Catches a mutant that drops the outer clamp and lets a far-off
        // pointer compute a negative or unbounded distance ratio instead of
        // flat 0.
        let buttonFrame = NSRect(x: 0, y: 0, width: 120, height: 32)
        let result = WelcomeWindow.keennessAndNodding(pointer: NSPoint(x: 2000, y: 2000),
                                                       buttonFrame: buttonFrame)
        #expect(result.keenness == 0)
        #expect(result.isNodding == false)
    }

    @Test("The mascot is fully keen once the pointer reaches the button")
    func keennessOnButtonIsOne() {
        // Catches a mutant that never reaches 1 — e.g. an off-by-one in the
        // inner-radius comparison that leaves the centre itself just short.
        let buttonFrame = NSRect(x: 100, y: 100, width: 120, height: 32)
        let center = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        let result = WelcomeWindow.keennessAndNodding(pointer: center, buttonFrame: buttonFrame)
        #expect(result.keenness == 1)
        #expect(result.isNodding == true)
    }

    @Test("Keenness climbs monotonically as the pointer closes in")
    func keennessIsMonotonicBetween() {
        // Catches a mutant that swaps the ramp's direction (keen when far,
        // calm when close) or makes it non-monotonic (e.g. a sign error in
        // the interpolation).
        let buttonFrame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let distances: [CGFloat] = [300, 250, 200, 150, 100, 50, 10]
        let keenness = distances.map {
            WelcomeWindow.keennessAndNodding(pointer: NSPoint(x: buttonFrame.midX + $0, y: buttonFrame.midY),
                                             buttonFrame: buttonFrame).keenness
        }
        for (closer, fartherAway) in zip(keenness.dropFirst(), keenness) {
            #expect(closer >= fartherAway, "keenness must not drop as the pointer gets closer")
        }
        #expect(keenness.first! < keenness.last!)
    }

    @Test("Nodding is strictly inside-the-frame, not a radius around it")
    func noddingOnlyInsideFrame() {
        // Catches a mutant that ties `isNodding` to the same radius as
        // keenness (e.g. `distance <= innerRadius`) instead of the actual
        // button frame — which would make the mascot "nod" while hovering
        // empty space near a small button.
        let buttonFrame = NSRect(x: 0, y: 0, width: 10, height: 10)
        let justOutside = NSPoint(x: 20, y: 5) // within the keenness inner radius, outside the frame
        let result = WelcomeWindow.keennessAndNodding(pointer: justOutside, buttonFrame: buttonFrame)
        #expect(result.isNodding == false)
        #expect(result.keenness > 0, "sanity: this point is still within the keen zone")
    }

    // MARK: - Relaunch footnote pluralisation (pure)

    @Test("No missing relaunch-gated permission means no footnote")
    func relaunchLineForZeroIsNil() {
        // Catches a mutant that always returns a string, which would show
        // "Takes effect after you relaunch Snitt" on a healthy launch.
        #expect(WelcomeWindow.relaunchLine(missingCount: 0) == nil)
    }

    @Test("One missing permission gets the singular phrasing")
    func relaunchLineForOne() {
        #expect(WelcomeWindow.relaunchLine(missingCount: 1) == "Takes effect after you relaunch Snitt.")
    }

    @Test("Two missing permissions say \"Both\"")
    func relaunchLineForTwo() {
        // Catches a mutant that falls through to the generic "These" at
        // count 2, which reads oddly for exactly two things.
        #expect(WelcomeWindow.relaunchLine(missingCount: 2) == "Both take effect after you relaunch Snitt.")
    }

    @Test("Three or more missing permissions say \"These\"")
    func relaunchLineForThreeOrMore() {
        // Catches a mutant that hardcodes "Both" for every count >= 2.
        #expect(WelcomeWindow.relaunchLine(missingCount: 3) == "These take effect after you relaunch Snitt.")
    }

    // MARK: - Shortcut caption (pure)

    @Test("The shortcut caption reports the hotkey actually registered, not the shipped default")
    func shortcutCaptionReflectsReboundHotkey() {
        // Catches a mutant that hardcodes "⌥⌘5" in the caption — the hotkey
        // is rebindable in Settings, so a literal here would misreport it
        // for anyone who changed it.
        let rebound = HotkeyCombination(fromKeyEvent: makeKeyEvent(keyCode: 9, modifiers: [.control, .shift]))
        let caption = WelcomeWindow.recordCaption(rebound)
        #expect(caption.contains(rebound.displayString))
        #expect(!caption.contains("⌥⌘5"))
    }

    // MARK: - Headline

    @Test("The headline names the two guidance cases differently")
    func headlineDiffersByGuidance() {
        // Catches a mutant that returns the same string for both cases,
        // which would show "Ready when you are" to someone who has never
        // recorded anything.
        let gettingStarted = WelcomeWindow.headlineText(for: .gettingStarted)
        let tip = WelcomeWindow.headlineText(for: .tip("Hold Shift to record without focusing."))
        #expect(gettingStarted == "Welcome to Snitt")
        #expect(tip == "Ready when you are")
        #expect(gettingStarted != tip)
    }

    // MARK: - Window lifecycle

    @Test("Showing the window twice brings the first one forward")
    func showTwiceReusesWindow() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
        }

        // Catches a mutant that drops the `open.first` reuse check and
        // always constructs a new controller — the same stacking bug
        // `EmptyDocumentWindow.show` guards against for ⌘N.
        let first = noOpShow(defaults: defaults)
        let second = noOpShow(defaults: defaults)
        #expect(first === second)
        #expect(WelcomeWindow.open.count == 1)
    }

    @Test("The window is never released on close, like every other window here")
    func windowIsNotReleasedWhenClosed() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
        }
        // Catches a regression of the over-release trap `WindowLifetimeTests`
        // already pins for other windows: a programmatically created
        // `NSWindow` defaults `isReleasedWhenClosed` to true, which frees it
        // out from under the reference this controller holds.
        let controller = noOpShow(defaults: defaults)
        #expect(controller.window.isReleasedWhenClosed == false)
    }

    // MARK: - Permission section

    @Test("A healthy launch shows no permission section")
    func permissionSectionAbsentWhenHealthy() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
        }
        // Catches a mutant that builds the section unconditionally — a
        // fresh, fully-granted install should show no permission UI at all,
        // not a row of green ticks on the front door.
        let controller = noOpShow(defaults: defaults, screenRecordingGranted: true,
                                  microphoneGranted: true, inputMonitoringGranted: true)
        #expect(controller.hasPermissionSection == false)
    }

    @Test("A missing permission shows the section")
    func permissionSectionPresentWhenMissing() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
        }
        // Catches a mutant that inverts or drops the `needsAttention` gate
        // and never shows the section even when Screen Recording is denied.
        let controller = noOpShow(defaults: defaults, screenRecordingGranted: false,
                                  microphoneGranted: true, inputMonitoringGranted: true)
        #expect(controller.hasPermissionSection == true)
    }

    // MARK: - Recents

    @Test("The sidebar shows exactly one row per filtered recent entry")
    func recentsRowCountMatchesFilteredEntries() throws {
        let (defaults, defaultsSuite) = try fixtureDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            WelcomeWindow.resetForTesting()
            try? FileManager.default.removeItem(at: folder)
        }

        var urls: [URL] = []
        for name in ["Safari-main-a1b2c3d-1", "Xcode-main-d4e5f6g-2"] {
            let url = folder.appendingPathComponent("\(name).snitt")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            urls.append(url)
        }
        // One URL that does not exist on disk — `WelcomeContent.recents`
        // filters it out, and the row count must follow that filtering
        // rather than the raw URL count handed in.
        urls.append(folder.appendingPathComponent("Gone-main-000000-3.snitt"))

        // Catches a mutant that builds a row per URL handed to `show`
        // instead of per entry `WelcomeContent.recents` actually returned.
        let controller = noOpShow(defaults: defaults, recentURLs: urls)
        #expect(controller.recentsRowCount == 2)
    }

    @Test("No recents means no rows, not a placeholder row")
    func emptyRecentsProducesNoRows() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeWindow.resetForTesting()
        }
        // Catches a mutant that always produces at least one row (e.g. a
        // sentinel "no recordings" row counted the same as a real entry).
        let controller = noOpShow(defaults: defaults, recentURLs: [])
        #expect(controller.recentsRowCount == 0)
    }
}

/// A minimal synthetic key-down event, for driving
/// `HotkeyCombination(fromKeyEvent:)` without a real keyboard.
@MainActor
private func makeKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                     timestamp: 0, windowNumber: 0, context: nil,
                     characters: "", charactersIgnoringModifiers: "",
                     isARepeat: false, keyCode: keyCode)!
}
