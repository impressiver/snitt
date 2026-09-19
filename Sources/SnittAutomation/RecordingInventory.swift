// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// One recording sitting in the output directory (D108).
public struct RecordingSummary: Codable, Sendable, Equatable {
    public var path: String
    /// Every byte the bundle occupies, `capture.mov` included.
    ///
    /// The whole bundle rather than the movie alone, because the question this
    /// answers is "what is this costing me", and the answer a person would get
    /// from the Finder is the directory's size.
    public var byteSize: Int
    /// Seconds since the recording started, from `meta.json`'s `createdAt`.
    ///
    /// Age rather than a timestamp, because the question an agent asks is
    /// "which of these did I just make". A timestamp makes it do date
    /// arithmetic against a clock it has to go and find; `createdAt` is
    /// published beside this for anyone who wants the other form.
    public var ageSeconds: Double
    public var createdAt: Date
    /// `"human"` or `"agent"`.
    public var initiator: String
    /// How an agent's session ended: `"capped"`, `"completed"`, or absent.
    ///
    /// **`"capped"` is the one worth looking for.** §5.3's watchdog exists
    /// because an agent that crashes after `record start` would otherwise
    /// leave `AVAssetWriter` writing until the disk filled; it force-stops the
    /// session and still finalises the bundle. That bundle is a full-
    /// resolution video nobody asked for and nobody has seen.
    ///
    /// Absent means the recording did not end through the agent API: a person
    /// pressed the hotkey, or it was recorded before this was written. See
    /// `RecordingMetadata.outcome`.
    public var outcome: String?
    /// WALL seconds the recording ran, as `meta.json` stamped it. Absent for a
    /// bundle whose metadata never got a duration.
    public var durationSeconds: Double?

    public init(path: String, byteSize: Int, ageSeconds: Double, createdAt: Date,
                initiator: String, outcome: String?, durationSeconds: Double?) {
        self.path = path
        self.byteSize = byteSize
        self.ageSeconds = ageSeconds
        self.createdAt = createdAt
        self.initiator = initiator
        self.outcome = outcome
        self.durationSeconds = durationSeconds
    }
}

/// What `snitt recordings list` returns (D108).
public struct RecordingList: Codable, Sendable, Equatable {
    /// Where these were found, so a caller that gets nothing back can tell
    /// "there are no recordings" from "you are looking in the wrong place".
    /// The output directory is user-configurable, and an agent has no other
    /// way to learn where it points.
    public var directory: String
    /// How many bundles the directory holds, which is NOT `recordings.count`
    /// when a limit truncated the answer.
    ///
    /// Published separately so a truncated list reads as truncated. A caller
    /// that got ten of forty and was told only "ten" would conclude it had
    /// seen everything, which is the quiet kind of wrong this API keeps
    /// finding in itself.
    public var total: Int
    /// Newest first.
    public var recordings: [RecordingSummary]
    /// Bytes across ALL of them, not only the ones listed.
    public var totalByteSize: Int

    public init(directory: String, total: Int, recordings: [RecordingSummary],
                totalByteSize: Int) {
        self.directory = directory
        self.total = total
        self.recordings = recordings
        self.totalByteSize = totalByteSize
    }
}

/// Reads the output directory and says what is in it (D108).
///
/// In `SnittAutomation` rather than `SnittApp` for one practical reason: this
/// target's tests run in CI and `SnittAppTests` does not (it hangs on a
/// headless runner). The logic is plain Foundation over a directory, so the
/// only thing keeping it out of a CI-gated target would be habit.
///
/// It reads and never deletes. Removing somebody's recordings over a socket is
/// a much larger decision than listing them, and the finding this closes is
/// that an agent cannot FIND its own debris, not that it cannot delete it.
public enum RecordingInventory {

    /// Every `.snitt` bundle directly inside `directory`, newest first.
    ///
    /// Not recursive: the output directory is where Snitt writes, and walking
    /// a person's whole `~/Documents` because they pointed the setting at it
    /// would be both slow and a surprise.
    ///
    /// A bundle whose `meta.json` cannot be read is SKIPPED rather than
    /// failing the listing. That is the opposite of the absent-versus-
    /// unreadable discipline `readEDL` applies, and deliberately so: those
    /// callers are answering a question about ONE recording the caller named,
    /// where a silent empty answer hides a real problem. This answers a
    /// question about a directory, and one damaged bundle in it must not make
    /// the other thirty unfindable. The count says how many were skipped.
    public static func list(in directory: URL, now: Date = Date(),
                            limit: Int? = nil) -> RecordingList {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        var summaries: [RecordingSummary] = []
        for url in entries where url.pathExtension == "snitt" {
            guard let bundle = try? SnittBundle(opening: url),
                  let meta = try? RecordingMetadata.read(from: bundle) else { continue }
            summaries.append(RecordingSummary(
                path: url.path,
                byteSize: size(of: url),
                // Clamped at zero: a bundle stamped in the future (a clock
                // that moved, a file copied from another machine) would
                // otherwise report a negative age, which reads as nonsense
                // rather than as the anomaly it is.
                ageSeconds: max(0, now.timeIntervalSince(meta.createdAt)),
                createdAt: meta.createdAt,
                initiator: meta.initiator.rawValue,
                outcome: meta.outcome,
                durationSeconds: meta.durationSeconds))
        }
        summaries.sort { $0.createdAt > $1.createdAt }

        let total = summaries.count
        let totalBytes = summaries.reduce(0) { $0 + $1.byteSize }
        if let limit, limit < summaries.count {
            summaries = Array(summaries.prefix(limit))
        }
        return RecordingList(directory: directory.path, total: total,
                             recordings: summaries, totalByteSize: totalBytes)
    }

    /// Bytes under `url`, summed over everything in the bundle.
    ///
    /// `capture.mov` dominates, but a bundle also holds screenshots and an
    /// over-dub take, and reporting only the movie would understate a
    /// directory somebody is trying to reclaim space in.
    private static func size(of url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            total += values?.fileSize ?? 0
        }
        return total
    }
}
