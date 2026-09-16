// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import AVFoundation
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Narration recorded in the editor (D93), everywhere it touches the document.
///
/// The placement arithmetic is `OverdubPlacementTests`. This is the wiring
/// around it: the recorder's refusals, the document field surviving a round
/// trip, and the two guards that stop a voiceover shipping silently absent
/// from an export.
@Suite(.serialized)
@MainActor
struct VoiceoverTests {
    init() { _ = NSApplication.shared }

    // MARK: - The recorder

    @Test("A refused microphone stops the take before anything is written")
    func refusedMicrophoneWritesNothing() throws {
        // The grant is checked BEFORE the file is created. Otherwise a refusal
        // leaves an empty voiceover.m4a in the bundle, which the next read
        // would find and treat as narration.
        let recorder = VoiceoverRecorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vo-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let failure = recorder.start(writingTo: url, fromOutputSeconds: 0,
                                     ensureMicrophone: { false })
        #expect(failure == .microphoneDenied)
        #expect(recorder.isRecording == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Stopping when nothing is recording is a no-op, not a zero-length take")
    func stoppingIdleReturnsNil() {
        // Nil rather than 0: a caller distinguishes "nothing to record" from
        // "a take of no length", and 0 would write an empty Overdub.
        #expect(VoiceoverRecorder().stop() == nil)
    }

    @Test("The start anchor is where the playhead WAS, not where it ended up")
    func anchorIsCapturedAtStart() throws {
        // The playhead moves while narration is spoken — `startVoiceover`
        // starts playback deliberately, because narrating over a still frame
        // anchors everything to one instant. So the anchor has to be taken
        // once, at the start.
        let recorder = VoiceoverRecorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vo-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = recorder.start(writingTo: url, fromOutputSeconds: 12.5,
                           ensureMicrophone: { false })
        // Refused, so nothing was anchored — the failure path must not leave a
        // stale anchor behind for the next take to inherit.
        #expect(recorder.startedAtOutput == 0)
    }

    // MARK: - The document

    @Test("A take survives a write and a read")
    func takeRoundTrips() throws {
        var edl = EditDecisionList()
        edl.overdubs = [Overdub(
            filename: "overdub-1.m4a", durationSeconds: 6.25,
            segments: [OverdubSegment(takeStart: 0, sourceStart: 30, durationSeconds: 6.25)])]

        let data = try JSONEncoder().encode(edl)
        let decoded = try JSONDecoder().decode(EditDecisionList.self, from: data)
        #expect(decoded.overdubs == edl.overdubs)
    }

    // MARK: - The two guards

    @Test("A take disqualifies passthrough, so it cannot be silently dropped")
    func takeForcesAReEncode() {
        // Passthrough copies ALREADY-ENCODED samples. A take is not in
        // `capture.mov`, so there are none to copy for the stretch it covers —
        // an eligible export would produce the picture and the ORIGINAL
        // microphone, which is exactly the audio the take was recorded to
        // replace. The failure is silent: the file plays, and says the thing
        // you re-recorded to stop it saying.
        var edl = EditDecisionList()
        #expect(PassthroughEligibility.disqualifier(
            resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl,
            hasAudioMix: false) == nil, "the fixture is not otherwise eligible")

        edl.overdubs = [Overdub(filename: "overdub-1.m4a", durationSeconds: 3,
                                segments: [OverdubSegment(takeStart: 0, sourceStart: 0,
                                                          durationSeconds: 3)])]
        #expect(PassthroughEligibility.disqualifier(
            resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl,
            hasAudioMix: false) == .overdub)
    }

    @Test("A take lands on the microphone, so the mix covers only captured tracks")
    func takesAddNoTrackToTheVocabulary() {
        // The mix resolves composition audio track `i` to `canonical[i]`. Under
        // D93 a voiceover occupied index 2 and the vocabulary needed a third
        // name for it; a take goes on the microphone, so the composition has
        // exactly the capture's tracks again and the two lists agree.
        //
        // `canonical` still has the third slot, reserved for the synthesised
        // voice (D101). What this pins is that a TAKE does not use it — an
        // implementation that quietly went back to appending a track would
        // still pass every assertion about the take being audible.
        #expect(AudioTrackOrder.captured == ["systemAudio", "microphone"])
        #expect(AudioTrackOrder.canonical[AudioTrackOrder.captured.count] == "voiceover")
    }

    @Test("The failure messages say what to do, not what went wrong")
    func failureMessagesAreActionable() {
        let denied = AppDelegate.voiceoverFailureMessage(.microphoneDenied)
        #expect(denied.contains("System Settings"),
                "a refused microphone message that does not name the remedy: \(denied)")
        #expect(AppDelegate.voiceoverFailureMessage(.alreadyRecording)
            .contains("already"))
        #expect(AppDelegate.voiceoverFailureMessage(.failed("disk is full"))
            .contains("disk is full"), "the underlying reason was swallowed")
    }
}

/// That an edit does not send the playhead home (D102).
///
/// The failure this guards is not the visible jump. An over-dub reads the
/// playhead to decide where it was spoken, so a playhead reset to 0 by the
/// PREVIOUS take's save anchors the next take at the start of the recording —
/// and the words it was meant to replace survive, being nowhere near what it
/// claims to cover. Four takes in a real document, every one anchored at
/// source 0.
@MainActor
struct PlayheadSurvivesEditsTests {

    @Test("Rebuilding after an edit leaves the playhead where it was")
    func playheadSurvivesARebuild() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 10.0)
        try EditDecisionList.fullRange().write(to: bundle)

        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: .fullRange(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        await controller.seek(toSeconds: 6.0)
        #expect(abs(controller.player.currentTime().seconds - 6.0) < 0.2,
                "the fixture did not seek, so this proves nothing")

        // An edit that removes no footage — exactly what saving a take does.
        var edl = EditDecisionList.fullRange()
        edl.showMarkers = true
        try await controller.apply(edl: edl, events: [])

        let after = controller.player.currentTime().seconds
        #expect(abs(after - 6.0) < 0.3,
                "the playhead moved to \(after) — an edit sent it home")
    }
}
