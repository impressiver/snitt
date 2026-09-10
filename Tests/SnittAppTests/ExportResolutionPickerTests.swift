// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// The resolution menu in the export save panel.
///
/// `.serialized` with `NSApplication.shared` touched in `init`: `NSApp` is nil
/// in a test bundle until something asks for it, and building an `NSView`
/// before that has crashed this suite's neighbours before.
///
/// What is asserted here is the WIRING — that the control shows exactly what
/// `ExportPreflight` decided and reports back what was picked. What is worth
/// offering, and how it is worded, is asserted in `ExportPreflightTests`
/// against no view at all.
@Suite(.serialized)
@MainActor
struct ExportResolutionPickerTests {
    init() { _ = NSApplication.shared }

    private func options() -> [ExportOption] {
        [ExportOption(resolution: .source, width: 1512, height: 982, maxBytes: 41_000_000),
         ExportOption(resolution: .hd720p, width: 1280, height: 831, maxBytes: 24_000_000),
         ExportOption(resolution: .sd480p, width: 640, height: 416, maxBytes: 6_400_000)]
    }

    @Test("Before the estimates land the menu is inert, and export still means source")
    func startsInert() {
        // The panel is shown before the numbers exist. A live popup over an
        // empty menu would invite a choice from nothing; worse, a
        // `selectedResolution` that guessed here would silently change the
        // file for someone who pressed Export immediately.
        let picker = ExportResolutionPicker()
        #expect(picker.isEnabledForTesting == false)
        #expect(picker.menuTitlesForTesting == ["Measuring…"])
        #expect(picker.selectedResolution == .source)
    }

    @Test("The menu shows exactly what ExportPreflight decided")
    func menuMirrorsThePreflight() {
        // Not "the menu has three items" — the titles themselves, so a view
        // that built its own labels instead of using `menuTitle` fails. Two
        // places deciding how a resolution is described is how the GUI and
        // the CLI drift apart.
        let picker = ExportResolutionPicker()
        picker.populate(with: options())
        #expect(picker.menuTitlesForTesting == options().map(\.menuTitle))
        #expect(picker.isEnabledForTesting)
    }

    @Test("The default selection is source, so an untouched panel exports what it always did")
    func defaultsToSource() {
        let picker = ExportResolutionPicker()
        picker.populate(with: options())
        #expect(picker.selectedResolution == .source)
    }

    @Test("Picking a row reports that row's resolution back")
    func selectionIsReported() {
        // The whole point of the control. A `selectedResolution` hard-wired to
        // `.source` passes every other test in this file.
        let picker = ExportResolutionPicker()
        picker.populate(with: options())
        picker.selectForTesting(1)
        #expect(picker.selectedResolution == .hd720p)
        picker.selectForTesting(2)
        #expect(picker.selectedResolution == .sd480p)
    }

    @Test("A failed measurement disables the menu and says so, without blocking export")
    func emptyOptionsDegradeGracefully() {
        // Estimating builds a whole composition and can fail. Losing the menu
        // must not lose the export — the fallback is the behaviour that
        // shipped before the menu existed.
        let picker = ExportResolutionPicker()
        picker.populate(with: [])
        #expect(picker.isEnabledForTesting == false)
        #expect(picker.selectedResolution == .source)
        #expect(picker.caveatForTesting.contains("could not be measured"))
    }

    @Test("Repopulating with a shorter menu does not carry a stale selection")
    func repopulatingResetsTheSelection() {
        // Note what this does and does not prove. `NSPopUpButton.removeAllItems`
        // resets the selection to the first item, so a stale index cannot
        // survive a repopulate and this test passes even with the bounds guard
        // in `selectedResolution` removed — it verifies AppKit's behaviour, not
        // the guard's.
        //
        // The guard is still load-bearing, just on a different path: before
        // `populate` runs, the popup shows "Measuring…" at index 0 while
        // `options` is empty, so an unguarded `options[0]` traps. Deleting the
        // guard makes `startsInert` above crash the whole test bundle with
        // "Index out of range" — verified, and worth stating here because a
        // crashed bundle prints no summary line and `swift test` exits 0, so
        // that failure is invisible to anything that only greps for "✘".
        let picker = ExportResolutionPicker()
        picker.populate(with: options())
        picker.selectForTesting(2)
        picker.populate(with: [options()[0]])
        #expect(picker.selectedResolution == .source)
    }
}
