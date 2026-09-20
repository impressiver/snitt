// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Somewhere a recording is going, and what that place will accept.
///
/// The job is narrow and worth stating: turn "I am putting this in a pull
/// request" into the three settings the exporter already takes — a size
/// ceiling, a resolution and a format — so nobody has to know that GitHub
/// rejects anything over 10 MB until it rejects it.
///
/// **Every limit here goes stale, so each one is dated and sourced.** Platforms
/// change these without announcing it, and a number in a `let` with no
/// provenance is indistinguishable from a number somebody guessed. `verifiedOn`
/// is what makes "these are out of date" a checkable claim rather than a
/// suspicion.
///
/// **Where a platform has tiers, the limit is the one that CANNOT FAIL.**
/// GitHub allows 10 MB on free plans and 100 MB on paid; this uses 10. A paid
/// user is mildly inconvenienced by a smaller file, while a free user with a
/// 100 MB file is stopped dead at the moment they try to post it — and they
/// find out after the export, not before. Asymmetric costs, so the conservative
/// number wins.
public struct ExportDestination: Equatable, Sendable, Identifiable {
    public let id: String
    /// What the menu says.
    public let name: String
    public let maxSizeBytes: Int
    /// Nil where the ceiling is far beyond any plausible screen recording.
    ///
    /// A duration limit is deliberately NOT enforced by trimming. Snitt will
    /// not silently cut the end off a recording to make it fit somewhere —
    /// that destroys content to satisfy a policy, and the person would find out
    /// by watching their own demo stop mid-sentence. It is reported instead.
    public let maxDurationSeconds: Double?
    public let resolution: ExportResolution
    /// A `MovieExporter` format string — `"mp4"` or `"gif"`.
    public let format: String
    /// What the person should know that the numbers do not say.
    public let note: String?

    public init(id: String, name: String, maxSizeBytes: Int,
                maxDurationSeconds: Double?, resolution: ExportResolution,
                format: String = "mp4", note: String? = nil) {
        self.id = id
        self.name = name
        self.maxSizeBytes = maxSizeBytes
        self.maxDurationSeconds = maxDurationSeconds
        self.resolution = resolution
        self.format = format
        self.note = note
    }

    /// When these limits were last checked against the platforms' own docs.
    ///
    /// Surfaced in the UI rather than buried here, because a stale limit fails
    /// in the worst way: the export succeeds, and the upload is refused by
    /// somebody else's server after the user has already moved on.
    public static let verifiedOn = "2026-09-12"

    /// H.264 everywhere, and it is not a default — it is a requirement.
    ///
    /// GitHub's own documentation recommends H.264 "for greatest
    /// compatibility", and notes that video codec support is browser-specific:
    /// a file that plays for the person who uploaded it may not play for the
    /// person reading the pull request. This is the same reason the capture
    /// encoder was left on H.264 rather than moved to HEVC.
    public static let codecNote = "H.264, for the widest browser support"

    public static let github = ExportDestination(
        id: "github", name: "GitHub",
        // 10 MB is the FREE-plan ceiling; paid plans allow 100. See the type's
        // note on tiers — a file that a free-plan reader cannot post is worse
        // than one that is smaller than it had to be.
        maxSizeBytes: 10_000_000, maxDurationSeconds: nil,
        resolution: .hd1080p,
        note: "10 MB is the free-plan limit; paid plans allow 100 MB.")

    public static let slack = ExportDestination(
        id: "slack", name: "Slack",
        // Slack's file ceiling is 1 GB, which no screen recording will reach
        // before its 5-minute clip limit does. The binding constraint here is
        // duration, not size, so the size figure is set to something sane for
        // a chat message rather than to Slack's actual maximum.
        maxSizeBytes: 100_000_000, maxDurationSeconds: 300,
        resolution: .hd1080p,
        note: "Slack caps video clips at 5 minutes.")

    public static let x = ExportDestination(
        id: "x", name: "X",
        maxSizeBytes: 512_000_000, maxDurationSeconds: 140,
        resolution: .hd1080p,
        note: "2 minutes 20 seconds on a free account; Premium allows far more.")

    public static let linkedin = ExportDestination(
        id: "linkedin", name: "LinkedIn",
        maxSizeBytes: 5_000_000_000, maxDurationSeconds: 600,
        resolution: .hd1080p, note: nil)

    public static let reddit = ExportDestination(
        id: "reddit", name: "Reddit",
        maxSizeBytes: 1_000_000_000, maxDurationSeconds: 900,
        resolution: .hd1080p, note: nil)

    public static let youtube = ExportDestination(
        id: "youtube", name: "YouTube",
        // YouTube's real ceilings are so far beyond a screen recording that
        // quoting them would be noise. What matters is that nothing is thrown
        // away, so this exports at source.
        maxSizeBytes: 2_000_000_000, maxDurationSeconds: nil,
        resolution: .source,
        note: "Exported at full quality. YouTube re-encodes anyway.")

    public static let tiktok = ExportDestination(
        id: "tiktok", name: "TikTok",
        // The most restrictive size ceiling of the eight, and the reported
        // range (72-287 MB) varies by platform, so the low end is used.
        maxSizeBytes: 72_000_000, maxDurationSeconds: 600,
        resolution: .hd1080p,
        note: "TikTok is vertical; a landscape recording will be letterboxed.")

    public static let facebook = ExportDestination(
        id: "facebook", name: "Facebook",
        maxSizeBytes: 4_000_000_000, maxDurationSeconds: 14_400,
        resolution: .hd1080p, note: nil)

    /// Ordered the way the menu shows them: the two a developer reaches for
    /// daily first, then the rest.
    public static let all: [ExportDestination] = [
        .github, .slack, .x, .linkedin, .reddit, .youtube, .tiktok, .facebook,
    ]

    public static func named(_ id: String) -> ExportDestination? {
        all.first { $0.id == id }
    }
}

extension ExportDestination {
    /// Whether a recording of `seconds` is too long for this destination.
    ///
    /// Reported, never acted on. Trimming to fit would destroy content to
    /// satisfy somebody else's policy, and the person would discover it by
    /// watching their own demo stop mid-sentence.
    public func exceedsDuration(_ seconds: Double) -> Bool {
        guard let limit = maxDurationSeconds else { return false }
        return seconds > limit
    }
}
