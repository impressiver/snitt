// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
    private func makeState(loaded: Bool = true,
                           silent: Bool = false,
                           events: [LoggedEvent] = []) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: duration)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(),
                                                       scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: events)
        guard loaded else { return state }

        if silent {
            // A recording with no audio track: sampling FINISHED and found
            // nothing, which is different from not having sampled yet.
            state.waveforms = []
        } else {
            let rate = 10.0
            var peaks = [Float](repeating: 0.001, count: Int(duration * rate))
            for i in 0..<Int(2 * rate) { peaks[i] = 0.6 }
            state.waveforms = [WaveformSamples(track: "microphone",
                                               samplesPerSecond: rate, peaks: peaks)]
        }
        state.waveformsLoaded = true
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

    @Test("Every automatic fold is named for what was happening")
    func foldsAreLabelled() async throws {
        // The whole point of the feature: a trim leaves holes, and a hole says
        // nothing about what used to be in it. `Cut` carried only `id` and
        // `range` until now, so an automatic trim produced anonymous gaps a
        // viewer had to expand one at a time.
        // A marker just before the dead stretch, which begins at 2s.
        let state = try await makeState(events: [
            LoggedEvent(timeSeconds: 1.5, kind: .marker, label: "running the build"),
        ])
        let outcome = state.autoDeepTrim(preset: .default)
        guard case .cut = outcome else { Issue.record("cut nothing: \(outcome)"); return }

        let cut = try #require(state.edl.cuts.first)
        let label = try #require(cut.label, "the fold has no label")
        #expect(label.hasPrefix("running the build — "),
                "named \(label), not for the marker that preceded it")
        // And it says how long, because that is the other thing a hole hides.
        #expect(label.contains("s") || label.contains("m"))
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

    @Test("A silent recording is trimmable, not permanently 'not ready'")
    func silentRecordingIsTrimmable() async throws {
        // The defect a real 200-second screen recording with zero audio tracks
        // exposed: an empty waveform array was read as "still loading", so the
        // command reported not-ready forever on exactly the recordings most
        // likely to contain dead air.
        let state = try await makeState(silent: true)
        let outcome = state.autoDeepTrim(preset: .default)
        guard case .cut(let spans, _) = outcome else {
            Issue.record("a silent recording gave \(outcome)"); return
        }
        #expect(spans >= 1)
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

/// Which terms a transcription biases toward (D81).
@Suite(.serialized)
@MainActor
struct TranscriberVocabularyTests {

    private func bundle(vocabulary: [String]?) throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "vocab-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try RecordingMetadata(createdAt: Date(), initiator: .agent,
                              vocabulary: vocabulary).write(to: bundle)
        return bundle
    }

    @Test("Re-transcribing uses the hints the recording was made with")
    func storedVocabularyIsUsed() throws {
        // The case that matters: a re-transcription usually happens BECAUSE
        // the first one got the names wrong, so dropping the hints then is
        // dropping them exactly when they are needed.
        let source = try bundle(vocabulary: ["KeptRanges", "SCStream"])
        defer { try? FileManager.default.removeItem(at: source.url) }
        #expect(Transcriber.resolveVocabulary(override: nil, bundle: source)
                == ["KeptRanges", "SCStream"])
    }

    @Test("An explicit list overrides what the recording stored")
    func overrideWins() throws {
        let source = try bundle(vocabulary: ["Stored"])
        defer { try? FileManager.default.removeItem(at: source.url) }
        #expect(Transcriber.resolveVocabulary(override: ["Better"], bundle: source)
                == ["Better"])
    }

    @Test("A recording with no vocabulary transcribes with none, not a crash")
    func absentVocabularyIsEmpty() throws {
        let source = try bundle(vocabulary: nil)
        defer { try? FileManager.default.removeItem(at: source.url) }
        #expect(Transcriber.resolveVocabulary(override: nil, bundle: source).isEmpty)
    }

    @Test("Stored terms are cleaned on the way out, not trusted raw")
    func storedTermsArePrepared() throws {
        // A bundle can be hand-edited, and metadata written by an older build
        // was never passed through `Vocabulary.prepare`.
        let source = try bundle(vocabulary: ["  Padded  ", "", "Padded"])
        defer { try? FileManager.default.removeItem(at: source.url) }
        #expect(Transcriber.resolveVocabulary(override: nil, bundle: source) == ["Padded"])
    }
}
