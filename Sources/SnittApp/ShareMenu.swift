// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// File ▸ Share ▸ …, built the way QuickTime builds it: a SUBMENU of the
/// destinations this Mac has, listed instantly.
///
/// **The defect this replaces.** "Share…" was one flat item. Choosing it
/// exported the whole recording first — about ten seconds, with nothing on
/// screen saying so — and only then raised an `NSSharingServicePicker`
/// anchored to a rectangle in the content view, which put the sheet down in a
/// corner of the window instead of under the menu that opened it.
///
/// **Why the menu can be instant when the export is not.** The list of share
/// services depends on the item's TYPE, not its contents: every `.mp4` offers
/// the same destinations. So the menu is enumerated against a tiny placeholder
/// of the right type, and the real recording is exported only once somebody
/// has chosen where it is going. Measured rather than assumed — see
/// `placeholderURL`.
@MainActor
enum ShareMenu {
    /// A file that EXISTS, of the type a share will produce.
    ///
    /// Both halves are load-bearing and were established by probing the real
    /// API rather than reasoned about:
    ///
    /// - `NSSharingService.sharingServices(forItems:)` returns **zero**
    ///   services for a URL whose file is not there. A menu built from the
    ///   path the export is *going* to write would therefore be empty every
    ///   time, which is worse than the slow version it replaces.
    /// - A four-byte file with an `.mp4` extension returns the **same ten**
    ///   services as a real export — AirDrop, Mail, Messages, Notes, Add to
    ///   Photos, Freeform, Simulator, Journal, Shortcuts, Fast Share. The
    ///   classification is by type, so the placeholder is not an
    ///   approximation of the answer; it is the answer.
    static func placeholderURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snitt-share-probe")
            .appendingPathExtension(exportedType.preferredFilenameExtension ?? "mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data([0, 0, 0, 0]).write(to: url)
        }
        return url
    }

    /// What a share sends. One constant, so the placeholder and the real
    /// export cannot come to disagree about the type being offered — the menu
    /// would then advertise destinations that the actual file cannot go to.
    static let exportedType: UTType = .mpeg4Movie

    /// The destinations this Mac can send a recording to, in the system's own
    /// order.
    ///
    /// `sharingServices(forItems:)` is deprecated in favour of
    /// `NSSharingServicePicker.standardShareMenuItem`, and that replacement is
    /// deliberately not used: it builds its menu from the items it is given
    /// and performs the share on those same items, so it needs the finished
    /// file BEFORE the menu can open. That is precisely the ten-second wait
    /// being removed. Using the older call for enumeration only, and
    /// performing the share on the real export, is what lets the menu be
    /// instant and still send the right file.
    @available(macOS, deprecated: 13.0)
    static func services() -> [NSSharingService] {
        guard let url = try? placeholderURL() else { return [] }
        return NSSharingService.sharingServices(forItems: [url])
    }
}

/// Owns the Share submenu and keeps it current.
///
/// A class with a stored reference because `NSMenu.delegate` is WEAK — the
/// same trap `NSMenuItem.target` sets, and one this project has already been
/// caught by. A delegate created inline would be deallocated before the menu
/// was ever opened, and the submenu would simply be empty with nothing to
/// explain why.
@MainActor
final class ShareMenuController: NSObject, NSMenuDelegate {
    /// Held for the life of the app, for the reason above.
    static let shared = ShareMenuController()

    /// Rebuilt on every open rather than cached: share extensions are
    /// installed, removed and enabled while an app is running, and a list
    /// captured at launch would quietly go stale. It is a cheap call — the
    /// expensive part was never the enumeration.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let services = ShareMenu.services()
        guard !services.isEmpty else {
            // Says so, rather than opening an empty rectangle. An empty menu
            // reads as a broken app; a disabled line reads as a Mac with
            // nothing set up.
            let empty = NSMenuItem(title: "No share destinations", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for service in services {
            let item = NSMenuItem(title: service.menuItemTitle,
                                  action: #selector(AppDelegate.shareToService(_:)),
                                  keyEquivalent: "")
            item.image = service.image
            // The service itself, not its index or title: a list that
            // reordered between build and click would otherwise send the
            // recording somewhere nobody chose.
            item.representedObject = service
            menu.addItem(item)
        }
    }
}
