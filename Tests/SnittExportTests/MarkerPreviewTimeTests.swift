// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// Where clicking a marker should put the playhead so the marker is VISIBLE.
///
/// Reported from the app: with Show Markers on, clicking a marker in the pane
/// shows the banner only "sometimes". It is not a race — at a banner's own
/// moment `appearance` returns opacity 0, because that instant is the first
/// frame of its arrival. Seeking exactly there is seeking to the one point in
/// the banner's window with nothing on screen, and it appeared to work only
/// when the seek settled a few tens of milliseconds late.
///
/// Every assertion here is therefore stated in terms of what `appearance`
/// answers AT the returned time, not in terms of the arithmetic that produced
/// it. Asserting `result == appearsAt + animateInSeconds` would pass against a
/// curve whose banner is invisible there, which is the bug this is for.
struct MarkerPreviewTimeTests {

    private func banners(at times: [Double], labels: [String]? = nil) -> [MarkerBanner] {
        let events = times.enumerated().map { index, time in
            LoggedEvent(timeSeconds: time, kind: .marker,
                        label: labels?[index] ?? "Marker \(index)", x: nil, y: nil)
        }
        return MarkerBanners.banners(events: events, keptRanges: [TimeRange(start: 0, end: 600)])
    }

    @Test("The marker's own moment shows NOTHING — which is the bug")
    func theBugItself() throws {
        // Pinned as its own test so the fix cannot be read as arbitrary. If
        // this ever stops holding, the nudge below has become unnecessary and
        // should go, rather than sitting there moving the playhead for a
        // reason that expired.
        let list = banners(at: [10])
        let banner = try #require(list.first)
        let look = try #require(MarkerBanners.appearance(of: banner, at: banner.appearsAt))
        #expect(look.opacity == 0)
        #expect(look.slide == 1)
    }

    @Test("The preview time is one where the banner is fully on screen")
    func previewTimeShowsTheBanner() throws {
        let list = banners(at: [10])
        let when = MarkerBanners.previewTime(forMarkerAt: 10, in: list)
        let banner = try #require(MarkerBanners.banner(at: when, in: list))
        #expect(banner.text == "Marker 0", "the nudge landed on a different marker")
        let look = try #require(MarkerBanners.appearance(of: banner, at: when))
        #expect(look.opacity == 1, "the banner is still fading in at \(when)")
        #expect(look.slide == 0, "the banner is still sliding in at \(when)")
    }

    @Test("It stays close enough to still be that marker's moment")
    func nudgeIsSmall() {
        // The playhead is no longer exactly on the marker, which is a real
        // cost — bounded here so a later change to the animation cannot turn a
        // nudge into a jump. `currentChapterID` uses a 0.01s tolerance and
        // takes the last chapter at or before the playhead, so anything short
        // of the next marker keeps the row highlighted.
        let when = MarkerBanners.previewTime(forMarkerAt: 10, in: banners(at: [10]))
        #expect(when > 10)
        #expect(when - 10 <= 0.5, "the playhead moved \(when - 10)s past the marker")
    }

    @Test("An unlabelled marker is not nudged at all")
    func unlabelledMarkersAreUntouched() {
        // No banner is drawn for one (`MarkerBanners.banners` drops it), so
        // there is nothing to wait for and moving the playhead off the thing
        // that was clicked would be a cost with no benefit.
        let list = banners(at: [4, 10], labels: ["kept", "   "])
        #expect(MarkerBanners.previewTime(forMarkerAt: 10, in: list) == 10)
    }

    @Test("With Show Markers off, the playhead lands exactly on the marker")
    func noBannersMeansNoNudge() {
        // The editor passes `markerBanners`, which is empty when the toggle is
        // off. No preview to aim at, so the seek must be exact — a pane that
        // moved the playhead off-marker to reveal something that is not being
        // drawn would be strictly worse than before.
        #expect(MarkerBanners.previewTime(forMarkerAt: 10, in: []) == 10)
    }

    @Test("Two markers closer than the animation never preview the wrong one")
    func closeMarkersDoNotCrossOver() throws {
        // The case that makes a fixed `+ animateInSeconds` wrong. Markers a
        // tenth of a second apart leave no room for the first to reach rest
        // before the second appears, and `banner(at:)` answers with the LAST
        // match — so the naive nudge would show marker two while marker one
        // was clicked, silently, with the right row highlighted.
        let list = banners(at: [10, 10.1])
        let when = MarkerBanners.previewTime(forMarkerAt: 10, in: list)
        #expect(when < 10.1, "the nudge crossed into the next marker's banner")
        let shown = try #require(MarkerBanners.banner(at: when, in: list))
        #expect(shown.text == "Marker 0", "clicking the first marker previewed \(shown.text)")
        // And it is still further in than the invisible first frame.
        let look = try #require(MarkerBanners.appearance(of: shown, at: when))
        #expect(look.opacity > 0)
    }

    @Test("A marker with no banner in the list is returned unchanged")
    func unknownTimeIsIdentity() {
        // A marker inside a cut has no banner, and a stale click should move
        // the playhead where it was told rather than to some other marker.
        #expect(MarkerBanners.previewTime(forMarkerAt: 999, in: banners(at: [10])) == 999)
    }
}
