// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

public enum Initiator: String, Codable, Sendable {
    case human
    case agent
}

/// Git provenance for a recording made inside a repository (spec section 7).
public struct GitContext: Codable, Sendable, Equatable {
    public var branch: String?
    public var commit: String?

    public init(branch: String? = nil, commit: String? = nil) {
        self.branch = branch
        self.commit = commit
    }
}

/// Capture health metrics (spec section 12.1). Populated in M2; defined now
/// so the meta.json schema does not change when M2 lands.
public struct CaptureHealth: Codable, Sendable, Equatable {
    public var meanFrameVariance: Double?
    public var micRMS: Double?
    public var systemAudioRMS: Double?
    /// Where the Mac was playing sound during the recording, as
    /// `AudioOutputRoute`'s raw value — `"builtInSpeakers"`, `"headphones"`,
    /// `"external"` or `"unknown"`.
    ///
    /// A `String` rather than the enum because that type lives in
    /// `SnittCapture`, which depends on this module and not the other way
    /// round. Recorded so a poor transcript can be EXPLAINED after the fact:
    /// `"builtInSpeakers"` alongside a non-nil `micRMS` and `systemAudioRMS`
    /// means the microphone was recording the speakers as well as the voice,
    /// which is the difference between "the recogniser is bad" and "the take
    /// was unusable before it started" (D73).
    public var outputRoute: String?

    public init(meanFrameVariance: Double? = nil,
                micRMS: Double? = nil,
                systemAudioRMS: Double? = nil,
                outputRoute: String? = nil) {
        self.meanFrameVariance = meanFrameVariance
        self.micRMS = micRMS
        self.systemAudioRMS = systemAudioRMS
        self.outputRoute = outputRoute
    }
}

/// The sidecar written beside `capture.mov` (spec section 7).
///
/// **Two clocks live in a bundle, and they are not the same one.**
///
/// - `durationSeconds` here is WALL time: stamped when `Recorder.start()` is
///   called — before `SCStream.startCapture()` — to when `stop()` runs. It
///   therefore OVERSTATES the length of `capture.mov` by however long the
///   stream took to come up (hundreds of milliseconds, typically).
/// - Marker offsets in `events.json` are MEDIA time: seconds from the first
///   delivered frame's presentation timestamp, which is `capture.mov`'s own
///   t=0. That is the clock a player, a scrubber, or an M3b chapter list
///   works in.
///
/// So a consumer must not mix them. `marker / durationSeconds` is not a
/// fraction of the movie, and `durationSeconds` is not a chapter's end time —
/// use the asset's own duration (`AVAsset.duration`) for anything positioned
/// against the media. A marker can never EXCEED `durationSeconds`, since the
/// media clock starts later and stops earlier, so nothing falls outside its
/// recording; the skew is a small overstatement at the tail.
///
/// `durationSeconds`' meaning is deliberately NOT changed: "how long the
/// recording ran" is what a human reading meta.json expects, and it has
/// consumers already.
public struct RecordingMetadata: Codable, Sendable {
    public var schemaVersion: Int
    /// Wall-clock instant `Recorder.start()` was called.
    public var createdAt: Date
    public var initiator: Initiator
    /// WALL-clock seconds from `start()` to `stop()` — see the note above.
    /// Not the duration of `capture.mov`, which is shorter by the stream's
    /// startup latency, and not the clock marker offsets are on.
    public var durationSeconds: Double?
    /// Words the speech recogniser should expect to hear (D62's correction
    /// burden, D81).
    ///
    /// Stored on the RECORDING rather than in a global setting because the
    /// vocabulary that matters is the one this session was about: a demo of
    /// `KeptRanges` and a demo of `SCContentSharingPicker` need different
    /// hints, and a setting would carry the wrong one into both. It also
    /// survives re-transcription, which is when a better hint is most likely
    /// to be wanted.
    public var vocabulary: [String]?
    public var git: GitContext?
    public var health: CaptureHealth?
    /// How an AGENT's session ended, stamped after the bundle was finalised
    /// (D108). One of `AuditOutcome`'s strings, today `"completed"` or
    /// `"capped"`.
    ///
    /// Written here as well as in the audit trail because the audit trail is
    /// keyed by SESSION ID and carries no bundle path, so nothing could join
    /// the two: §5.3's watchdog force-stops an abandoned agent's recording,
    /// finalises a perfectly good bundle and records `capped`, and the bundle
    /// itself had no way to say it was debris rather than a finished demo.
    /// `snitt recordings list` is the reader.
    ///
    /// `nil` covers three cases and does not distinguish them: a recording a
    /// person made with the hotkey (which never passes through
    /// `AutomationHost` at all, and which `initiator` already identifies), a
    /// session still running, and a bundle written before this field existed.
    /// None of them is debris an agent needs to find, which is why one nil is
    /// enough. Optional and absent-means-nil, so every bundle already on disk
    /// keeps opening.
    public var outcome: String?

    public init(schemaVersion: Int = 1,
                createdAt: Date,
                initiator: Initiator,
                durationSeconds: Double? = nil,
                git: GitContext? = nil,
                health: CaptureHealth? = nil,
                vocabulary: [String]? = nil,
                outcome: String? = nil) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.initiator = initiator
        self.durationSeconds = durationSeconds
        self.git = git
        self.health = health
        self.vocabulary = vocabulary
        self.outcome = outcome
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.metaURL)
    }

    public static func read(from bundle: SnittBundle) throws -> RecordingMetadata {
        try JSONCoding.decoder.decode(
            RecordingMetadata.self, from: Data(contentsOf: bundle.metaURL)
        )
    }
}

/// Shared JSON configuration. ISO-8601 dates and sorted keys keep bundle
/// files diffable and stable across writes.
enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
