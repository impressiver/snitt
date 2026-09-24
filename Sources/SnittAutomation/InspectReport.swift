// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// What `snitt inspect` returns (§8).
///
/// Exists because an agent cannot watch the video it just made. Every value
/// here is already computed elsewhere in the pipeline; this assembles them so
/// an agent can write something factually true in a pull request instead of
/// narrating a recording it has never seen.
public struct InspectReport: Codable, Sendable, Equatable {
    public struct Marker: Codable, Sendable, Equatable {
        public var timeSeconds: Double
        public var label: String?
    }

    /// One fold in the recording, as the report describes it.
    public struct Cut: Codable, Sendable, Equatable {
        public var startSeconds: Double
        public var endSeconds: Double
        /// What the fold removed, where an automatic trim said so. `nil` for a
        /// cut somebody made by hand.
        public var label: String?
    }

    public var bundlePath: String
    public var createdAt: Date
    public var initiator: String
    /// How much FOOTAGE was captured. Unaffected by any edit — this is what the
    /// camera recorded, and it never changes.
    ///
    /// For what the edit runs for, read `outputDurationSeconds`. The two are the
    /// same number until something is cut, which is why one stood in for both
    /// for so long.
    public var durationSeconds: Double?
    public var git: GitContext?
    public var health: CaptureHealth?
    /// Markers are listed; input events are only counted — the log records
    /// that input happened, never what, and listing it would be the same
    /// disclosure by another route.
    public var markers: [Marker]
    public var markerCount: Int
    public var inputEventCount: Int
    /// How many of `inputEventCount` were REPORTED by a client rather than
    /// observed by the event tap. Published rather than folded in, so a
    /// consumer can tell "a person clicked here" from "an automation asserts
    /// it clicked here" — they are different claims and a recording must not
    /// vouch for the second as though it were the first.
    public var reportedEventCount: Int

    /// What the recording RUNS for, after the cuts in `edit.json`.
    ///
    /// This report is the only way an agent finds out what it made, and it
    /// described the bundle as it came off the camera: cuts and crops were
    /// invisible, and `durationSeconds` reported the untrimmed footage. So an
    /// agent returning to a bundle it had already edited was told the pre-edit
    /// state as though it were current, and could not tell that the line it
    /// meant to cut had already gone. That cost a whole re-take in a real
    /// session before anyone noticed the edit was still there.
    ///
    /// `nil` when the footage length is unknown, rather than a guess.
    public var outputDurationSeconds: Double?
    /// The folds already applied, in source time.
    ///
    /// **Optional, and the two empties mean different things.** `[]` is an app
    /// saying "nothing has been cut"; `nil` is an app too old to have an
    /// opinion, and a reader must not collapse them into "untouched" without
    /// noticing which it has.
    ///
    /// Optional for the wire, not for the semantics: a non-Optional array makes
    /// synthesized `Codable` REQUIRE the key, so every older app's inspect
    /// response decodes as `keyNotFound`. That is the second time this exact
    /// trap fired in one change — see `screenshotTaken`'s `marked` — so the
    /// rule is now stated plainly: any field added to a shipped response is
    /// Optional, whatever its type would naturally be.
    public var cuts: [Cut]?
    /// The crop already applied, if any.
    public var crop: CropRect?

    /// The captured picture in PIXELS.
    ///
    /// The number a caller needs to convert a region it measured in pixels into
    /// the fraction `crop` stores, and to check afterwards that the crop landed
    /// where it asked. Nothing earlier in the loop reported it: it appeared
    /// only in `CropSummary`, AFTER a crop had been applied. A caller building
    /// demo scripts worked around that by hardcoding a fraction derived by hand
    /// from one screenshot, which silently crops the wrong thing on a machine
    /// whose window furniture differs — the failure the crop refusal's own
    /// wording exists to prevent.
    ///
    /// `nil` for a bundle recorded before `Recorder.start()` began writing it.
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public static func report(for bundle: SnittBundle) throws -> InspectReport {
        let meta = try RecordingMetadata.read(from: bundle)
        let events = try Self.readEvents(for: bundle)
        let markers = events.filter { $0.kind == .marker }
        let edl = try Self.readEDL(for: bundle)

        return InspectReport(
            bundlePath: bundle.url.path,
            createdAt: meta.createdAt,
            initiator: meta.initiator.rawValue,
            durationSeconds: meta.durationSeconds,
            git: meta.git,
            health: meta.health,
            markers: markers.map { Marker(timeSeconds: $0.timeSeconds, label: $0.label) },
            markerCount: markers.count,
            inputEventCount: events.count - markers.count,
            reportedEventCount: events.filter { $0.kind != .marker && $0.source == .reported }.count,
            outputDurationSeconds: meta.durationSeconds.map {
                edl.outputDuration(sourceDuration: $0)
            },
            cuts: edl.cuts.map {
                Cut(startSeconds: $0.range.start, endSeconds: $0.range.end, label: $0.label)
            },
            crop: edl.crop,
            pixelWidth: meta.pixelWidth,
            pixelHeight: meta.pixelHeight
        )
    }

    /// Reads `bundle`'s event log, drawing the same absent-vs-unreadable
    /// distinction `MovieExporter.readBundleEvents` and
    /// `AutomationHost.readEventsForAutoTrim` already draw for `events.json`
    /// (§8) — a MISSING file is a partial bundle from an interrupted
    /// recording, which still deserves an answer rather than an error the
    /// agent cannot act on, but a file that EXISTS and fails to decode must
    /// be refused, not silently reported as "no markers".
    ///
    /// This was the one remaining `(try? EventLog.read(from: bundle))?.events
    /// ?? []` — the exact collapsing pattern a whole-branch review already
    /// fixed at `MovieExporter`'s and `AutomationHost`'s `events.json` call
    /// sites, and `DocumentOpener` fixed for `edit.json` — left standing on
    /// `snitt inspect`'s path. It is now doubly load-bearing (D60, M5f): a
    /// `schemaVersion` newer than this build understands throws from
    /// `EventLog.init(from:)`, and `try?` used to turn that refusal into a
    /// silently EMPTY marker list — an agent asking `snitt inspect` about a
    /// recording a newer Snitt build had already marked up would be told
    /// "no markers" instead of being told its own build is out of date.
    private static func readEvents(for bundle: SnittBundle) throws -> [LoggedEvent] {
        guard FileManager.default.fileExists(atPath: bundle.eventsURL.path) else {
            return []
        }
        return try EventLog.read(from: bundle).events
    }

    /// Reads `bundle`'s edit list, drawing the SAME absent-vs-unreadable
    /// distinction as `readEvents` above, for the same reasons.
    ///
    /// Absent is ordinary: a recording interrupted before its sidecars were
    /// written has no `edit.json`, and "nothing has been cut" is the truthful
    /// answer for it. A file that exists and will not decode is not ordinary —
    /// a `schemaVersion` from a newer build throws here — and reporting that as
    /// "no cuts" would tell an agent its bundle is untouched when a newer Snitt
    /// has already edited it. That is the confidently-wrong answer §8 forbids,
    /// and it is worse on this field than on markers: an agent told "no cuts"
    /// goes and cuts again.
    private static func readEDL(for bundle: SnittBundle) throws -> EditDecisionList {
        guard FileManager.default.fileExists(atPath: bundle.editURL.path) else {
            return .fullRange()
        }
        return try EditDecisionList.read(from: bundle)
    }
}
