// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import SnittDocument

/// A video on the clipboard, if there is one.
///
/// Split out from the menu handler and given an injectable pasteboard so the
/// decision is testable: "is there a video to open" is a question with several
/// wrong answers that all look like "no", and a silent no is exactly how
/// File ▸ New would appear broken to somebody who had just copied a file.
@MainActor
enum ClipboardMedia {

    /// The first video the pasteboard is offering, or nil.
    ///
    /// **Reads file URLs only, deliberately.** A pasteboard can also carry
    /// raw movie DATA, and accepting that would mean writing it to a temporary
    /// file to find out whether it is readable at all — work done before
    /// knowing it was wanted. Every ordinary route (Finder copy, a Save-to
    /// from another app, a drag) puts a URL on the board.
    static func video(in pasteboard: NSPasteboard = .general) -> URL? {
        // `urlReadingContentsConformToTypes` filters at the pasteboard rather
        // than after the fact, so a board holding a text file and a movie
        // yields the movie instead of the first item.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ImportableMedia.types.map(\.identifier),
        ]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: options) as? [URL]
        else { return nil }
        // `canOpen` again rather than trusting the filter: it is the same
        // predicate File ▸ Open and the drop handler use, and a route that
        // accepted something the others refuse is a promise the next step
        // breaks.
        return urls.first(where: ImportableMedia.canOpen)
    }
}
