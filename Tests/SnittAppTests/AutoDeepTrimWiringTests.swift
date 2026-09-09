import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The editor's Auto-Trim command (D57).
///
/// `AutoDeepTrim`'s own tests prove the detection. These prove the editor asks
/// for it, turns the answer into ordinary undoable cuts, and does not propose
/// the same span twice.
@Suite(.serialized)
@MainActor
struct AutoDeepTrimWiringTests {
    private let duration = 20.0

    private func solid(_ white: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: white, green: white, blue: white, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return ctx.makeImage()!
    }

    /// A state whose signals show activity for the first two seconds and
    /// nothing for the remaining eighteen.
    ///
    /// The waveform and filmstrip are injected rather than decoded: what is
    /// under test is the command — detect, filter, cut, undo — not that the
    /// editor can load a waveform, which its own tests cover. Decoding a real
    /// twenty-second movie here would test AVFoundation instead.
    private func makeState(loaded: Bool = true) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: duration)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(),
                                                       scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])
        guard loaded else { return state }

        let rate = 10.0
        var peaks = [Float](repeating: 0.001, count: Int(duration * rate))
        for i in 0..<Int(2 * rate) { peaks[i] = 0.6 }
        state.waveforms = [WaveformSamples(track: "microphone", samplesPerSecond: rate, peaks: peaks)]
        // Moving for two seconds, then a still picture.
        let frameRate = 5.0
        var frames = [CGImage]()
        for i in 0..<Int(duration * frameRate) {
            frames.append(solid(i < Int(2 * frameRate) ? CGFloat(i % 2) : 0.5))
        }
        state.filmstrip = FilmstripFrames(samplesPerSecond: frameRate, frames: frames)
        return state
    }

    @Test("Trimming turns dead air into ordinary cuts")
    func trimProducesCuts() async throws {
        let state = try await makeState()
        #expect(state.edl.cuts.isEmpty)

        let outcome = state.autoDeepTrim(preset: .default)
        guard case .cut(let spans, let seconds) = outcome else {
            Issue.record("expected a cut, got \(outcome)"); return
        }
        #expect(spans >= 1)
        #expect(seconds > 10, "only \(seconds)s of an eighteen-second silence")
        #expect(state.edl.cuts.count == spans, "the spans were not added to the EDL")
    }

    @Test("An automatic trim is undoable like any other edit")
    func trimIsUndoable() async throws {
        // D57's own reasoning for wanting D56's reversible folds: an automatic
        // trim has to be inspectable and individually undoable, not a bulk edit
        // the user must accept whole.
        let state = try await makeState()
        let undo = UndoManager()
        state.undoManager = undo
        state.autoDeepTrim(preset: .default)
        #expect(!state.edl.cuts.isEmpty)

        undo.undo()
        #expect(state.edl.cuts.isEmpty, "an automatic trim could not be undone")
    }

    @Test("Running it twice does not stack a second fold on the same silence")
    func rerunFindsNothingNew() async throws {
        let state = try await makeState()
        let first = state.autoDeepTrim(preset: .default)
        guard case .cut = first else { Issue.record("first run cut nothing"); return }
        let cutsAfterFirst = state.edl.cuts.count

        let second = state.autoDeepTrim(preset: .default)
        #expect(second == .nothingToCut, "second run returned \(second)")
        #expect(state.edl.cuts.count == cutsAfterFirst,
                "re-running stacked cuts onto material that was already gone")
    }

    @Test("Before the signals load, it says so rather than cutting nothing silently")
    func notReadyIsDistinctFromNothingToCut() async throws {
        // These are different answers and must not look alike: one is a wait,
        // the other is an outcome.
        let state = try await makeState(loaded: false)
        #expect(state.autoDeepTrim(preset: .default) == .notReady)
        #expect(state.edl.cuts.isEmpty)
    }

    @Test("The caption distinguishes every outcome")
    func captionsAreDistinct() {
        let captions = [
            EditorContentView.trimCaption(.cut(spans: 1, seconds: 3.0)),
            EditorContentView.trimCaption(.cut(spans: 4, seconds: 12.25)),
            EditorContentView.trimCaption(.nothingToCut),
            EditorContentView.trimCaption(.notReady),
        ]
        #expect(Set(captions).count == 4, "two outcomes read the same: \(captions)")
        #expect(captions[0].contains("1 span") && !captions[0].contains("spans"),
                "singular: \(captions[0])")
        #expect(captions[1].contains("4 spans"), "plural: \(captions[1])")
    }
}
