// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// D107's export overrides for the two burned-in overlays.
///
/// `showSubtitles` and `showMarkers` are document properties set in the
/// editor, and an agent has no editor. Exposing them on the export verb is the
/// whole point; getting the ABSENT case wrong is the hazard.
@Suite
struct EditDecisionListOverlayTests {

    private func edl(captions: Bool, markers: Bool) -> EditDecisionList {
        EditDecisionList(cuts: [], trackStates: [],
                         showSubtitles: captions, showMarkers: markers)
    }

    @Test("Passing nothing leaves what the document already says")
    func absentOverridesChangeNothing() {
        // DISCRIMINATES AGAINST: `captions: Bool = false` instead of `Bool?`,
        // which is the obvious way to write this and is silently wrong. A
        // person who turned captions on in the editor, then asked an agent to
        // export, would get a video with no captions and no error anywhere,
        // exactly §8's confidently-wrong outcome. With a `false` default this
        // test reads `showSubtitles == false` and fails.
        let document = edl(captions: true, markers: true)
        let exported = document.drawing(captions: nil, markerBanners: nil)
        #expect(exported.showSubtitles == true)
        #expect(exported.showMarkers == true)
    }

    @Test("An override is applied, in both directions")
    func overridesApply() {
        // The control for the test above: a `drawing` that ignored its
        // arguments entirely would pass `absentOverridesChangeNothing` and be
        // useless.
        let off = edl(captions: false, markers: false)
        #expect(off.drawing(captions: true, markerBanners: true).showSubtitles == true)
        #expect(off.drawing(captions: true, markerBanners: true).showMarkers == true)

        let on = edl(captions: true, markers: true)
        #expect(on.drawing(captions: false, markerBanners: nil).showSubtitles == false)
        // And only the one asked about moves.
        #expect(on.drawing(captions: false, markerBanners: nil).showMarkers == true)
    }

    // The other half of "an export is not an edit", that asking for captions
    // on one export does not turn them on in the person's document for ever,
    // is asserted where it can actually go wrong: `AutomationHostTests`'
    // `exportDoesNotWriteOverlayOverridesBackToTheBundle`, which reads
    // `edit.json` off disk afterwards. A version of that claim here would only
    // be testing that a Swift struct is a value type.

    @Test("Nothing else about the edit moves")
    func everythingElseSurvives() {
        // A copy-and-replace implementation that rebuilt the EDL from the two
        // flags would silently drop cuts, the crop and the takes, the D60
        // data-loss shape, which this repo has shipped once already.
        var document = EditDecisionList(
            cuts: [Cut(range: TimeRange(start: 1, end: 2))],
            trackStates: [TrackState(track: "microphone", muted: true)],
            crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5),
            showClicks: true)
        document.showSubtitles = false
        let exported = document.drawing(captions: true, markerBanners: nil)
        #expect(exported.cuts.count == 1)
        #expect(exported.trackStates.first?.muted == true)
        #expect(exported.crop?.width == 0.5)
        #expect(exported.showClicks == true)
        #expect(exported.showSubtitles == true)
    }
}
