import Testing
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Per-track gain and mute from the editor.
///
/// `TrackState.gain` has existed and been applied by the export mix since M3
/// with no way to set it — the same shape crop had, a model feature with no
/// surface. These assert the surface writes to the model that the export
/// already reads.
@MainActor
struct AudioGainTests {
    private func makeState() async throws -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0)
        try EditDecisionList.fullRange().write(to: bundle)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: .fullRange(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        return (EditorTimelineState(controller: controller, edl: .fullRange(), events: []), bundle)
    }

    @Test("Gain reaches edit.json, where the export mix reads it")
    func gainPersists() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setGain(track: "microphone", gain: 2.5)
        await state.waitForPendingSave()

        let onDisk = try EditDecisionList.read(from: bundle)
        let mic = try #require(onDisk.trackStates.first { $0.track == "microphone" })
        #expect(abs(mic.gain - 2.5) < 1e-9, "gain never reached edit.json")
    }

    @Test("Gain is clamped, so a slider cannot invert phase or blow the ceiling")
    func gainIsClamped() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        // Negative gain inverts phase, which is never what a drag meant.
        state.setGain(track: "microphone", gain: -3)
        await state.waitForPendingSave()
        #expect(state.edl.trackStates.first { $0.track == "microphone" }?.gain == 0)

        state.setGain(track: "microphone", gain: 99)
        await state.waitForPendingSave()
        #expect(state.edl.trackStates.first { $0.track == "microphone" }?.gain == 4)
    }

    @Test("Muting one track leaves the other alone")
    func muteIsPerTrack() async throws {
        // The bug this guards is index-based track matching, which this project
        // has already shipped once: it gave audio track 0 the state named
        // "video" and made muting system audio do nothing.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setMuted(track: "microphone", muted: true)
        await state.waitForPendingSave()

        let states = state.edl.trackStates
        #expect(states.first { $0.track == "microphone" }?.muted == true)
        #expect(states.first { $0.track == "systemAudio" }?.muted == false)
        #expect(states.first { $0.track == "video" }?.muted == false)
    }

    @Test("Gain changes undo")
    func gainUndoes() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.setGain(track: "microphone", gain: 3)
        await state.waitForPendingSave()
        undoManager.undo()
        await state.waitForPendingSave()

        #expect(state.edl.trackStates.first { $0.track == "microphone" }?.gain == 1.0)
    }

    @Test("Setting the value it already has is not an edit")
    func noOpDoesNotPushUndo() async throws {
        // A slider emits a continuous stream while dragging. Registering an
        // undo step per emission would make one drag take fifty ⌘Z presses to
        // reverse.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.setGain(track: "microphone", gain: 1.0)   // already 1.0
        #expect(undoManager.canUndo == false)
    }

    @Test("Only tracks the recording has get controls")
    func audioTracksAreDerived() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.audioTracks.map(\.track) == ["microphone", "systemAudio"])
        #expect(!state.audioTracks.contains { $0.track == "video" },
                "video is not an audio track and must not get a gain slider")
    }
}
