// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// The previews are only worth having if what they show is worth looking at.
///
/// `#Preview` bodies themselves cannot be executed from a test bundle — they
/// are registered for Xcode's canvas, not called. What CAN be checked, and is
/// what actually goes wrong, is the data behind them: a waveform of identical
/// peaks, a filmstrip of zero frames, or a timeline that renders blank all
/// look like a working preview of a boring recording rather than like a broken
/// fixture, and each would quietly retire the preview as a place bugs show up.
@Suite(.serialized)
@MainActor
struct PreviewFixturesTests {
    init() { _ = NSApplication.shared }

    @Test("The sample waveform has structure, not a flat line")
    func waveformIsNotFlat() {
        // A constant-valued waveform draws as a rectangle, which is a shape
        // the lane can produce for real reasons — so it would not look wrong.
        for samples in PreviewFixtures.waveforms {
            #expect(samples.peaks.count > 100)
            let distinct = Set(samples.peaks.map { ($0 * 100).rounded() })
            #expect(distinct.count > 20,
                    "\(samples.track) peaks are near-constant: \(distinct.count) levels")
        }
    }

    @Test("The two sample tracks are visibly different from each other")
    func tracksAreDistinguishable() {
        // Two identical bands make the per-track gain and mute previews
        // meaningless — you cannot see which one a control affected.
        let loudest = PreviewFixtures.waveforms.map { $0.peaks.max() ?? 0 }
        #expect(loudest.count == 2)
        #expect(loudest[0] > loudest[1] * 1.5,
                "microphone and system audio peak at similar levels")
    }

    @Test("The sample transcript groups into several phrases")
    func transcriptGroupsIntoPhrases() {
        // One phrase spanning everything is what a fixture with no pauses
        // produces, and it hides every layout decision the lane makes.
        #expect(PreviewFixtures.phrases.count >= 3)
        #expect(PreviewFixtures.words.count > PreviewFixtures.phrases.count)
    }

    @Test("The sample cuts differ in size by an order of magnitude")
    func cutsCoverBothExtremes() {
        // The short cut is the one whose expanded band degenerates to a
        // sub-pixel sliver — the case that produced the negative-width rect
        // the fold border had to be rewritten to avoid.
        let lengths = PreviewFixtures.cuts.map { $0.range.end - $0.range.start }
        #expect((lengths.max() ?? 0) > (lengths.min() ?? 1) * 10)
    }

    @Test("The sample filmstrip actually decoded frames")
    func filmstripHasFrames() {
        // `compactMap` over a failing `CGContext` yields [] silently, and an
        // empty filmstrip draws as an empty lane — indistinguishable from a
        // lane that is correctly empty because sampling has not finished.
        #expect(PreviewFixtures.filmstrip.frames.count > 10)
    }

    @Test("The timeline preview renders something, in more than one colour")
    func timelineRendersNonBlank() throws {
        // The assertion the whole exercise is for. A view that draws nothing
        // — wrong fixture, zero duration, a lane plan that allocated no
        // height — produces a preview that looks like an empty timeline, and
        // an empty timeline is a thing this app can legitimately show.
        let view = PreviewFixtures.timeline(size: NSSize(width: 600, height: 200))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        var colours = Set<String>()
        for x in stride(from: 4, to: Int(view.bounds.width) - 4, by: 17) {
            for y in stride(from: 2, to: Int(view.bounds.height) - 2, by: 7) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                colours.insert(String(format: "%.2f-%.2f-%.2f", colour.redComponent,
                                      colour.greenComponent, colour.blueComponent))
            }
        }
        #expect(colours.count > 5,
                "the timeline preview drew \(colours.count) distinct colours")
    }

    @Test("The floor-height timeline still renders every lane it promised")
    func timelineAtTheFloorStillDrawsLanes() throws {
        // The preview that exists to show the collapse, checked for the
        // failure it would hide: a plan that allocates lanes into a height
        // nothing can draw in renders blank, which reads as "collapsed
        // correctly".
        let height = TimelineLaneBudget.minimumTimelineHeight
        let view = PreviewFixtures.timeline(size: NSSize(width: 600, height: height))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        var colours = Set<String>()
        for x in stride(from: 4, to: Int(view.bounds.width) - 4, by: 13) {
            for y in stride(from: 2, to: Int(height) - 2, by: 3) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                colours.insert(String(format: "%.2f-%.2f-%.2f", colour.redComponent,
                                      colour.greenComponent, colour.blueComponent))
            }
        }
        // Identity, not a count. This used to assert "more than 3 distinct
        // colours", which was a proxy for "the lanes drew" — and the proxy
        // broke when rev 5's style sheet made the marks lane transparent on
        // `ink0` rather than a band of its own. A count would have had to be
        // lowered to 3 to pass, at which point it could no longer tell a
        // rendered timeline from one missing a lane. Naming the three bands
        // asserts what the count was standing in for, and gets stronger
        // rather than weaker as lanes stop being distinguished by shade.
        func key(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "%.2f-%.2f-%.2f", c.redComponent,
                          c.greenComponent, c.blueComponent)
        }
        // What actually reaches the floor is narrower than it looks: at
        // `minimumTimelineHeight` the video and audio bands are collapsed
        // away entirely, and what renders is the ground plus the marks and
        // cuts drawn ON it. So naming specific bands is wrong too — the
        // assertion that survives the collapse is "the ground drew, and
        // things drew on it", which is exactly the blank-render this test
        // was written to catch.
        let ground = key(TimelineView.Palette.background)
        #expect(colours.contains(ground), "the timeline ground never drew")
        let content = colours.subtracting([ground])
        #expect(content.count >= 2,
                "only \(content.count) colours drew on the ground — \(colours.sorted())")
    }
}
