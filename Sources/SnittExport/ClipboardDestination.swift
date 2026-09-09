// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import AppKit

/// Puts a finished recording on the clipboard.
///
/// Copying is the default outcome of stopping a recording, not a step the user
/// takes afterwards (§4.1). The gap between "the file exists" and "it is pasted
/// into Slack" is where the time-to-share budget is actually spent.
public enum ClipboardDestination {
    public static func pasteboardItems(for fileURL: URL) -> [NSPasteboardWriting] {
        [fileURL as NSURL]
    }

    /// Copies the file, returning false if it could not be copied.
    ///
    /// The file's existence is checked BEFORE the pasteboard is cleared, so the
    /// common failure — a recording that never got written — cannot destroy what
    /// the user already had on their clipboard.
    ///
    /// That guarantee is narrower than "a failed copy is always harmless", and
    /// deliberately so. `NSPasteboard` requires `clearContents()` before
    /// `writeObjects(_:)`, with no atomic alternative, so a write that fails
    /// *after* the clear leaves the clipboard empty. Snapshotting and restoring
    /// the previous contents was considered and rejected: pasteboard items can be
    /// lazily promised, so a restore may not faithfully reproduce them, which
    /// would trade a near-unreachable failure for an unreliable mechanism.
    public static func copy(fileURL: URL, to pasteboard: NSPasteboard) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(pasteboardItems(for: fileURL))
    }
}
