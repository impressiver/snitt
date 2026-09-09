import AVFoundation
import AppKit
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The editor's transport: rewind, and what a scrub does to playback.
///
/// Both assertions are on the PLAYER — where the playhead actually ended up
/// and whether the picture is still moving — rather than on "pause() was
/// called". A test that counted calls would pass against a `rewind()` routed
/// through `onScrub`, which is precisely the implementation these rule out.
@Suite(.serialized)
@MainActor
struct EditorTransportTests {

    private func makeState(seconds: Double = 6.0,
                           edl: EditDecisionList = EditDecisionList())
    async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        try await controller.apply(edl: edl, events: [])
        return EditorTimelineState(controller: controller, edl: edl, events: [])
    }

    private func currentSeconds(_ state: EditorTimelineState) -> Double {
        state.controller.player.currentTime().seconds
    }

    @Test("Rewind puts the playhead back at the start")
    func rewindReturnsToTheStart() async throws {
        let state = try await makeState()
        await state.controller.seek(toSeconds: 4.0)
        #expect(currentSeconds(state) > 3.0, "the fixture never moved off zero")

        state.rewind()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(currentSeconds(state) < 0.05, "landed at \(currentSeconds(state))")
    }

    @Test("Rewind works when the recording starts with a cut")
    func rewindWorksWithACutAtTheStart() async throws {
        // Zero in OUTPUT time is always the start of the edit. Resolving a
        // rewind through `keptRanges` as if it were a SOURCE time would land
        // it at the first kept edge — the same place here, but the mapping is
        // an extra way to be wrong for no benefit, and this pins the case
        // that would expose it.
        let state = try await makeState(
            edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 2))]))
        await state.controller.seek(toSeconds: 3.0)

        state.rewind()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(currentSeconds(state) < 0.05, "landed at \(currentSeconds(state))")
    }

    @Test("Scrubbing the timeline stops playback")
    func scrubbingStopsPlayback() async throws {
        // The reported problem: the picture kept moving after a click, so the
        // playhead walked away from where it had just been put and the click
        // read as ignored.
        let state = try await makeState()
        state.controller.play()
        #expect(state.isPlaying, "the fixture never started playing")

        state.onScrub(2.0)

        #expect(state.isPlaying == false)
    }

    @Test("Rewind does NOT stop playback")
    func rewindKeepsPlaying() async throws {
        // This is the assertion that rules out `rewind() { onScrub(0) }` —
        // the obvious implementation, and one that reuses the code path that
        // now pauses. A rewind pressed while watching is a replay, not a stop.
        let state = try await makeState()
        state.controller.play()
        #expect(state.isPlaying, "the fixture never started playing")

        state.rewind()

        #expect(state.isPlaying, "rewind paused playback")
    }

    @Test("A chapter or transcript click stops playback too")
    func seekingFromAPaneStopsPlayback() async throws {
        // `seek(toOutput:)` and `seek(toWord:)` both route through `onScrub`
        // on purpose — same act, different target. Pausing only on the
        // timeline's own path would leave the panes behaving differently from
        // the lane for no reason a user could predict.
        let state = try await makeState()
        state.controller.play()
        #expect(state.isPlaying)

        state.seek(toOutput: 2.0)

        #expect(state.isPlaying == false)
    }
}
