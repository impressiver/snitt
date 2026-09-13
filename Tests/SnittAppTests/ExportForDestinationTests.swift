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

    @Test("An ordinary export has no size ceiling")
    func plainRequestsAreUnconstrained() {
        // The ceiling belongs to the presets. A person choosing a resolution
        // by hand is choosing quality, not a byte budget, and silently
        // imposing one would make the sheet's own estimate wrong.
        #expect(ExportRequest(destination: base).maxSizeBytes == nil)
    }

    @Test("The File menu offers every destination, wired to the export action")
    func menuReachesEveryDestination() throws {
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        let forItem = try #require(file.items.first { $0.title == "Export for" },
                                   "File has no Export for submenu")
        let submenu = try #require(forItem.submenu)

        #expect(submenu.items.count == ExportDestination.all.count)
        for destination in ExportDestination.all {
            let entry = try #require(submenu.items.first { $0.title == destination.name },
                                     "no menu entry for \(destination.name)")
            #expect(entry.action == #selector(AppDelegate.exportForDestination(_:)))
            // Identified by id, not by title: the action resolves the preset
            // from this, so a renamed entry must not silently retarget the
            // export to a different place.
            #expect(entry.representedObject as? String == destination.id)
        }
    }

    @Test("Share sits beside Export and uses the system sheet")
    func shareIsInTheFileMenu() throws {
        // QuickTime's arrangement, and the reason it is the system picker
        // rather than a list Snitt keeps: whatever the person has set up is
        // already there and stays right without Snitt tracking it.
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        let share = try #require(file.items.first { $0.title == "Share…" },
                                 "File has no Share item")
        #expect(share.action == #selector(AppDelegate.shareDocument(_:)))

        // Beside Export, not somewhere else in the menu.
        let exportIndex = try #require(file.items.firstIndex { $0.title == "Export…" })
        let shareIndex = try #require(file.items.firstIndex { $0.title == "Share…" })
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
                         #selector(AppDelegate.exportForDestination(_:)),
                         #selector(AppDelegate.shareDocument(_:))] {
            let item = NSMenuItem(title: "x", action: selector, keyEquivalent: "")
            #expect(delegate.validateMenuItem(item) == false,
                    "\(selector) stayed enabled with no editor in front")
        }
    }

    @Test("Every menu entry resolves back to a real preset")
    func everyEntryResolves() throws {
        // The other half of the id indirection. An entry carrying an id that
        // `named(_:)` cannot resolve is an item that does nothing when
        // clicked, which looks like a broken app rather than a typo.
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        let submenu = try #require(file.items.first { $0.title == "Export for" }?.submenu)
        for entry in submenu.items {
            let id = try #require(entry.representedObject as? String, "\(entry.title) carries no id")
            #expect(ExportDestination.named(id) != nil, "\(entry.title) has unknown id \(id)")
        }
    }
}
