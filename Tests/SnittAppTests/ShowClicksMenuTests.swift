// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Playback ▸ Show Clicks, and the export agreeing with it.
///
/// The product requirement is one sentence — "if selected in the menu, it's
/// selected in export too" — and it is exactly the kind that passes a test
/// asserting each half separately while the two never meet. So the coupling
/// gets its own assertions, against the value the sheet would actually open
/// with rather than against the preference both sides happen to read.
@Suite(.serialized)
@MainActor
struct ShowClicksMenuTests {
    init() { _ = NSApplication.shared }

    @Test("The Playback menu carries a Show Clicks item")
    func playbackMenuHasTheItem() throws {
        let item = KeyboardShortcutRegistry.playbackMenuItem()
        let submenu = try #require(item.submenu)
        let clicks = try #require(
            submenu.items.first { $0.title == KeyboardShortcutRegistry.showClicksTitle })
        // Asserting the ACTION, not merely that a title exists. An item with
        // no action is disabled and does nothing when picked, which is what
        // "the menu doesn't work" looks like from outside.
        #expect(clicks.action == #selector(AppDelegate.toggleShowClicks(_:)))
    }

    @Test("Show Clicks is a toggle, not one of the keyed shortcuts")
    func showClicksIsNotAShortcut() {
        // It deliberately sits outside `shortcuts`: that array drives the
        // Keyboard Shortcuts help, and an entry with no key would render there
        // as a binding with a blank key. Pins the reason it was appended
        // separately, so a later tidy-up that folds it in fails here.
        #expect(!KeyboardShortcutRegistry.shortcuts.contains {
            $0.title == KeyboardShortcutRegistry.showClicksTitle
        })
        #expect(!KeyboardShortcutRegistry.helpText
            .contains(KeyboardShortcutRegistry.showClicksTitle))
    }

    @Test("The flag round-trips through edit.json, and defaults off")
    func flagRoundTripsThroughTheEDL() throws {
        // Off by default: rings are an annotation, and a bundle that never
        // asked for them must not gain them.
        #expect(EditDecisionList.fullRange().showClicks == false)

        var edl = EditDecisionList.fullRange()
        edl.showClicks = true
        let data = try JSONEncoder().encode(edl)
        let back = try JSONDecoder().decode(EditDecisionList.self, from: data)
        #expect(back.showClicks == true, "the flag did not survive edit.json")
    }

    @Test("An edit.json from before this field still opens, with clicks off")
    func olderBundlesStillOpen() throws {
        // The whole reason this field is additive and does not bump the schema
        // version. A bundle written by any earlier build has no `showClicks`
        // key, and refusing it — or defaulting it on — would break documents
        // that predate the feature.
        let json = """
        {"schemaVersion": 3, "cuts": [], "trackStates": []}
        """
        let edl = try JSONDecoder().decode(EditDecisionList.self,
                                           from: Data(json.utf8))
        #expect(edl.showClicks == false)
    }

    @Test("The flag is written only when on, so an off bundle gains no key")
    func offWritesNoKey() throws {
        // Keeps a file's shape meaningful — and keeps a bundle from before the
        // feature round-tripping without acquiring a key it never had.
        let off = try JSONEncoder().encode(EditDecisionList.fullRange())
        let offText = try #require(String(data: off, encoding: .utf8))
        #expect(!offText.contains("showClicks"))

        var edl = EditDecisionList.fullRange()
        edl.showClicks = true
        let on = try JSONEncoder().encode(edl)
        let onText = try #require(String(data: on, encoding: .utf8))
        #expect(onText.contains("showClicks"))
    }

    @Test("The document's flag reaches the export sheet's initial request")
    func documentFlagSeedsTheExportSheet() {
        // THE requirement, asserted where it can actually fail: the value the
        // sheet opens with. Both halves of this could be right in isolation —
        // the menu writing a preference nobody reads, or the sheet reading one
        // nobody writes — and the user would see a checked menu and an
        // unchecked export.
        let url = URL(fileURLWithPath: "/tmp/x.mp4")
        #expect(ExportRequest(destination: url, drawClicks: true).drawClicks == true)
        #expect(ExportRequest(destination: url, drawClicks: false).drawClicks == false)
        // And the default stays off for every other construction site, so
        // previews and older tests are unaffected.
        #expect(ExportRequest(destination: url).drawClicks == false)
    }

    @Test("Clicks with no coordinates produce no marks, however the toggle is set")
    func positionlessClicksDrawNothing() {
        // Every recording made before D64 is in this state. Turning the menu
        // on for one of them must draw nothing rather than draw rings at the
        // origin — and the player relies on the empty list to skip attaching a
        // time observer at all.
        let events = [
            LoggedEvent(timeSeconds: 1.0, kind: .click, label: nil, x: nil, y: nil),
            LoggedEvent(timeSeconds: 2.0, kind: .click, label: nil, x: nil, y: nil),
        ]
        let kept = [TimeRange(start: 0, end: 10)]
        #expect(ClickOverlay.unitMarks(events: events, keptRanges: kept).isEmpty)
    }

    @Test("unitMarks returns fractions, not pixels — and still maps through cuts")
    func unitMarksAreFractions() throws {
        // The playback overlay multiplies by `AVPlayerLayer.videoRect` at draw
        // time, so what it needs back is the fraction it stored. A version
        // that returned render pixels would put every ring within a few
        // pixels of the top-left corner — plausible enough on screen to be
        // mistaken for a positioning bug rather than a units bug.
        let click = LoggedEvent(timeSeconds: 5.0, kind: .click, label: nil, x: 0.25, y: 0.75)
        // A cut before the click, so output time differs from source time and
        // a mapping that skipped the cuts is visible.
        let kept = [TimeRange(start: 0, end: 1), TimeRange(start: 3, end: 10)]
        let marks = ClickOverlay.unitMarks(events: [click], keptRanges: kept)
        let mark = try #require(marks.first)
        #expect(abs(mark.position.x - 0.25) < 1e-9, "x was \(mark.position.x)")
        #expect(abs(mark.position.y - 0.75) < 1e-9, "y was \(mark.position.y)")
        // 1s kept, then the click 2s into the second range → 3s output.
        #expect(abs(mark.outputTime - 3.0) < 1e-9, "outputTime was \(mark.outputTime)")
    }
}
