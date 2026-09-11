// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

#if DEBUG
import AppKit
import SnittDocument
import SnittExport

/// Sample data for the `#Preview` blocks at the foot of each interface file.
///
/// **Why this exists.** Three times in one week a change to this app was
/// correct in its model, covered by tests, and invisible on screen — the
/// filmstrip that never shrank because the renderer read a different constant,
/// the gain control that was rebuilt without its slider, the fold selection
/// the view was never told about. Every one of them was caught by a person
/// looking at the app, days later, and none of them by arithmetic. A preview
/// is the cheapest way to look.
///
/// **One fixture set, not one per preview.** The previews are a visual
/// regression surface, and that only works if they show comparable things:
/// the same recording, the same two audio tracks, the same cuts, so a change
/// to lane heights shows up as the same recording drawn differently rather
/// than as two unrelated pictures.
///
/// `#if DEBUG` because this is sample data in a shipping module. Note that
/// `Scripts/make-app.sh` builds `-c debug`, so it IS present in the app you
/// run locally; the guard keeps it out of a release build, not out of that
/// one.
enum PreviewFixtures {

    /// A plausible short screen recording: long enough that lanes have to make
    /// decisions, short enough to read at a glance.
    static let duration = 42.0

    /// Two cuts, deliberately unequal — a long one and a brief one — because
    /// the short one is where fold drawing degenerates (a sub-pixel band at
    /// low zoom) and a fixture with two similar cuts never shows that.
    static let cuts: [Cut] = [
        Cut(range: TimeRange(start: 8, end: 13.5), label: "false start"),
        Cut(range: TimeRange(start: 27, end: 27.4), label: "cough"),
    ]

    static let markers: [JumpPoint] = [
        JumpPoint(timeSeconds: 2.5, label: "Intro"),
        JumpPoint(timeSeconds: 15, label: "The bug"),
        JumpPoint(timeSeconds: 24, label: "Fix"),
        JumpPoint(timeSeconds: 36, label: "Wrap up"),
    ]

    static let trackStates: [TrackState] = [
        TrackState(track: "microphone", muted: false, gain: 1.4),
        TrackState(track: "systemAudio", muted: true, gain: 0.6),
    ]

    static var audioTracks: [String] { trackStates.map(\.track) }

    /// Peaks with structure rather than noise: speech-like bursts on the
    /// microphone and a quieter, steadier system track. A flat or purely
    /// random waveform hides exactly the thing the lane is for.
    static let waveforms: [WaveformSamples] = [
        WaveformSamples(track: "microphone", samplesPerSecond: 20,
                        peaks: peaks(count: Int(duration * 20), seed: 7,
                                     floor: 0.05, ceiling: 1.05)),
        WaveformSamples(track: "systemAudio", samplesPerSecond: 20,
                        peaks: peaks(count: Int(duration * 20), seed: 31,
                                     floor: 0.02, ceiling: 0.45)),
    ]

    static let phrases: [TranscriptPhrase] = TranscriptPhrases.phrases(from: words)

    static let words: [TranscriptWord] = {
        let script = [
            "So", "here", "is", "the", "thing", "I", "kept", "getting", "wrong.",
            "The", "model", "was", "right", "every", "time.", "It", "just",
            "never", "reached", "the", "screen.",
        ]
        var out: [TranscriptWord] = []
        var t = 1.0
        for word in script {
            // A pause after each sentence, so phrase grouping actually groups.
            let duration = 0.28 + Double(word.count) * 0.03
            out.append(TranscriptWord(text: word, start: t, duration: duration,
                                      confidence: word == "wrong." ? 0.41 : 0.93))
            t += duration + (word.hasSuffix(".") ? 0.75 : 0.06)
        }
        return out
    }()

    /// Flat colour thumbnails cycling through a hue ramp. Not screenshots: the
    /// filmstrip's job on this timeline is to show WHERE you are, and a ramp
    /// makes a lane that repeated one frame — or drew none — obvious at a
    /// glance, which a strip of real screen captures does not.
    static let filmstrip = FilmstripFrames(
        samplesPerSecond: 1,
        frames: (0..<Int(duration)).compactMap { index in
            let hue = Double(index % 24) / 24.0
            return solidFrame(NSColor(hue: hue, saturation: 0.45,
                                      brightness: 0.75, alpha: 1))
        })

    static let exportOptions: [ExportOption] = [
        ExportOption(resolution: .source, width: 1512, height: 982,
                     maxBytes: 41_000_000, durationSeconds: 26.3),
        ExportOption(resolution: .hd720p, width: 1280, height: 831,
                     maxBytes: 24_000_000, durationSeconds: 26.3),
        ExportOption(resolution: .sd480p, width: 640, height: 416,
                     maxBytes: 6_400_000, durationSeconds: 26.3),
    ]

    /// A timeline view already populated, at `size`. The previews all go
    /// through this so they differ only in what they are demonstrating.
    @MainActor
    static func timeline(size: NSSize, selectedFold: UUID? = nil,
                         expanded: Set<UUID> = []) -> TimelineView {
        let view = TimelineView(frame: NSRect(origin: .zero, size: size))
        view.update(duration: duration, cuts: cuts, markerPoints: markers,
                    playhead: 19.5,
                    selection: nil,
                    expandedCutIDs: expanded,
                    selectedFoldID: selectedFold,
                    trackStates: trackStates,
                    waveforms: waveforms,
                    filmstrip: filmstrip)
        view.update(phrases: phrases)
        return view
    }

    // MARK: - Generators

    /// A deterministic pseudo-random ramp. Deterministic on purpose: a preview
    /// that redraws differently every time cannot be compared against the last
    /// time you looked at it, which is most of what a preview is for.
    /// `Math.random` equivalents are also unavailable to a `static let`.
    private static func peaks(count: Int, seed: UInt64,
                              floor: Float, ceiling: Float) -> [Float] {
        var state = seed
        var out: [Float] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(state >> 33) / Float(UInt32.max)
            // A slow envelope over the noise, so it reads as speech rather
            // than as static.
            let envelope = Float(abs(sin(Double(index) / 37.0)))
            out.append(floor + noise * envelope * (ceiling - floor))
        }
        return out
    }

    private static func solidFrame(_ color: NSColor) -> CGImage? {
        let width = 32, height = 20
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let rgb = color.usingColorSpace(.sRGB)
        else { return nil }
        context.setFillColor(red: rgb.redComponent, green: rgb.greenComponent,
                             blue: rgb.blueComponent, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
#endif
