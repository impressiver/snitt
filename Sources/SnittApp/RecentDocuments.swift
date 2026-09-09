// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// Recent `.snitt` documents (§4.14).
///
/// Wraps `NSDocumentController` purely for its recents list. Snitt's editor
/// is not an `NSDocument` and this milestone does not make it one — adopting
/// the document architecture is a much larger change than the shell needs.
@MainActor
enum RecentDocuments {
    static func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func urls() -> [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    static func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        for url in urls() {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(AppDelegate.openRecentDocument(_:)),
                                  keyEquivalent: "")
            item.representedObject = url
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Clear Menu",
                     action: #selector(AppDelegate.clearRecentDocuments(_:)),
                     keyEquivalent: "")
        return menu
    }
}
