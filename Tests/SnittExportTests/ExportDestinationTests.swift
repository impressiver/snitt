// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport

/// The destination presets.
///
/// These are facts about other people's servers, so most of what can be
/// asserted is internal consistency rather than truth — a test cannot know
/// what GitHub accepts today. What it CAN do is fail when a preset would
/// produce a file that its own stated limit rejects, which is the mistake that
/// actually ships.
struct ExportDestinationTests {

    @Test("Every destination is usable — no zero ceilings, no unknown formats")
    func presetsAreWellFormed() {
        // A zero or negative ceiling would make the size ladder walk to its
        // smallest rung and still report failure, which reads as "export is
        // broken" rather than "this preset is wrong".
        for d in ExportDestination.all {
            #expect(d.maxSizeBytes > 0, "\(d.name) has a nonsense size ceiling")
            #expect(["mp4", "gif"].contains(d.format), "\(d.name) has format \(d.format)")
            #expect(!d.name.isEmpty)
            if let duration = d.maxDurationSeconds {
                #expect(duration > 0, "\(d.name) has a nonsense duration limit")
            }
        }
    }

    @Test("Identifiers are unique, so a menu selection resolves to one preset")
    func idsAreUnique() {
        let ids = ExportDestination.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate destination ids: \(ids)")
        for id in ids {
            #expect(ExportDestination.named(id)?.id == id)
        }
        #expect(ExportDestination.named("myspace") == nil)
    }

    @Test("Every platform the product owner asked for is present")
    func theRequestedPlatformsAreCovered() {
        // Named explicitly rather than counted: a count passes when one is
        // swapped for another, and the list came from a specific request.
        let ids = Set(ExportDestination.all.map(\.id))
        for expected in ["slack", "github", "linkedin", "x", "reddit",
                         "youtube", "tiktok", "facebook"] {
            #expect(ids.contains(expected), "no preset for \(expected)")
        }
    }

    @Test("GitHub uses the limit that cannot fail, not the generous one")
    func githubUsesTheFreePlanCeiling() {
        // 10 MB free, 100 MB paid. The asymmetry is the whole argument: a paid
        // user is mildly inconvenienced by a smaller file, while a free user
        // with a 100 MB file is stopped at the moment of posting — after the
        // export, when they have already moved on. Pinned because "raise it to
        // 100, most people are on paid plans" is a plausible future edit.
        #expect(ExportDestination.github.maxSizeBytes == 10_000_000)
        #expect(ExportDestination.github.note?.contains("free-plan") == true,
                "the tier the number comes from must be visible to the user")
    }

    @Test("A duration limit is reported, never enforced by trimming")
    func durationIsAdvisoryOnly() {
        // Snitt must not cut the end off a recording to satisfy somebody
        // else's policy — the person would find out by watching their own demo
        // stop mid-sentence. `exceedsDuration` answers a question; nothing
        // acts on it.
        let slack = ExportDestination.slack
        #expect(slack.exceedsDuration(301))
        #expect(!slack.exceedsDuration(299))
        #expect(!slack.exceedsDuration(300), "the limit itself is allowed")

        // And a destination with no limit never reports one, however long.
        #expect(!ExportDestination.youtube.exceedsDuration(60 * 60 * 5))
    }

    @Test("Presets carry a verification date, because these numbers go stale")
    func limitsAreDated() {
        // The failure mode of a stale limit is the worst kind: the export
        // succeeds and somebody else's server refuses the upload afterwards.
        // A date makes "these are out of date" checkable instead of a hunch.
        #expect(!ExportDestination.verifiedOn.isEmpty)
        #expect(ExportDestination.verifiedOn.count == 10, "expected YYYY-MM-DD")
    }

    @Test("Nothing exports above 1080p except where full quality is the point")
    func resolutionsAreSensibleForUpload() {
        // Every destination re-encodes what it receives, so shipping 4K into a
        // 10 MB ceiling spends the whole budget on pixels nobody will see and
        // forces the size ladder down to a scale that looks worse than 1080p
        // would have. YouTube is the deliberate exception: it keeps what it is
        // given and re-encodes from that.
        for d in ExportDestination.all where d.id != "youtube" {
            #expect(d.resolution == .hd1080p, "\(d.name) exports at \(d.resolution)")
        }
        #expect(ExportDestination.youtube.resolution == .source)
    }
}
