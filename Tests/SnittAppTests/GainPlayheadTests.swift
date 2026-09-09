// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Mute and gain re-apply the audio mix in place; they do not rebuild.
///
/// The reported problem: dragging a gain slider sent the playhead back to the
/// start. `applyAndSave` went through `PreviewController.apply`, which calls
/// `replaceCurrentItem` — correct for a cut, which moves material, and pure
/// loss for gain, which changes nothing but a volume.
///
/// Every assertion is on the PLAYER — where the playhead is, and what mix the
/// player is actually using — rather than on which method ran. `edl` holding
/// the right number proves nothing about what you hear or where you are.
@Suite(.serialized)
@MainActor
struct GainPlayheadTests {

    private func makeState(seconds: Double = 6.0)
    async throws -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        // Two audio tracks, so there is a real mix to build and a real
        // by-name match to get wrong.
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds,
                                      audioTrackCount: 2)
        try EditDecisionList.fullRange().write(to: bundle)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: .fullRange(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        return (EditorTimelineState(controller: controller, edl: .fullRange(), events: []),
                bundle)
    }

    private func playhead(_ state: EditorTimelineState) -> Double {
        state.controller.player.currentTime().seconds
    }

    /// The mix the PLAYER is using, not the one the builder would produce.
    private func liveMix(_ state: EditorTimelineState) -> AVAudioMix? {
        state.controller.player.currentItem?.audioMix
    }

    private func volume(of parameters: AVAudioMixInputParameters) -> Float? {
        var start: Float = -1
        let ok = parameters.getVolumeRamp(for: .zero, startVolume: &start,
                                          endVolume: nil, timeRange: nil)
        return ok ? start : nil
    }

    /// The mix parameters governing one canonical track, matched BY TRACK ID.
    ///
    /// Not by position in `inputParameters`: matching audio tracks by index is
    /// the exact bug `CompositionBuilder.audioMix` documents at length (it
    /// gave systemAudio the state named "video"), and a test that repeats it
    /// would agree with a broken implementation.
    private func parameters(for name: String, in state: EditorTimelineState)
    async throws -> AVAudioMixInputParameters? {
        guard let mix = liveMix(state), let asset = state.controller.player.currentItem?.asset
        else { return nil }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let position = AudioTrackOrder.canonical.firstIndex(of: name),
              position < tracks.count else { return nil }
        let trackID = tracks[position].trackID
        return mix.inputParameters.first { $0.trackID == trackID }
    }

    // MARK: - The reported bug

    @Test("Adjusting gain leaves the playhead where it was")
    func gainKeepsThePlayhead() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        await state.controller.seek(toSeconds: 4.0)
        #expect(playhead(state) > 3.5, "the fixture never moved off zero")

        state.setGain(track: "microphone", gain: 2.0)
        await state.waitForPendingSave()

        #expect(abs(playhead(state) - 4.0) < 0.1, "playhead moved to \(playhead(state))")
    }

    @Test("Muting leaves the playhead where it was")
    func muteKeepsThePlayhead() async throws {
        // Same code path, same complaint if it regresses — and mute is the
        // control somebody reaches for MID-passage, to check whether the
        // narration is carrying the demo.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        await state.controller.seek(toSeconds: 4.0)

        state.setMuted(track: "systemAudio", muted: true)
        await state.waitForPendingSave()

        #expect(abs(playhead(state) - 4.0) < 0.1, "playhead moved to \(playhead(state))")
    }

    @Test("A cut still rebuilds, because it actually moves material")
    func cutStillRebuilds() async throws {
        // The guard against over-applying the fix. If `rebuild:` defaulted
        // wrong, or every edit took the mix-only path, a cut would leave the
        // composition at its old length — the timeline would draw the trim
        // while the player kept playing the removed footage.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let before = state.controller.durationSeconds

        state.selection = Selection(range: TimeRange(start: 1.0, end: 3.0))
        state.cutSelection()
        await state.waitForPendingSave()

        #expect(state.controller.durationSeconds < before - 1.5,
                "duration went \(before) -> \(state.controller.durationSeconds)")
    }

    // MARK: - The mix still reaches the player

    @Test("Gain reaches the mix the player is using")
    func gainReachesThePlayer() async throws {
        // Keeping the playhead is worthless if the sound stops changing.
        // This is the half a "did not seek to zero" test cannot see.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setGain(track: "microphone", gain: 0.25)
        await state.waitForPendingSave()

        let mic = try #require(await parameters(for: "microphone", in: state),
                               "no mix reached the player")
        #expect(volume(of: mic) == 0.25)
    }

    @Test("Gain lands on the track it names, not on its neighbour")
    func gainLandsOnTheNamedTrack() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setGain(track: "microphone", gain: 0.25)
        await state.waitForPendingSave()

        let system = try #require(await parameters(for: "systemAudio", in: state))
        #expect(volume(of: system) == 1.0, "system audio was turned down too")
    }

    @Test("Muting silences the track in the player's mix")
    func muteSilencesInThePlayer() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setMuted(track: "microphone", muted: true)
        await state.waitForPendingSave()

        let mic = try #require(await parameters(for: "microphone", in: state))
        #expect(volume(of: mic) == 0.0)
    }

    @Test("Returning to unity CLEARS the mix rather than leaving the old one")
    func returningToUnityClearsTheMix() async throws {
        // The trap in applying a mix in place. `audioMix(for:edl:)` returns
        // nil when there is nothing to express, and an implementation that
        // treats nil as "nothing to do" leaves the previous mix installed —
        // so un-muting a track would leave it silent forever, with an EDL
        // that says it is fine and a slider that says 1.0.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setMuted(track: "microphone", muted: true)
        await state.waitForPendingSave()
        #expect(liveMix(state) != nil, "the fixture never installed a mix")

        state.setMuted(track: "microphone", muted: false)
        await state.waitForPendingSave()

        #expect(liveMix(state) == nil, "a stale mix is still applied")
    }

    @Test("Un-muting after a cut restores full volume, mix or no mix")
    func unmutingAfterACutIsAudible() async throws {
        // The end-to-end version of the test above, through the two paths
        // interleaved: a rebuild installs a fresh mix, and the mix-only path
        // must be able to clear THAT one too.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setMuted(track: "microphone", muted: true)
        await state.waitForPendingSave()
        state.selection = Selection(range: TimeRange(start: 1.0, end: 2.0))
        state.cutSelection()
        await state.waitForPendingSave()

        state.setMuted(track: "microphone", muted: false)
        await state.waitForPendingSave()

        if let mic = try await parameters(for: "microphone", in: state) {
            #expect(volume(of: mic) == 1.0, "still attenuated after un-muting")
        } else {
            #expect(liveMix(state) == nil, "a mix exists but names no microphone")
        }
    }

    @Test("Gain still reaches edit.json on the mix-only path")
    func gainStillPersists() async throws {
        // The mix-only path skips the rebuild, and `persist` is called from
        // the same place — but skipping it too would be an easy edit, and the
        // symptom (gain forgotten on reopen) is invisible in the session that
        // caused it.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setGain(track: "microphone", gain: 1.75)
        await state.waitForPendingSave()

        let onDisk = try EditDecisionList.read(from: bundle)
        let mic = try #require(onDisk.trackStates.first { $0.track == "microphone" })
        #expect(abs(mic.gain - 1.75) < 1e-9)
    }
}
