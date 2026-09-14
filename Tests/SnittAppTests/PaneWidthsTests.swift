// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// Remembered pane widths.
///
/// No test here touches `.standard`: writing a real preference domain from a
/// test is the thing this project verifies by MTIME elsewhere, so each test
/// gets a throwaway suite it also removes.
@Suite
struct PaneWidthsTests {
    private func defaults() -> (UserDefaults, () -> Void) {
        let name = "com.snitt.test.panes.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (store, { store.removePersistentDomain(forName: name) })
    }

    @Test("A width survives a save and load")
    func widthRoundTrips() {
        let (store, cleanup) = defaults()
        defer { cleanup() }
        PaneWidths(markers: 320, transcript: 420).save(to: store)
        let loaded = PaneWidths.load(store)
        #expect(loaded.markers == 320)
        #expect(loaded.transcript == 420)
    }

    @Test("A first run gets the designed defaults, not the minimums")
    func firstRunUsesDefaults() {
        // `double(forKey:)` returns 0 for a key never written, and 0 clamps UP
        // to the minimum — so a naive load would open every first run with a
        // 180pt rail instead of the 260 it was designed at. "Never set" and
        // "set to something small" have to stay different answers.
        let (store, cleanup) = defaults()
        defer { cleanup() }
        let loaded = PaneWidths.load(store)
        #expect(loaded.markers == PaneWidths.defaultMarkers)
        #expect(loaded.transcript == PaneWidths.defaultTranscript)
    }

    @Test("A pane cannot be dragged away to nothing")
    func widthsClampAtTheMinimum() {
        // A pane dragged to nothing is indistinguishable from a pane that
        // failed to appear.
        #expect(PaneWidths.clampMarkers(0) == PaneWidths.minimumMarkers)
        #expect(PaneWidths.clampMarkers(-500) == PaneWidths.minimumMarkers)
        #expect(PaneWidths.clampTranscript(10) == PaneWidths.minimumTranscript)
    }

    @Test("A pane cannot be dragged over the picture")
    func widthsClampAtTheMaximum() {
        // Past this the pane competes with the recording rather than
        // supporting it, which is the thing the layout exists to protect.
        #expect(PaneWidths.clampMarkers(5000) == PaneWidths.maximumMarkers)
        #expect(PaneWidths.clampTranscript(5000) == PaneWidths.maximumTranscript)
    }

    @Test("A stored width outside today's bounds comes back usable")
    func storedWidthsAreClampedOnLoad() {
        // A value written by a build with different bounds must not strand the
        // window in a state you cannot drag out of. Clamping on load as well
        // as on save is what makes that impossible.
        let (store, cleanup) = defaults()
        defer { cleanup() }
        store.set(9000.0, forKey: "com.impressiver.snitt.paneWidth.markers")
        store.set(1.0, forKey: "com.impressiver.snitt.paneHeight.transcript")
        let loaded = PaneWidths.load(store)
        #expect(loaded.markers == PaneWidths.maximumMarkers)
        #expect(loaded.transcript == PaneWidths.minimumTranscript)
    }

    @Test("A transcript WIDTH left by an older build is not read back as a height")
    func retiredWidthKeyIsNotReused() {
        // The transcript used to be a column on the right and its width was
        // stored. It is a stacked pane now and the number means a height. 340
        // is a perfectly ordinary width AND a perfectly ordinary height, so
        // reusing the key would silently reinterpret one as the other and look
        // entirely plausible doing it — the pane would simply open at a size
        // nobody chose.
        let (store, cleanup) = defaults()
        defer { cleanup() }
        store.set(340.0, forKey: "com.impressiver.snitt.paneWidth.transcript")
        #expect(PaneWidths.load(store).transcript == PaneWidths.defaultTranscript)
    }

    @Test("Saving clears the retired width key rather than leaving it behind")
    func savingRetiresTheOldKey() {
        // A stale key nothing reads is a value a later reader can find and
        // believe.
        let (store, cleanup) = defaults()
        defer { cleanup() }
        store.set(340.0, forKey: "com.impressiver.snitt.paneWidth.transcript")
        PaneWidths(markers: 300, transcript: 300).save(to: store)
        #expect(store.object(forKey: "com.impressiver.snitt.paneWidth.transcript") == nil)
    }

    @Test("Saving does not touch the real preference domain")
    func savingIsScopedToItsStore() {
        // The rule this project checks by MTIME elsewhere: a test must not
        // write the user's own preferences.
        let (store, cleanup) = defaults()
        defer { cleanup() }
        PaneWidths(markers: 300, transcript: 400).save(to: store)
        #expect(UserDefaults.standard
            .object(forKey: "com.impressiver.snitt.paneWidth.markers") == nil)
    }
}
