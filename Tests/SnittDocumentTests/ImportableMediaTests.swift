// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// What Snitt will open as a recording.
///
/// One predicate, three surfaces: File ▸ Open, the clipboard, and a drop. The
/// reason it is one and not three is the failure a drop that accepts a file
/// `Open…` refuses — a drag that highlights, lands, and then does nothing,
/// with no error because nothing went wrong.
struct ImportableMediaTests {

    @Test("The ordinary screen-recording formats open")
    func commonFormatsAreAccepted() {
        for name in ["demo.mp4", "demo.mov", "demo.m4v", "DEMO.MOV", "demo.MP4"] {
            #expect(ImportableMedia.canOpen(URL(fileURLWithPath: "/tmp/\(name)")),
                    "\(name) was refused")
        }
    }

    @Test("A .snitt is NOT importable, however much it looks like media")
    func snittBundlesAreNotImported() {
        // The one that would corrupt something rather than merely fail. A
        // `.snitt` opens as a document; importing one would copy the whole
        // bundle DIRECTORY into a new bundle's `capture.mov` and produce a
        // file nothing can read.
        //
        // This passes with NO special case in `canOpen`: the bundle's UTI
        // declares conformance to `com.apple.package` and
        // `public.composite-content`, never `public.movie`. An explicit
        // extension guard was written and then deleted when a mutation pass
        // showed nothing could reach it. THIS test is the protection — adding
        // `public.movie` to that conformance list in `make-app.sh` fails here.
        #expect(!ImportableMedia.canOpen(URL(fileURLWithPath: "/tmp/demo.snitt")))
    }

    @Test("Things that are not video are refused")
    func nonVideoIsRefused() {
        for name in ["notes.txt", "shot.png", "archive.zip", "song.mp3", "noextension"] {
            #expect(!ImportableMedia.canOpen(URL(fileURLWithPath: "/tmp/\(name)")),
                    "\(name) was accepted")
        }
    }

    @Test("The document takes the source's own name")
    func documentNameFollowsTheSource() {
        // Somebody who opens `sprint-demo.mp4` looks for `sprint-demo.snitt`
        // afterwards. A generated `Snitt-1789163327` is the one name they
        // cannot search for.
        #expect(ImportableMedia.documentName(
            for: URL(fileURLWithPath: "/tmp/sprint-demo.mp4")) == "sprint-demo")
    }

    @Test("A name a file system cannot carry becomes one it can")
    func documentNameIsSanitised() {
        // A colon is a path separator to the Finder and a slash to everything
        // else, so a bundle named with either is one that cannot be created —
        // the import would fail at the last step with a file-system error.
        #expect(!ImportableMedia.documentName(
            for: URL(fileURLWithPath: "/tmp/a:b.mp4")).contains(":"))
        // And a file with no stem at all still gets a usable name rather than
        // an empty one, which the file system also refuses.
        #expect(!ImportableMedia.documentName(for: URL(fileURLWithPath: "/tmp/.mp4")).isEmpty)
    }
}
