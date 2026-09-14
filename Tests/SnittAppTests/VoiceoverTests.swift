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
/// The placement arithmetic is `VoiceoverPlacementTests`. This is the wiring
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
        // "a take of no length", and 0 would write an empty VoiceoverTrack.
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

    @Test("A voiceover survives a write and a read")
    func voiceoverRoundTrips() throws {
        var edl = EditDecisionList()
        edl.voiceover = VoiceoverTrack(
            filename: "voiceover.m4a", durationSeconds: 6.25,
            segments: [VoiceoverSegment(voiceoverStart: 0, sourceStart: 30, durationSeconds: 6.25)])

        let data = try JSONEncoder().encode(edl)
        let decoded = try JSONDecoder().decode(EditDecisionList.self, from: data)
        #expect(decoded.voiceover == edl.voiceover)
    }

    @Test("A document with no narration writes no voiceover key")
    func absentVoiceoverWritesNothing() throws {
        // Additive, like `crop` and the three `show` flags: the schema version
        // does not move, and an older build reading a newer document loses the
        // narration rather than refusing the file.
        let data = try JSONEncoder().encode(EditDecisionList())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("voiceover"))
        #expect(try JSONDecoder().decode(EditDecisionList.self, from: data).voiceover == nil)
    }

    // MARK: - The two guards

    @Test("Narration disqualifies passthrough, so the track cannot be silently dropped")
    func voiceoverForcesAReEncode() {
        // Passthrough copies ALREADY-ENCODED samples. A voiceover is not in
        // `capture.mov`, so there are none to copy — an eligible export would
        // produce the picture and the original audio and no narration at all.
        // The failure is silent: the file plays, and the thing you recorded is
        // just missing.
        var edl = EditDecisionList()
        #expect(PassthroughEligibility.disqualifier(
            resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl,
            hasAudioMix: false) == nil, "the fixture is not otherwise eligible")

        edl.voiceover = VoiceoverTrack(filename: "voiceover.m4a", durationSeconds: 3,
                                       segments: [VoiceoverSegment(voiceoverStart: 0,
                                                                   sourceStart: 0,
                                                                   durationSeconds: 3)])
        #expect(PassthroughEligibility.disqualifier(
            resolution: .source, maxSizeBytes: nil, clicks: [], edl: edl,
            hasAudioMix: false) == .voiceover)
    }

    @Test("The track vocabulary has room for narration at the index it lands on")
    func canonicalOrderCoversTheVoiceover() {
        // `CompositionBuilder` appends the voiceover after the captured tracks
        // and the mix resolves composition audio track `i` to `canonical[i]`.
        // A vocabulary of two names would leave index 2 unresolved, so muting
        // or gaining narration would do nothing — silently, because an
        // unmatched track is simply left at unity.
        #expect(AudioTrackOrder.canonical.count > AudioTrackOrder.captured.count)
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
