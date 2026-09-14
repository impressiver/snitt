// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument
import SnittBrand

/// The zoom control and the timeline agreeing about the zoom.
///
/// Reported as "zooming the timeline with mouse should adjust the scale
/// control to match". The slider read `zoomFraction` straight off the
/// `NSView`, which publishes nothing — so a scroll or a pinch moved the
/// timeline and left the control where it was. It looked right during
/// PLAYBACK only, because the 20Hz playhead poll was re-rendering the
/// transport for unrelated reasons; paused, the control simply lied.
@Suite(.serialized)
@MainActor
struct TimelineZoomSyncTests {
    init() { _ = NSApplication.shared }

    private func makeView() -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        view.update(duration: 60, cuts: [], markerPoints: [], playhead: 0)
        return view
    }

    @Test("Every zoom route reports the new fraction")
    func everyRouteReports() {
        // Asserted per ROUTE rather than once, because they are different
        // entry points and the callback lives in the one they all funnel
        // through — which is the claim being tested, not an implementation
        // detail to take on trust.
        let view = makeView()
        var reported: [Double] = []
        view.onZoomChanged = { reported.append($0) }

        view.zoomIn()
        #expect(reported.last == view.zoomFraction, "zoomIn did not report")
        let afterIn = reported.count

        view.zoomOut()
        #expect(reported.count > afterIn, "zoomOut did not report")
        #expect(reported.last == view.zoomFraction)

        view.setZoomFraction(0.7)
        #expect(reported.last == view.zoomFraction, "the slider's own write did not report")
    }

    @Test("A scroll-wheel zoom reports too — the route that was broken")
    func scrollWheelReports() throws {
        // The one actually reported. Driven through a real scroll event rather
        // than by calling `setZoom`, because "they all funnel through setZoom"
        // is exactly the assumption that would make this test vacuous.
        let view = makeView()
        var reported: [Double] = []
        view.onZoomChanged = { reported.append($0) }

        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
        // The modifier the timeline requires for zoom rather than scroll.
        scroll.flags = .maskCommand
        let event = try #require(NSEvent(cgEvent: scroll))
        view.scrollWheel(with: event)

        #expect(!reported.isEmpty, "a scroll-wheel zoom reported nothing")
        #expect(reported.last == view.zoomFraction)
    }

    @Test("Zooming past the end reports the CLAMPED value, not the requested one")
    func clampedZoomReportsWhatHappened() {
        // Otherwise the slider would run past its own end while the timeline
        // stopped — the control and the view disagreeing in the other
        // direction, which is the same defect wearing different clothes.
        let view = makeView()
        var reported: [Double] = []
        view.onZoomChanged = { reported.append($0) }

        for _ in 0..<20 { view.zoomIn() }
        #expect(reported.last == view.zoomFraction)
        #expect((reported.last ?? 0) <= 1.0)
    }
}

/// The voiceover lane's colour.
@Suite
struct VoiceoverLaneColourTests {

    @Test("Narration is drawn in the colour its words are")
    func laneMatchesTheTranscript() {
        // The lane was the brand's amber, which says "this is one of the
        // recorded tracks" — the one thing it is not — while the transcript
        // two panes away was already colouring the same audio differently.
        #expect(TimelineView.Palette.waveform(for: "voiceover", muted: false)
                == SnittPalette.voiceover)
        #expect(TimelineView.Palette.waveform(for: "microphone", muted: false)
                == SnittPalette.signal)
        #expect(TimelineView.Palette.waveform(for: "voiceover", muted: false)
                != TimelineView.Palette.waveform(for: "microphone", muted: false))
    }

    @Test("Muting dims narration without turning it back into a recorded track")
    func mutedNarrationKeepsItsHue() {
        // A muted voiceover drawn in muted AMBER would read as a muted
        // microphone, which is a different track being silenced.
        let muted = TimelineView.Palette.waveform(for: "voiceover", muted: true)
        #expect(muted != TimelineView.Palette.waveform(for: "voiceover", muted: false))
        #expect(muted != TimelineView.Palette.waveform(for: "microphone", muted: true))
    }

    @Test("An unknown track keeps the ordinary waveform colour")
    func unknownTracksAreUnchanged() {
        // Asked by NAME, not by lane index: the lane order is a display choice
        // while the composition's order is not, and an index-based answer is
        // the defect that once gave system audio the state named "video".
        #expect(TimelineView.Palette.waveform(for: "systemAudio", muted: false)
                == SnittPalette.signal)
    }
}
