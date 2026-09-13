// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import CoreGraphics
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// When an export may copy samples instead of re-encoding them.
///
/// The stakes are asymmetric, which is why this is a whitelist. Wrongly
/// re-encoding costs a second. Wrongly copying emits the WRONG PICTURE —
/// uncropped, unscaled, or missing the overlay — and does it fast, silently,
/// and in the one path CI cannot run end to end.
struct PassthroughEligibilityTests {

    private func edl(crop: CropRect? = nil) -> EditDecisionList {
        EditDecisionList(cuts: [], trackStates: [TrackState(track: "video")], crop: crop)
    }

    @Test("A plain source export copies the samples")
    func plainSourceExportIsEligible() {
        #expect(PassthroughEligibility.disqualifier(
            resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl(),
            hasAudioMix: false) == nil)
    }

    @Test("Every transformation disqualifies, and says which one")
    func transformationsDisqualify() {
        // Each case changes exactly ONE input from the eligible baseline, so a
        // predicate that happened to return the right answer for the wrong
        // reason still fails. Asserting the reason rather than a bare false is
        // what makes that possible.
        let cases: [(String, PassthroughEligibility.Disqualifier, () -> PassthroughEligibility.Disqualifier?)] = [
            ("resolution", .resolutionChange, {
                PassthroughEligibility.disqualifier(resolution: .hd1080p, maxSizeBytes: nil,
                                                    clicks: [], edl: self.edl(),
                                                    hasAudioMix: false) }),
            ("size ceiling", .sizeLimit, {
                PassthroughEligibility.disqualifier(resolution: .source, maxSizeBytes: 10_000_000,
                                                    clicks: [], edl: self.edl(),
                                                    hasAudioMix: false) }),
            ("click overlay", .clickOverlay, {
                PassthroughEligibility.disqualifier(
                    resolution: .source, maxSizeBytes: nil,
                    clicks: [ClickMark(outputTime: 1, position: .zero)], edl: self.edl(),
                    hasAudioMix: false) }),
            ("crop", .crop, {
                PassthroughEligibility.disqualifier(
                    resolution: .source, maxSizeBytes: nil, clicks: [],
                    edl: self.edl(crop: CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)),
                    hasAudioMix: false) }),
            ("an audio mix", .audioMix, {
                PassthroughEligibility.disqualifier(resolution: .source, maxSizeBytes: nil,
                                                    clicks: [], edl: self.edl(),
                                                    hasAudioMix: true) }),
            ("burned-in subtitles", .burnedInText, {
                var edl = self.edl(); edl.showSubtitles = true
                return PassthroughEligibility.disqualifier(
                    resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl,
                    hasAudioMix: false) }),
            ("burned-in markers", .burnedInText, {
                var edl = self.edl(); edl.showMarkers = true
                return PassthroughEligibility.disqualifier(
                    resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl,
                    hasAudioMix: false) }),
            ("built at a smaller scale", .scaled, {
                PassthroughEligibility.disqualifier(resolution: .source, maxSizeBytes: nil,
                                                    clicks: [], edl: self.edl(),
                                                    hasAudioMix: false, scale: 0.5) }),
        ]
        for (name, expected, run) in cases {
            #expect(run() == expected, "\(name) did not disqualify with \(expected)")
        }
    }

    @Test("A full-frame crop is not a crop")
    func fullFrameCropIsStillEligible() {
        // `nil` and "the whole frame" render identically — §7 says so — so a
        // document that had a crop set and then reset must not lose the fast
        // path for a transform that does nothing.
        let full = CropRect(x: 0, y: 0, width: 1, height: 1)
        #expect(full.isFullFrame)
        #expect(PassthroughEligibility.isEligible(resolution: .source, maxSizeBytes: nil,
                                                  clicks: [], edl: edl(crop: full),
                                                  hasAudioMix: false))
    }

    @Test("Anything that produces an audio mix disqualifies — mute included")
    func anyAudioMixDisqualifies() {
        // The assumption this test exists to kill. An earlier version of the
        // predicate reasoned that only `gain` mattered, because "a muted track
        // is expressed by leaving it out of the composition". `CompositionBuilder`
        // does the opposite — it keeps the track and sets its volume to 0
        // through the mix — so passthrough skipped the mix and exported a muted
        // recording byte-identical to the unmuted one. Audible mute, silent bug.
        //
        // The predicate now asks the BUILT composition whether it has a mix,
        // which is the same question `CompositionBuilder.needsMix` answers, so
        // the two cannot drift apart again.
        #expect(PassthroughEligibility.disqualifier(
            resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl(),
            hasAudioMix: true) == .audioMix)
        #expect(PassthroughEligibility.isEligible(
            resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl(),
            hasAudioMix: false))
    }

    @Test("Cuts alone stay eligible — the measured case this exists for")
    func cutsDoNotDisqualify() {
        // Record, top-and-tail, ship. Measured on a real 4112x2580 capture with
        // a cut at 5.37s, deliberately off-keyframe: 1.112s re-encoding versus
        // 0.023s copying, decoded frames identical to within 0.1 mean luma.
        // AVFoundation resolves the mid-GOP splice itself.
        let trimmed = EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 5.37))],
                                       trackStates: [TrackState(track: "video")])
        #expect(PassthroughEligibility.isEligible(resolution: .source, maxSizeBytes: nil,
                                                  clicks: [], edl: trimmed,
                                                  hasAudioMix: false))
    }

    @Test("A new EDL field cannot silently inherit the fast path")
    func everyEDLFieldHasBeenConsidered() {
        // THE structural guard. Passthrough bypasses the video composition, so
        // it is only correct while every way of describing an edit has been
        // checked against it. Adding a field to `EditDecisionList` — a filter,
        // a rotation, a speed ramp — would otherwise leave this predicate
        // silently answering "eligible" for edits it has never heard of, and
        // the symptom is a fast export of the wrong picture.
        //
        // Compared against the type's REAL fields via Mirror rather than a
        // hand-kept list, so the check cannot rot the way the list it guards
        // could.
        let fields = Set(Mirror(reflecting: EditDecisionList()).children.compactMap(\.label))
        #expect(fields == PassthroughEligibility.consideredEDLFields, """
            EditDecisionList's fields have changed.
            in the type but not considered: \(fields.subtracting(PassthroughEligibility.consideredEDLFields))
            considered but no longer present: \(PassthroughEligibility.consideredEDLFields.subtracting(fields))
            Decide whether the new field changes a pixel. If it can, disqualify \
            passthrough for it in PassthroughEligibility.disqualifier; then add \
            it to consideredEDLFields either way.
            """)
    }
}
