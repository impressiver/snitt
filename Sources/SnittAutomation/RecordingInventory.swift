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

    /// Bundles in the directory whose `meta.json` could not be read, by path.
    ///
    /// **The comment on `list` used to promise this and it did not exist.** It
    /// said "the count says how many were skipped"; `total` is
    /// `summaries.count`, the number read SUCCESSFULLY, so a skipped bundle
    /// appeared in no field at all — not here, not in `total`, not in
    /// `totalByteSize`. The one tool whose job is finding leftover recordings
    /// was blind to exactly the ones an interrupted recording leaves, while its
    /// own documentation said otherwise. Confirmed from both sides: an
    /// abandoned bundle was the newest thing on disk and absent from the
    /// listing, and a caller reading that listing concluded their bundle simply
    /// was not there yet.
    ///
    /// Paths rather than a count, because a caller who learns there are two
    /// unreadable bundles still cannot act without knowing which.
    ///
    /// Should be rare now that `Recorder.start()` writes `meta.json` before the
    /// first frame: a recording interrupted at any point after that lands in
    /// `recordings` instead, carrying its start time, initiator and build. What
    /// remains here is a bundle from before that change, or one interrupted in
    /// the instant between creation and the first write.
    public var unreadable: [String]

    public init(directory: String, total: Int, recordings: [RecordingSummary],
                totalByteSize: Int, unreadable: [String] = []) {
        self.directory = directory
        self.total = total
        self.recordings = recordings
        self.totalByteSize = totalByteSize
        self.unreadable = unreadable
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
    /// A bundle whose `meta.json` cannot be read is not listed as a recording,
    /// and does not fail the listing either. That is the opposite of the
    /// absent-versus-unreadable discipline `readEDL` applies, and deliberately
    /// so: those callers are answering a question about ONE recording the
    /// caller named, where a silent empty answer hides a real problem. This
    /// answers a question about a directory, and one damaged bundle in it must
    /// not make the other thirty unfindable.
    ///
    /// It IS reported, in `unreadable`. This comment used to claim a count that
    /// did not exist, so the skip was total — see that property.
    public static func list(in directory: URL, now: Date = Date(),
                            limit: Int? = nil) -> RecordingList {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        var summaries: [RecordingSummary] = []
        var unreadable: [String] = []
        for url in entries where url.pathExtension == "snitt" {
            guard let bundle = try? SnittBundle(opening: url),
                  let meta = try? RecordingMetadata.read(from: bundle) else {
                unreadable.append(url.path)
                continue
            }
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
                             recordings: summaries, totalByteSize: totalBytes,
                             unreadable: unreadable.sorted())
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
