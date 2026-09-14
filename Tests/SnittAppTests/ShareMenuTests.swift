// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import SnittApp

/// File ▸ Share ▸ …, and the one fact the whole design rests on.
///
/// Reported from the app: Share took "about 10s to load, with no indication
/// anything is happening", and the sheet appeared in the bottom-right corner
/// of the window. Both came from exporting the recording BEFORE anything was
/// shown. The menu now lists destinations immediately and exports only once
/// one is chosen.
///
/// That is only sound because share services are chosen by the item's TYPE
/// rather than its contents — which is measured here, not assumed.
@Suite(.serialized)
@MainActor
struct ShareMenuTests {
    init() { _ = NSApplication.shared }

    @Test("A placeholder of the right type offers the SAME destinations as a real file")
    func placeholderMatchesARealFile() throws {
        // The load-bearing claim. If services depended on the file's contents,
        // the instant menu would be listing destinations the real export
        // cannot actually go to — and nobody would find out until they picked
        // one.
        let placeholder = try ShareMenu.placeholderURL()
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-real-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        // Big enough to be a plausible file rather than a stub, so "they match
        // because both are tiny" is not the reason this passes.
        try Data(repeating: 7, count: 64 * 1024).write(to: real)
        defer { try? FileManager.default.removeItem(at: real) }

        let fromPlaceholder = NSSharingService.sharingServices(forItems: [placeholder]).map(\.title)
        let fromReal = NSSharingService.sharingServices(forItems: [real]).map(\.title)
        #expect(fromPlaceholder == fromReal,
                "placeholder offers \(fromPlaceholder), a real file offers \(fromReal)")
    }

    @Test("The placeholder EXISTS on disk, because a missing file offers nothing")
    func placeholderMustExist() throws {
        // Probed against the real API: `sharingServices(forItems:)` returns
        // ZERO services for a URL whose file is not there. Building the menu
        // from the path the export is going to write — the obvious shortcut —
        // would therefore produce an empty menu every single time, which is
        // worse than the slow version it replaces.
        let url = try ShareMenu.placeholderURL()
        #expect(FileManager.default.fileExists(atPath: url.path))

        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-written-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        #expect(NSSharingService.sharingServices(forItems: [absent]).isEmpty,
                "a missing file now offers services; the placeholder may be unnecessary")
    }

    @Test("The placeholder's type is the type a share actually sends")
    func placeholderTypeMatchesTheExport() throws {
        // One constant feeds both. Two would let the menu advertise
        // destinations for a type the export does not produce.
        let url = try ShareMenu.placeholderURL()
        #expect(url.pathExtension == ShareMenu.exportedType.preferredFilenameExtension)
    }

    @Test("The menu lists real destinations, each carrying its own service")
    func menuCarriesTheService() {
        let menu = NSMenu(title: "Share")
        ShareMenuController.shared.menuNeedsUpdate(menu)

        #expect(!menu.items.isEmpty)
        for item in menu.items where item.isEnabled {
            // The SERVICE, not a title or an index. The menu is rebuilt on
            // every open, so anything positional is a handle to whatever
            // happened to be there last time.
            #expect(item.representedObject is NSSharingService,
                    "\(item.title) carries \(String(describing: item.representedObject))")
            #expect(item.action == #selector(AppDelegate.shareToService(_:)))
        }
    }

    @Test("Reopening the menu replaces its items rather than appending them")
    func rebuildDoesNotAccumulate() {
        // `menuNeedsUpdate` fires on every open. Without the `removeAllItems`
        // the list would grow by its own length each time — visible only to
        // somebody who opened the menu twice, which is everybody.
        let menu = NSMenu(title: "Share")
        ShareMenuController.shared.menuNeedsUpdate(menu)
        let first = menu.items.count
        ShareMenuController.shared.menuNeedsUpdate(menu)
        #expect(menu.items.count == first)
    }

    @Test("The controller is held strongly enough to still be there when the menu opens")
    func delegateOutlivesMenuConstruction() throws {
        // `NSMenu.delegate` is WEAK — the same trap `NSMenuItem.target` sets,
        // and one this project has already been caught by. A delegate created
        // inline would be gone before the menu was ever opened, and the
        // submenu would be empty with nothing to explain why.
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        let share = try #require(file.items.first { $0.title == "Share" })
        let submenu = try #require(share.submenu)
        #expect(submenu.delegate != nil, "the Share submenu lost its delegate")
        #expect(submenu.delegate === ShareMenuController.shared)
    }
}
