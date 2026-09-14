// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The player's captions obey the mute, and never mix two voices.
///
/// `EditorTimelineState.audibleWords` documents the rule — "every surface
/// reads THIS rather than `transcript.words`, so the pane, the timeline lane
/// and anything added later cannot disagree about what is audible" — and
/// `subtitleCues` was the surface reading around it. Muting narration silenced
/// it and left its words sitting on the picture.
@MainActor
struct PreviewCaptionMuteTests {

    private func makeState(words: [TranscriptWord],
                           muting muted: [String]) async throws
        -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 4.0)

        var edl = EditDecisionList(cuts: [], trackStates: [
            TrackState(track: "video"),
            TrackState(track: "microphone", muted: muted.contains("microphone")),
            TrackState(track: "voiceover", muted: muted.contains("voiceover")),
        ])
        edl.showSubtitles = true
        try edl.write(to: bundle)

        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [])
        state.transcript = Transcript(words: words, locale: "en-US")
        return (state, bundle)
    }

    private let bothVoices = [
        TranscriptWord(text: "recorded", start: 1.0, duration: 0.4, confidence: 1),
        TranscriptWord(text: "narrated", start: 1.1, duration: 0.4,
                       confidence: 1, track: "voiceover"),
    ]

    @Test("Both voices are captioned when both are audible")
    func bothVoicesAreCaptioned() async throws {
        // The control. Without it the mute assertions below pass against a
        // `subtitleCues` that returns nothing at all.
        let (state, bundle) = try await makeState(words: bothVoices, muting: [])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let cues = state.subtitleCues
        #expect(Set(cues.map(\.track)) == ["microphone", "voiceover"])
        // And separated, rather than one cue reading "recorded narrated".
        #expect(cues.count == 2, "the two voices were merged into \(cues.map(\.text))")
    }

    @Test("Muting the voiceover removes its captions from the player")
    func mutedNarrationIsNotCaptioned() async throws {
        let (state, bundle) = try await makeState(words: bothVoices, muting: ["voiceover"])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.subtitleCues.map(\.text) == ["recorded"])
    }

    @Test("Muting the microphone removes ITS captions, not the narration's")
    func mutedMicrophoneIsNotCaptioned() async throws {
        // Both directions, because a filter keyed on the wrong track name
        // passes the voiceover case and fails this one.
        let (state, bundle) = try await makeState(words: bothVoices, muting: ["microphone"])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.subtitleCues.map(\.text) == ["narrated"])
    }

    @Test("The survivor goes back to the centre line")
    func theRemainingCaptionIsRecentred() async throws {
        // Placement is about sharing the frame. Once the other voice is muted
        // there is nothing to share with, so a caption still offset to one side
        // would be indented for a partner that is not there.
        let (state, bundle) = try await makeState(words: bothVoices, muting: ["voiceover"])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.subtitleCues.allSatisfy { $0.placement == .alone })
    }

    @Test("The pane marks its lanes only when there are two of them")
    func narrationIsAnnouncedOnlyWhenPresent() async throws {
        // The transcript pane draws a lane rule down each row in the track's
        // colour. On a recording with one voice that rule distinguishes
        // nothing and is just chrome, so it is conditioned on this.
        let (both, bundleA) = try await makeState(words: bothVoices, muting: [])
        defer { try? FileManager.default.removeItem(at: bundleA.url) }
        #expect(both.hasNarration)

        let micOnly = [TranscriptWord(text: "recorded", start: 1.0, duration: 0.4,
                                      confidence: 1)]
        let (one, bundleB) = try await makeState(words: micOnly, muting: [])
        defer { try? FileManager.default.removeItem(at: bundleB.url) }
        #expect(!one.hasNarration)
    }

    @Test("Muting the voiceover puts the pane back to its single-voice look")
    func mutedNarrationIsNotAnnounced() async throws {
        // Derived from what is AUDIBLE rather than from `trackStates`, so a
        // muted voiceover does not leave a lane rule on every row marking a
        // distinction that is no longer on screen.
        let (state, bundle) = try await makeState(words: bothVoices, muting: ["voiceover"])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(!state.hasNarration)
    }

    @Test("The pane's rows are single-voiced")
    func paneRowsAreSplitByVoice() async throws {
        // What the pane actually lays out. Asserting on `TranscriptParagraphs`
        // alone would leave the surface free to feed it a comingled list, which
        // is the shape of defect this project keeps finding.
        let (state, bundle) = try await makeState(words: bothVoices, muting: [])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let rows = TranscriptParagraphs.split(state.audibleWords)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { Set($0.words.map(\.track)).count == 1 })
        #expect(Set(rows.map(\.track)) == ["microphone", "voiceover"])
    }

    @Test("Captions still respect the subtitle toggle")
    func togglingSubtitlesOffStillWins() async throws {
        // The mute filter is an ADDITIONAL gate, not a replacement for the
        // existing one.
        let (state, bundle) = try await makeState(words: bothVoices, muting: [])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        state.edl.showSubtitles = false
        #expect(state.subtitleCues.isEmpty)
    }
}
