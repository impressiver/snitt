// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

public enum SnittBundleError: Error, Equatable {
    case notADirectory
    case missingCapture
    case alreadyExists
}

/// A `.snitt` recording package.
///
/// The bundle is a directory. `capture.mov` is written once during recording
/// and never mutated afterwards. `edit.json` and `events.json` are the two
/// files editing touches — cuts in the former, marker position/label/
/// transcript in the latter (M5f Task 6 added writing to `events.json`;
/// before that, only capture ever wrote it). See spec section 7.
public struct SnittBundle: Sendable {
    public static let fileExtension = "snitt"

    public let url: URL

    public var captureURL: URL { url.appendingPathComponent("capture.mov") }
    public var eventsURL: URL { url.appendingPathComponent("events.json") }
    public var editURL: URL { url.appendingPathComponent("edit.json") }
    public var metaURL: URL { url.appendingPathComponent("meta.json") }
    public var posterURL: URL { url.appendingPathComponent("poster.png") }
    /// Word-level transcript (D62), written the first time transcription runs.
    public var transcriptURL: URL { url.appendingPathComponent("transcript.json") }
    /// Narration recorded in the editor (D93). Beside `capture.mov`, never
    /// inside it: §4.5 makes the capture immutable, and mixing narration in
    /// would make the one file that is meant to be the untouched original the
    /// one file an edit had rewritten.
    /// D93's third-track narration file. Kept only so a document written
    /// before D102 can still be recognised — nothing writes it any more, and
    /// the EDL no longer points at it.
    public var voiceoverURL: URL { url.appendingPathComponent("voiceover.m4a") }

    /// A file for one over-dub take.
    ///
    /// Named by UUID rather than by position. A document can hold several
    /// takes and any of them can be deleted, so an index in the name would
    /// stop matching the list the moment one went — and the take that had been
    /// `overdub-1` would either collide with a new one or silently point at
    /// another take's audio.
    public func overdubFilename(id: UUID = UUID()) -> String { "overdub-\(id.uuidString).m4a" }

    public func overdubURL(filename: String) -> URL { url.appendingPathComponent(filename) }

    /// Where agent screenshots land (M5e, D53).
    ///
    /// Inside the bundle rather than in a temp directory, because a screenshot
    /// is evidence about THIS recording: it is taken from a frame the recording
    /// contains, and its filename is the offset that frame sits at. Keeping the
    /// two together means moving the bundle moves the evidence, and §7's
    /// "everything about one recording lives in one package" holds.
    public var screenshotsURL: URL { url.appendingPathComponent("screenshots", isDirectory: true) }

    /// The file a screenshot at `offsetSeconds` is written to.
    ///
    /// Named by offset, to two decimals, so the filename itself answers "when
    /// in the recording was this" — the correlation D53 asks for, readable
    /// without opening anything.
    public func screenshotURL(atOffset offsetSeconds: Double) -> URL {
        screenshotsURL.appendingPathComponent(String(format: "%08.2f.png", offsetSeconds))
    }

    /// Creates a new bundle directory. Throws if anything already exists there.
    public init(creatingAt url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SnittBundleError.alreadyExists
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false
        )
        self.url = url
    }

    /// Opens an existing bundle directory.
    public init(opening url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw SnittBundleError.notADirectory
        }
        self.url = url
    }
}
