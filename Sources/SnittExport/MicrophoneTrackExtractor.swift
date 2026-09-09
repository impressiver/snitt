// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import Foundation
import SnittDocument

/// Extracts the microphone track into a standalone audio file for the
/// speech recognizer (D62, D68).
///
/// Necessary, not convenience — the S6 probe hit this: `capture.mov` carries
/// audio as [systemAudio, microphone] (`AudioTrackOrder.canonical`), and a
/// recognizer handed the whole movie takes the FIRST track it finds. For a
/// screen recording with no system audio that is pure silence, and the result
/// is a confident, empty transcript — an answer worse than an error, because
/// it reads as "nothing was said" rather than "wrong track".
public enum MicrophoneTrackExtractor {
    /// The extracted microphone audio, or nil when the recording has none —
    /// which is a normal state (mic off), not a failure.
    public static func extract(from bundle: SnittBundle) async throws -> URL? {
        let asset = AVURLAsset(url: bundle.captureURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let index = AudioTrackOrder.canonical.firstIndex(of: "microphone"),
              index < tracks.count else { return nil }

        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let duration = try await asset.load(.duration)
        try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                        of: tracks[index], at: .zero)

        // The scratch directory, never the bundle: this file is an
        // intermediate for the recognizer, not part of the recording, and a
        // sidecar nobody wrote to the schema would look like data on a future
        // read.
        let out = FileManager.default.temporaryDirectory
            .appending(path: "snitt-mic-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        try await session.export(to: out, as: .m4a)
        return out
    }
}
