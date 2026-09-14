// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittExport
@testable import SnittDocument

/// File ▸ Export for ▸ <destination>.
///
/// The presets themselves are checked in `ExportDestinationTests`; this is
/// about the wiring — that picking a destination produces the request that
/// destination needs, and that the menu can actually reach it.
@MainActor
struct ExportForDestinationTests {

    private let base = URL(fileURLWithPath: "/tmp/demo.mp4")

    @Test("A destination's limits become the request's settings")
    func presetBecomesARequest() {
        // The translation this feature is: a place turns into a size ceiling,
        // a resolution and a format. Asserted against GitHub because it is the
        // one with a ceiling tight enough to change the outcome.
        let request = ExportRequest.forDestination(.github, basedOn: base, drawClicks: false)
        #expect(request.maxSizeBytes == ExportDestination.github.maxSizeBytes)
        #expect(request.resolution == ExportDestination.github.resolution)
        #expect(request.format == "mp4")
    }

    @Test("The filename says where it is going")
    func filenameCarriesTheDestination() {
        // These files are made to be posted, and a folder of demo.mp4,
        // demo-1.mp4, demo-2.mp4 does not say which one is the small one.
        let request = ExportRequest.forDestination(.github, basedOn: base, drawClicks: false)
        #expect(request.destination.lastPathComponent == "demo-github.mp4")

        // And it does not accumulate: exporting for two destinations from the
        // same base gives two names, not one with both suffixes.
        let slack = ExportRequest.forDestination(.slack, basedOn: base, drawClicks: false)
        #expect(slack.destination.lastPathComponent == "demo-slack.mp4")
    }

    @Test("A GIF destination renames the file, rather than writing a GIF as .mp4")
    func formatDrivesTheExtension() {
        // `setFormat` exists because a .mp4 holding a GIF is a file Finder
        // opens in the wrong app. A preset that set `format` directly would
        // bypass that and produce exactly it.
        let gif = ExportDestination(id: "gifplace", name: "GIF Place",
                                    maxSizeBytes: 5_000_000, maxDurationSeconds: nil,
                                    resolution: .sd540p, format: "gif")
        let request = ExportRequest.forDestination(gif, basedOn: base, drawClicks: false)
        #expect(request.format == "gif")
        #expect(request.destination.pathExtension == "gif")
    }

    @Test("Show Clicks carries into a destination export")
    func clicksFollowTheDocument() {
        // The same rule the export sheet follows: what you set up while
        // watching is what you get when you export. A path that ignored it
        // would drop the rings only for these exports, which is the kind of
        // inconsistency nobody reports and everybody notices.
        #expect(ExportRequest.forDestination(.github, basedOn: base, drawClicks: true).drawClicks)
        #expect(!ExportRequest.forDestination(.github, basedOn: base, drawClicks: false).drawClicks)
    }

    @Test("The sheet's overlay toggles are seeded from the document")
    func overlayTogglesFollowTheDocument() {
        // Opening the sheet must agree with what the editor was showing —
        // three separate flags, so a request that carried one for all three
        // would tick boxes nobody asked for.
        let request = ExportRequest(destination: base, drawClicks: true,
                                    drawSubtitles: true, drawMarkers: false)
        #expect(request.drawClicks)
        #expect(request.drawSubtitles)
        #expect(!request.drawMarkers)
    }

    @Test("A destination export carries every overlay it was given")
    func destinationCarriesOverlays() {
        // The presets go through their own constructor, so they are their own
        // chance to drop one of the three silently.
        let request = ExportRequest.forDestination(.github, basedOn: base,
                                                   drawClicks: false,
                                                   drawSubtitles: true,
                                                   drawMarkers: true)
        #expect(request.drawSubtitles)
        #expect(request.drawMarkers)
        #expect(!request.drawClicks)
    }

    @Test("An ordinary export has no size ceiling")
    func plainRequestsAreUnconstrained() {
        // The ceiling belongs to the presets. A person choosing a resolution
        // by hand is choosing quality, not a byte budget, and silently
        // imposing one would make the sheet's own estimate wrong.
        #expect(ExportRequest(destination: base).maxSizeBytes == nil)
    }

    @Test("The File menu no longer exports the moment you pick a destination")
    func exportForIsNotInTheMenuBar() throws {
        // It was a submenu that exported immediately, with no dialog and no
        // chance to see what it had decided, so getting it wrong meant
        // exporting again rather than adjusting. It is a picker in the export
        // sheet now.
        //
        // Asserted as an ABSENCE because that is the change: a test that only
        // checked the sheet's picker would pass with both surfaces present,
        // and two places that both claim to set the export settings is the
        // state this removes.
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        #expect(!file.items.contains { $0.title == "Export for" },
                "Export for is still in the File menu")
        // Export and Share ARE still there. Removing a neighbour by accident
        // is one keystroke away from removing the item itself.
        #expect(file.items.contains { $0.title == "Export…" })
        #expect(file.items.contains { $0.title == "Share" })
    }

    @Test("Share is a SUBMENU beside Export, as QuickTime has it")
    func shareIsInTheFileMenu() throws {
        // It was a flat "Share…" that exported first and then raised a picker.
        // A submenu is what makes the destinations appear instantly, so the
        // shape is the fix rather than a presentation preference — asserting
        // only that an item called Share exists would pass against the version
        // that hung for ten seconds.
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        let share = try #require(file.items.first { $0.title == "Share" },
                                 "File has no Share item")
        #expect(share.submenu != nil, "Share is still a flat item, not a submenu")
        // NOT `action == nil`: AppKit installs `submenuAction:` on any item
        // that is given a submenu, so nil is a state this item cannot be in.
        // What matters is that clicking the parent does not itself share.
        #expect(share.action != #selector(AppDelegate.shareToService(_:)),
                "the submenu's parent also acts — two gestures on one item")

        // Beside Export, not somewhere else in the menu.
        let exportIndex = try #require(file.items.firstIndex { $0.title == "Export…" })
        let shareIndex = try #require(file.items.firstIndex { $0.title == "Share" })
        #expect(shareIndex > exportIndex)
        #expect(shareIndex - exportIndex <= 2,
                "Share drifted away from Export in the File menu")
    }

    @Test("Export, Export for and Share are all disabled with no document open")
    func documentActionsNeedADocument() {
        // Asserted together because they are one rule. An item that offers an
        // action and then silently declines it reads as a broken app rather
        // than as "nothing is open" — which is why Export already had this,
        // and why the two new ones must not be the exception.
        let delegate = AppDelegate()
        for selector in [#selector(AppDelegate.exportDocument(_:)),
                         #selector(AppDelegate.shareToService(_:))] {
            let item = NSMenuItem(title: "x", action: selector, keyEquivalent: "")
            #expect(delegate.validateMenuItem(item) == false,
                    "\(selector) stayed enabled with no editor in front")
        }
    }

    @Test("Every preset the picker offers resolves back to a real destination")
    func everyEntryResolves() throws {
        // The other half of the id indirection, now that the picker's
        // selection is an id rather than a menu item's representedObject. An
        // id `named(_:)` cannot resolve is an entry that does nothing when
        // chosen, which looks like a broken app rather than a typo.
        for destination in ExportDestination.all {
            #expect(ExportDestination.named(destination.id) != nil,
                    "\(destination.name) has unresolvable id \(destination.id)")
        }
        // And the sentinel the picker uses for "Custom" must not collide with
        // a real id, or that destination would be unreachable — the picker
        // would read the sentinel as a selection of it.
        #expect(ExportDestination.named(ExportSheet.customPresetID) == nil,
                "the Custom sentinel collides with a real destination id")
    }
}
