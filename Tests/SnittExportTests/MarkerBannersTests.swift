// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// Marker banners: when they appear, how long they stay, and how they move.
///
/// The curve is asserted here rather than looked at, because the export burns
/// it through `AVVideoCompositionCoreAnimationTool` while the editor draws it
/// into a layer. Two implementations of one easing curve drift the moment
/// either is touched, and the symptom — a banner that animates differently in
/// the preview than in the file — is invisible until somebody compares them
/// side by side.
struct MarkerBannersTests {

    private let whole = [TimeRange(start: 0, end: 120)]

    private func marker(_ label: String?, at time: Double) -> LoggedEvent {
        LoggedEvent(timeSeconds: time, kind: .marker, label: label, x: nil, y: nil)
    }

    @Test("A labelled marker becomes a banner at its own moment")
    func markerBecomesBanner() throws {
        let banners = MarkerBanners.banners(events: [marker("Bug reproduces here", at: 4)],
                                            keptRanges: whole)
        let banner = try #require(banners.first)
        #expect(banner.text == "Bug reproduces here")
        #expect(abs(banner.appearsAt - 4) < 1e-9)
    }

    @Test("An unlabelled marker draws nothing")
    func unlabelledMarkersAreSkipped() {
        // A marker with no label is a navigation point, not an annotation.
        // Drawing it would put a branded rectangle on the frame saying nothing.
        #expect(MarkerBanners.banners(events: [marker(nil, at: 1)], keptRanges: whole).isEmpty)
        #expect(MarkerBanners.banners(events: [marker("   ", at: 1)], keptRanges: whole).isEmpty)
    }

    @Test("Only markers become banners")
    func otherEventsAreIgnored() {
        // Clicks and keystrokes carry no label worth showing, and a click
        // banner would fire on every click in the recording.
        let events = [LoggedEvent(timeSeconds: 1, kind: .click, label: nil, x: 0.5, y: 0.5),
                      LoggedEvent(timeSeconds: 2, kind: .keystroke, label: nil, x: nil, y: nil)]
        #expect(MarkerBanners.banners(events: events, keptRanges: whole).isEmpty)
    }

    @Test("A marker inside a cut has no banner")
    func cutMarkersAreDropped() {
        let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 8, end: 20)]
        let banners = MarkerBanners.banners(
            events: [marker("gone", at: 5), marker("kept", at: 9)], keptRanges: kept)
        #expect(banners.map(\.text) == ["kept"])
    }

    @Test("Longer text is held longer, within bounds")
    func holdScalesWithReading() {
        // The same reading speed the captions use. A banner and a caption are
        // both text somebody has to read, and two reading speeds in one frame
        // would be indefensible.
        let short = MarkerBanners.hold(for: "Bug")
        let long = MarkerBanners.hold(for: String(repeating: "word ", count: 20))
        #expect(short < long)
        #expect(short >= MarkerBanners.minimumHoldSeconds)
        #expect(long <= MarkerBanners.maximumHoldSeconds,
                "a very long label would sit on the frame for \(long)s")
        #expect(MarkerBanners.wordsPerSecond == WebVTTSubtitles.wordsPerSecond)
    }

    @Test("Two banners are never on screen together")
    func bannersDoNotOverlap() {
        // They occupy the same corner, so an overlap is not a layout nuance —
        // the second draws on top of the first and both become unreadable.
        let banners = MarkerBanners.banners(
            events: [marker("first", at: 1), marker("second", at: 2)], keptRanges: whole)
        #expect(banners.count == 2)
        for (a, b) in zip(banners, banners.dropFirst()) {
            #expect(a.endsAt <= b.appearsAt + 1e-9,
                    "'\(a.text)' ends at \(a.endsAt), after '\(b.text)' starts at \(b.appearsAt)")
        }
    }

    @Test("Markers packed tighter than the animation still yield no negative hold")
    func impossiblyCloseMarkers() throws {
        // Two markers a tenth of a second apart leave no room for a hold. The
        // first should read as a flash, not as a banner with negative duration
        // drawn underneath the next one.
        let banners = MarkerBanners.banners(
            events: [marker("a", at: 1.0), marker("b", at: 1.1)], keptRanges: whole)
        let first = try #require(banners.first)
        #expect(first.holdSeconds >= 0, "negative hold: \(first.holdSeconds)")
    }

    @Test("A banner fades and slides in, rests, then leaves")
    func theCurveHasThreePhases() throws {
        let banner = MarkerBanner(appearsAt: 10, text: "Note", holdSeconds: 2)

        // Entering: partly visible, still offset.
        let entering = try #require(
            MarkerBanners.appearance(of: banner, at: 10 + MarkerBanners.animateInSeconds / 2))
        #expect(entering.opacity > 0 && entering.opacity < 1)
        #expect(entering.slide > 0, "it should still be offset while arriving")

        // Resting: fully visible, in place. This is the state that must be
        // exactly 1 and exactly 0 — a banner that never quite settles reads
        // as a rendering bug rather than as motion.
        let resting = try #require(MarkerBanners.appearance(of: banner, at: 11))
        #expect(resting.opacity == 1)
        #expect(resting.slide == 0)

        // Leaving: fading, moving away again.
        let leaving = try #require(
            MarkerBanners.appearance(of: banner, at: banner.endsAt - MarkerBanners.animateOutSeconds / 2))
        #expect(leaving.opacity > 0 && leaving.opacity < 1)
        #expect(leaving.slide > 0)
    }

    @Test("Nothing is drawn before a banner appears or after it leaves")
    func outsideTheWindowIsNil() {
        let banner = MarkerBanner(appearsAt: 10, text: "Note", holdSeconds: 2)
        #expect(MarkerBanners.appearance(of: banner, at: 9.99) == nil)
        #expect(MarkerBanners.appearance(of: banner, at: banner.endsAt) == nil)
        #expect(MarkerBanners.appearance(of: banner, at: banner.endsAt + 1) == nil)
    }

    @Test("Entry decelerates and exit accelerates, rather than both being linear")
    func easingIsNotLinear() throws {
        // The difference between "arriving and settling" and "sliding past".
        // A linear curve satisfies every other assertion here, so this is the
        // one that pins the easing itself.
        let banner = MarkerBanner(appearsAt: 0, text: "Note", holdSeconds: 2)
        let quarterIn = try #require(
            MarkerBanners.appearance(of: banner, at: MarkerBanners.animateInSeconds * 0.25))
        // Ease-OUT is ahead of linear at the same fraction of the way through.
        #expect(quarterIn.opacity > 0.25, "entry is linear or slower: \(quarterIn.opacity)")

        let quarterOut = try #require(
            MarkerBanners.appearance(of: banner,
                                     at: banner.endsAt - MarkerBanners.animateOutSeconds * 0.75))
        // Ease-IN is behind linear — still nearly fully visible a quarter of
        // the way out.
        #expect(quarterOut.opacity > 0.75, "exit is linear or faster: \(quarterOut.opacity)")
    }

    @Test("Lookup finds the banner for a moment")
    func lookupAtATime() {
        let banners = MarkerBanners.banners(
            events: [marker("one", at: 1), marker("two", at: 30)], keptRanges: whole)
        #expect(MarkerBanners.banner(at: 1.1, in: banners)?.text == "one")
        #expect(MarkerBanners.banner(at: 20, in: banners) == nil)
        #expect(MarkerBanners.banner(at: 30.1, in: banners)?.text == "two")
    }
}
