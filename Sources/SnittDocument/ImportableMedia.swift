// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import UniformTypeIdentifiers

/// Whether Snitt can open a file as a recording, and what to call the
/// document it becomes.
///
/// Pure, and in `SnittDocument` rather than beside the drag handlers, because
/// three surfaces have to agree about it: File ▸ Open, the clipboard, and a
/// drop. A drop that accepts a file `Open…` would refuse is a promise the next
/// step breaks, and the two would drift the moment either list was edited.
public enum ImportableMedia {

    /// The types Snitt will open as a recording.
    ///
    /// Declared as UTIs rather than extensions, so a `.mov` renamed `.MOV`, a
    /// file with no extension carrying the right type, and a promise from
    /// another app's drag pasteboard all resolve the same way.
    ///
    /// `movie` covers the container types AVFoundation reads; `mpeg4Movie` and
    /// `quickTimeMovie` conform to it and are named anyway, because a
    /// pasteboard item sometimes reports only the concrete type and
    /// `conforms(to:)` on the abstract one is the check that then fails.
    public static let types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    /// Whether `url` is something Snitt can open.
    ///
    /// Asked of the TYPE, not the extension, with the extension as a fallback
    /// for a file that has not been type-resolved yet — which is the state a
    /// promised drag item arrives in.
    /// A `.snitt` is correctly refused WITHOUT a special case, and that was
    /// checked rather than assumed. The bundle's own UTI declares conformance
    /// to `com.apple.package` and `public.composite-content` (`make-app.sh`),
    /// never `public.movie` — verified against the registered type on a
    /// machine with Snitt installed. An explicit extension guard was written
    /// here first and deleted: a mutation pass showed it could not fail,
    /// because nothing reaches it. `ImportableMediaTests` keeps the assertion,
    /// so adding `public.movie` to that conformance list would be caught.
    public static func canOpen(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return types.contains { type.conforms(to: $0) }
        }
        return false
    }

    /// The document name an imported file should get.
    ///
    /// The source's own stem, because somebody who drops `sprint-demo.mp4`
    /// is looking for `sprint-demo.snitt` afterwards — and a generated
    /// `Snitt-1789163327` would be the one name they cannot search for.
    /// Sanitised only where a filename cannot carry a character.
    public static func documentName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let cleaned = stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty result is reachable: a file called ".mp4" has no stem at
        // all, and a bundle named "" is one the file system refuses.
        return cleaned.isEmpty ? "Imported" : cleaned
    }
}
