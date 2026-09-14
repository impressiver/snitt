// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import AppKit
import Foundation
import SnittDocument

/// Turns a plain video file into a `.snitt` document.
///
/// **The whole feature in one sentence**: a recording Snitt did not make gets
/// the same auto-trim, cutting, markers, transcription and voiceover as one it
/// did, because after this runs there is no difference — the imported file IS
/// the bundle's `capture.mov`, and every part of the app downstream is already
/// written against that.
///
/// What it deliberately does NOT do is re-encode. The source is COPIED, so an
/// import is fast, lossless, and leaves the original untouched on disk. That
/// also keeps §4.5's pristine-capture invariant true for imported documents:
/// `capture.mov` is the untouched original, it is simply somebody else's
/// original.
@MainActor
enum VideoImporter {

    enum ImportError: LocalizedError {
        case notReadable(String)
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .notReadable(let name):
                return "Snitt could not read \(name)."
            case .noVideoTrack:
                // Named separately from "unreadable" because the remedy is
                // different: an audio file opens fine and simply has no
                // picture, and telling somebody their file is corrupt when it
                // is merely audio sends them to fix the wrong thing.
                return "That file has no video track."
            }
        }
    }

    /// Where an imported document lives until it is saved.
    ///
    /// The scratch directory, not the recordings folder. An import that has
    /// not been saved is not yet a recording the person decided to keep, and
    /// writing it straight into `~/Documents/Snitt` would fill that folder
    /// with documents nobody asked for — indistinguishable from ones they did.
    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SnittImports", isDirectory: true)
    }

    /// Copies `url` into a new, unsaved bundle and returns it.
    static func makeBundle(from url: URL) async throws -> SnittBundle {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else {
            throw ImportError.notReadable(url.lastPathComponent)
        }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else {
            throw ImportError.noVideoTrack
        }

        let root = scratchDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The source's own name, plus a uuid for the directory only — two
        // imports of `demo.mp4` must not collide, and the name the person
        // sees comes from the save panel rather than from here.
        let bundleURL = root
            .appendingPathComponent("\(ImportableMedia.documentName(for: url))-\(UUID().uuidString)")
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: bundleURL)

        // COPIED, not moved and not re-encoded. Moving would delete somebody
        // else's file as a side effect of opening it, which is not a thing an
        // "open" should ever do.
        try FileManager.default.copyItem(at: url, to: bundle.captureURL)

        try RecordingMetadata(
            createdAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date(),
            initiator: .human,
            durationSeconds: CMTimeGetSeconds(duration)
        ).write(to: bundle)
        try EditDecisionList().write(to: bundle)

        return bundle
    }

}
