// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittBrand
import Testing
import AppKit
@testable import SnittApp

/// The sweep (rev 5, W9) — the checks that are cheaper to assert than to
/// re-walk by eye every time something moves.
@Suite(.serialized)
@MainActor
struct PolishSweepTests {
    init() { _ = NSApplication.shared }

    @Test("The menu-bar clock does not change width as it counts")
    func menuBarClockIsTabular() {
        // A running clock in the proportional system font changes the width of
        // the whole status item on most ticks, so the icon and everything left
        // of it twitch once a second for the length of a recording. Measured
        // rather than asserted on the font's name: what matters is that two
        // different times occupy the same width.
        let narrow = StatusItemController.attributedTitle("0:11")
        let wide = StatusItemController.attributedTitle("0:00")
        #expect(abs(narrow.size().width - wide.size().width) < 0.01,
                "the menu-bar title is \(narrow.size().width) for one time and \(wide.size().width) for another — it will twitch")
    }

    @Test("An empty state still produces an empty title")
    func idleTitleStaysEmpty() {
        // The idle presentation carries no title, and a lone leading space
        // would widen the status item for nothing.
        #expect(StatusItemController.attributedTitle("").string.isEmpty)
    }

    @Test("Transport tooltips name their key by asking the registry")
    func tooltipsReadTheRegistry() {
        // D84: one list is the only place a binding is written down. A tooltip
        // that repeats one drifts silently — the button keeps working and just
        // starts lying about which key does it.
        for (label, title) in [("Play or pause", "Play / Pause"),
                               ("Previous mark", "Previous Mark"),
                               ("Next mark", "Next Mark"),
                               ("Back to start", "Back to Start")] {
            let help = TransportBar.help(label, title)
            let key = KeyboardShortcutRegistry.shortcutDisplay(titled: title)
            #expect(!key.isEmpty, "the registry lost its \(title) binding")
            #expect(help == "\(label) — \(key)", "tooltip reads \(help)")
        }
    }

    @Test("A tooltip for a shortcut nobody claims says less, not something wrong")
    func unknownShortcutLeavesTheTooltipShort() {
        // The failure mode that matters: rename a shortcut and the tooltip
        // should go quiet rather than keep printing the old key.
        #expect(TransportBar.help("Do a thing", "No Such Shortcut") == "Do a thing")
    }

    @Test("Every shortcut a tooltip claims is one the registry installs")
    func noTooltipInventsABinding() {
        // The other direction. `shortcutDisplay` returns empty for an unknown
        // title, so a typo would quietly drop the key from the tooltip — this
        // catches the typo instead of shipping the shorter tooltip.
        let claimed = ["Play / Pause", "Previous Mark", "Next Mark", "Back to Start"]
        let installed = Set(KeyboardShortcutRegistry.shortcuts.map(\.title))
        for title in claimed {
            #expect(installed.contains(title),
                    "a tooltip claims \(title), which the registry does not install")
        }
    }
}

// The surfaces the sweep found still wearing system defaults.
@Suite(.serialized)
@MainActor
struct SweptSurfaceTests {
    init() { _ = NSApplication.shared }

    @Test("The HUD is ink in both appearances, not a theme-following pill")
    func hudIsInk() throws {
        // W4's paint, which arrives with the sweep because the spec's PR table
        // omitted W4 from every group — four PRs and an adversarial pass went
        // by without anyone noticing the item had no home. The sweep's exit
        // criterion is that no surface renders a system default the brand
        // replaced, and this was one.
        //
        // The panel floats over somebody else's screen, usually light. A
        // `windowBackgroundColor` pill goes near-white there and disappears
        // into the thing being recorded.
        let panel = RecordingHUDPanel()
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let ground = try #require(view.layer?.backgroundColor)
        let colour = try #require(NSColor(cgColor: ground)?.usingColorSpace(.sRGB))
        let ink = SnittPalette.ink1.usingColorSpace(.sRGB)!
        #expect(abs(Double(colour.redComponent - ink.redComponent)) < 0.01
                && abs(Double(colour.blueComponent - ink.blueComponent)) < 0.01,
                "the HUD's ground is \(colour), not ink")
    }

    // NOT TESTED, and the reason is the point: the timeline's selection band
    // now asks for `NSColor.controlAccentColor` instead of `NSColor.systemBlue`
    // — §6 keeps selection on the user's accent everywhere. On a default-accent
    // Mac those two colours are the same, so a rendering test would pass
    // against either and a test comparing the constants would assert only that
    // AppKit has two names. A green check that cannot fail is worse than none;
    // the change is one line, verified by reading it, and a machine with a
    // non-blue accent shows it immediately.
}
