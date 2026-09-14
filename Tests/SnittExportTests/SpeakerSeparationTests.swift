// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittExport
@testable import SnittBrand
@testable import SnittDocument

/// Two voices, two captions.
///
/// Reported as "video and voiceover transcriptions need to be separated — it
/// doesn't read coherently with them comingled", and it could not read
/// coherently: every word went into one list sorted by start time, so a cue
/// covering a moment when both voices were talking came out as their sentences
/// shuffled together. Narration is spoken OVER footage that already has speech
/// in it, which makes that the ordinary case rather than an edge one.
struct SpeakerSeparationTests {

    private let whole = [TimeRange(start: 0, end: 60)]

    private func recorded(_ items: [(String, Double, Double)]) -> [TranscriptWord] {
        items.map { TranscriptWord(text: $0.0, start: $0.1, duration: $0.2, confidence: 1) }
    }

    private func narrated(_ items: [(String, Double, Double)]) -> [TranscriptWord] {
        items.map { TranscriptWord(text: $0.0, start: $0.1, duration: $0.2,
                                   confidence: 1, track: "voiceover") }
    }

    /// The reported defect, at its simplest: two people talking at the same
    /// time, a third of a second apart.
    private var interleaved: [TranscriptWord] {
        recorded([("so", 1.0, 0.2), ("here", 1.4, 0.2), ("we", 1.8, 0.2)])
            + narrated([("and", 1.2, 0.2), ("that", 1.6, 0.2), ("fails", 2.0, 0.2)])
    }

    @Test("A cue never mixes words from two voices")
    func cuesAreSingleVoiced() throws {
        // THE BUG. Before the split this produced one cue reading
        // "so and here that we fails" — every word present, in time order, and
        // meaning nothing.
        let cues = SubtitleCues.cues(words: interleaved, keptRanges: whole)
        #expect(cues.count == 2, "expected one cue per voice, got \(cues.map(\.text))")
        #expect(Set(cues.map(\.text)) == ["so here we", "and that fails"])
    }

    @Test("Each cue is labelled with the voice it came from")
    func cuesCarryTheirTrack() throws {
        // Without this the renderers cannot colour them, and "which of these
        // is the narration" becomes a guess from position.
        let cues = SubtitleCues.cues(words: interleaved, keptRanges: whole)
        let byTrack = Dictionary(grouping: cues, by: \.track).mapValues { $0.map(\.text) }
        #expect(byTrack["microphone"] == ["so here we"])
        #expect(byTrack["voiceover"] == ["and that fails"])
    }

    @Test("Overlapping cues are offset off the centre line, one above the other")
    func overlapBecomesADialoguePair() throws {
        let cues = SubtitleCues.cues(words: interleaved, keptRanges: whole)
        let mic = try #require(cues.first { $0.track == "microphone" })
        let voice = try #require(cues.first { $0.track == "voiceover" })

        #expect(mic.placement == .recorded)
        #expect(voice.placement == .narration)
        // Different lines, so they cannot draw on top of each other — the one
        // failure mode that makes BOTH captions unreadable rather than one.
        #expect(mic.row != voice.row)
        // Recorded speech stays on the bottom line, where a caption has always
        // been: adding narration must not move the caption a viewer is already
        // reading.
        #expect(mic.row == 0)
        // And they are offset from each other, which is what says "two
        // speakers" to somebody who has never used this app.
        //
        // The ACTUAL alignments, not merely that they differ: a mutation
        // survived the "they differ" form by centring the recorded line, which
        // is still different from a right-aligned one and yet is not an offset
        // pair at all. Half the design satisfied the whole assertion.
        #expect(OverlayLayout.captionAlignment(mic.placement) == .left)
        #expect(OverlayLayout.captionAlignment(voice.placement) == .right)
        #expect(OverlayLayout.captionAlignment(.alone) == .center)
    }

    @Test("A cue that shares the frame with nobody stays centred on the bottom line")
    func soloCuesAreUnmoved() throws {
        // The common case must not pay for the rare one. A recording with
        // narration only in the middle should have ordinary centred captions
        // everywhere else.
        let words = recorded([("alone", 1.0, 0.3)])
            + narrated([("later", 30.0, 0.3)])
        let cues = SubtitleCues.cues(words: words, keptRanges: whole)
        #expect(cues.count == 2)
        #expect(cues.allSatisfy { $0.placement == .alone },
                "a cue with nothing to share the frame with was offset anyway")
        #expect(cues.allSatisfy { $0.row == 0 })
    }

    @Test("Placement is decided per cue, so a caption never jumps sideways mid-sentence")
    func placementIsStableForTheWholeCue() throws {
        // Narration that begins a fraction before the recorded caption LEAVES
        // THE SCREEN. The speech ends at 1.6; the cue is held to 2.2 so it can
        // be read, and the narration lands inside that tail.
        //
        // Overlap is about what is DISPLAYED rather than about what was
        // spoken, because the problem being solved is two captions in the same
        // place — and the hold is the part of a cue's life that is not speech.
        // A first version of this put the narration at 2.4, past the hold, so
        // nothing overlapped and the test passed against an implementation
        // with no placement logic at all.
        //
        // If placement were decided per instant, the recorded caption would be
        // centred for most of its life and then hop left — which reads as a
        // rendering fault rather than as a second speaker arriving.
        let words = recorded([("a", 1.0, 0.2), ("b", 1.4, 0.2)])
            + narrated([("overlapping", 2.0, 0.3)])
        let cues = SubtitleCues.cues(words: words, keptRanges: whole)
        let mic = try #require(cues.first { $0.track == "microphone" })
        #expect(mic.end > 2.0 && mic.start < 2.0,
                "fixture no longer overlaps: cue runs \(mic.start)–\(mic.end)")
        #expect(mic.placement == .recorded,
                "the recorded cue overlaps narration and must be offset for its whole duration")
    }

    @Test("Two voices may be on screen at once — the lookup returns both")
    func lookupReturnsEverythingVisible() throws {
        // `cue(at:in:)` returned ONE, so all three renderers silently dropped
        // whichever it did not pick. The singular accessor is gone rather than
        // kept beside this one: it cannot express "two people are talking".
        let cues = SubtitleCues.cues(words: interleaved, keptRanges: whole)
        let visible = SubtitleCues.visible(at: 1.5, in: cues)
        #expect(visible.count == 2, "only \(visible.count) caption visible where two voices overlap")
        // Lower line first, so a renderer walking the list draws bottom-up.
        #expect(visible.map(\.row) == [0, 1])
    }

    @Test("Within one voice, cues still never overlap each other")
    func oneVoiceStillTrimsItsOwnOverlaps() {
        // The non-overlap rule was doing real work and must survive the split:
        // two captions from the SAME speaker share a line and would draw on
        // top of each other. Short utterances, each held for
        // `minimumCueSeconds`, are what used to collide.
        let words = recorded([("yes", 0.0, 0.2)]) + recorded([("no", 0.6, 0.2)])
        let cues = SubtitleCues.cues(words: words, keptRanges: whole)
        for (a, b) in zip(cues, cues.dropFirst()) {
            #expect(a.end <= b.start + 1e-9,
                    "'\(a.text)' is still on screen when '\(b.text)' starts")
        }
    }

    @Test("A recording with no narration is unchanged")
    func noNarrationIsTheOldBehaviour() throws {
        // The split must not alter the output for the documents that have only
        // ever had one voice, which is most of them.
        let words = recorded([("one", 0.0, 0.3), ("two", 0.4, 0.3)])
        let cues = SubtitleCues.cues(words: words, keptRanges: whole)
        let cue = try #require(cues.first)
        #expect(cue.text == "one two")
        #expect(cue.placement == .alone)
        #expect(cue.track == "microphone")
    }

    @Test("System audio counts as the recording's own voice, not as a third speaker")
    func systemAudioJoinsTheRecordedStream() throws {
        // The split is narration-versus-everything-else rather than one stream
        // per track name. If system audio is ever transcribed it is a sound the
        // recording captured, and a third caption line would be a design
        // nobody has asked for.
        let words = [TranscriptWord(text: "ding", start: 1.0, duration: 0.3,
                                    confidence: 1, track: "systemAudio")]
            + recorded([("said", 1.2, 0.3)])
        let cues = SubtitleCues.cues(words: words, keptRanges: whole)
        #expect(cues.count == 1, "system audio was given its own line: \(cues.map(\.text))")
        #expect(cues.allSatisfy { $0.row == 0 })
    }

    @Test("Narration is drawn in its own colour, and the recorded voice stays white")
    func narrationIsColouredLikeItsWords() {
        // White for the principal voice and cyan for the second is how
        // subtitling has distinguished speakers since teletext, and it happens
        // to be the teal this app already uses for narration everywhere else.
        #expect(SnittPalette.caption(for: "voiceover") == SnittPalette.voiceover)
        // NOT `SnittPalette.track`, whose default is amber: a caption sits on
        // video pixels nobody chose, and white with a shadow is the only base
        // that survives a white IDE and a dark terminal alike.
        #expect(SnittPalette.caption(for: "microphone") == .white)
        #expect(SnittPalette.caption(for: "systemAudio") == .white)
        #expect(SnittPalette.caption(for: "microphone") != SnittPalette.track("microphone"))
    }

    @Test("The upper line clears the lower one whatever it says")
    func rowsCannotCollide() {
        // The row step is a fixed two-line allowance rather than the measured
        // height of the caption below, because three renderers compute it and
        // a content-dependent height is one they will eventually disagree
        // about. What it must guarantee is this.
        let height = 1080.0
        let font = OverlayLayout.captionFontSize(pictureHeight: height)
        let step = OverlayLayout.captionRowHeight(fontSize: font)
        let tallestCaption = Double(SubtitleCues.maximumLines) * font
        #expect(step >= tallestCaption,
                "row \(step)pt apart cannot clear a \(tallestCaption)pt caption")
        #expect(OverlayLayout.captionBottomInset(pictureHeight: height, row: 1)
                > OverlayLayout.captionBottomInset(pictureHeight: height, row: 0))
        // Row 0 is exactly where a caption used to sit, so nothing moved for
        // the recordings that have one voice.
        #expect(OverlayLayout.captionBottomInset(pictureHeight: height, row: 0)
                == OverlayLayout.captionBottomInset(pictureHeight: height))
    }
}

/// Muted tracks are not captioned.
///
/// `EditorWindowController.audibleWords` says in its own documentation that
/// every surface reads it "so the pane, the timeline lane and anything added
/// later cannot disagree about what is audible". Two surfaces did not: the
/// player's captions and the burned-in subtitles both read the raw transcript,
/// so muting narration silenced it and left its words on the picture.
struct AudibleSubtitleTests {

    private let whole = [TimeRange(start: 0, end: 60)]

    @Test("A muted track's speech is not captioned")
    func mutedNarrationIsNotBurnedIn() {
        let words = [
            TranscriptWord(text: "kept", start: 1.0, duration: 0.3, confidence: 1),
            TranscriptWord(text: "silenced", start: 1.0, duration: 0.3,
                           confidence: 1, track: "voiceover"),
        ]
        let states = [TrackState(track: "microphone"),
                      TrackState(track: "voiceover", muted: true)]
        let audible = AudibleTranscript.audible(words, trackStates: states)
        let cues = SubtitleCues.cues(words: audible, keptRanges: whole)
        #expect(cues.map(\.text) == ["kept"])
        // And with nothing to share the frame with, the survivor goes back to
        // the centre line rather than staying offset for a partner that is no
        // longer there.
        #expect(cues.allSatisfy { $0.placement == .alone })
    }
}

/// That two captions actually reach the FRAME, on two lines, in two colours.
///
/// The model being right says nothing about the picture. This project has
/// found twenty-seven defects where a test asserted a property adjacent to the
/// one that mattered, and "the cue list contains two entries" is exactly that
/// shape: all three renderers used a singular lookup, so a correct pair of
/// cues would still have drawn as one caption.
///
/// Drawn through `TextOverlayFrame`, which is the GIF path — and the path that
/// `AVAssetImageGenerator` cannot be used to check, because it ignores
/// `AVVideoComposition.animationTool` entirely.
struct TwoCaptionRenderTests {

    /// A flat mid-grey frame, so anything standing out is something drawn.
    private func blankFrame(width: Int = 640, height: Int = 360) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Every pixel that differs from the frame's own background, with its
    /// colour. Contrast rather than absolute brightness — a first version of
    /// `textCentroid` in `TextOverlayRenderTests` asked for the brightest
    /// pixel on a uniform grey and got (0, 0), passing against frames
    /// containing no text at all.
    ///
    /// PER CHANNEL rather than on luma, which is the trap this file fell into
    /// next: the narration teal is (90, 200, 189) and a mid-grey backdrop is
    /// (128, 128, 128), so its LUMA is 159 — thirty-one away, under any
    /// threshold loose enough to ignore compression noise. The detector
    /// discarded exactly the pixels it existed to find, and reported the
    /// renderer as broken when the renderer was correct.
    private func drawnPixels(in image: CGImage) -> [(y: Int, r: Int, g: Int, b: Int)] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var out: [(y: Int, r: Int, g: Int, b: Int)] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                let r = Int(data[p]), g = Int(data[p + 1]), b = Int(data[p + 2])
                let apart = max(abs(r - 128), max(abs(g - 128), abs(b - 128)))
                if apart > 45 { out.append((y, r, g, b)) }
            }
        }
        return out
    }

    private var pair: [SubtitleCue] {
        [SubtitleCue(start: 0, end: 4, text: "RECORDED",
                     track: "microphone", placement: .recorded),
         SubtitleCue(start: 0, end: 4, text: "NARRATION",
                     track: "voiceover", placement: .narration)]
    }

    @Test("Both captions are drawn, on two separate lines")
    func bothCaptionsReachTheFrame() throws {
        let frame = try blankFrame()
        let drawn = try #require(TextOverlayFrame.draw(
            cues: pair, banners: [], on: frame, atOutputTime: 1.0,
            renderSize: CGSize(width: 640, height: 360)) as CGImage?)

        let pixels = drawnPixels(in: drawn)
        #expect(pixels.count > 50, "nothing was drawn on the frame at all")

        // Two bands with a gap between them. A renderer that drew one caption,
        // or drew both at the same height, produces ONE band — which is the
        // defect, and which every count-the-cues assertion passes through.
        let rows = Set(pixels.map(\.y)).sorted()
        let gaps = zip(rows, rows.dropFirst()).filter { $1 - $0 > 4 }
        #expect(gaps.count == 1,
                "expected two separated lines of text, found \(gaps.count + 1) band(s)")
    }

    @Test("The two lines are drawn in two different colours")
    func narrationIsTealOnTheFrame() throws {
        let frame = try blankFrame()
        let drawn = try #require(TextOverlayFrame.draw(
            cues: pair, banners: [], on: frame, atOutputTime: 1.0,
            renderSize: CGSize(width: 640, height: 360)) as CGImage?)
        let pixels = drawnPixels(in: drawn)

        // Teal is the one channel relationship white cannot fake: green and
        // blue well clear of red. Asserting "some pixel is not white" would
        // pass on the shadow.
        let teal = pixels.filter { $0.g > $0.r + 30 && $0.b > $0.r + 30 }
        #expect(!teal.isEmpty, "no narration-coloured pixels — the caption is drawn white")

        let white = pixels.filter { $0.r > 200 && $0.g > 200 && $0.b > 200 }
        #expect(!white.isEmpty, "no white pixels — the recorded caption lost its colour")

        // And they are on DIFFERENT lines: a single caption drawn teal would
        // satisfy both assertions above.
        let tealRows = Set(teal.map(\.y)), whiteRows = Set(white.map(\.y))
        #expect(tealRows.intersection(whiteRows).isEmpty,
                "the two colours share rows — they are on the same line")
        // Narration on top, recorded below. Core Graphics here is bottom-left
        // origin flipped into image rows, so the narration's rows are the
        // SMALLER ones.
        let lowestTeal = try #require(tealRows.max())
        let highestWhite = try #require(whiteRows.min())
        #expect(lowestTeal < highestWhite, "narration is not above the recorded caption")
    }

    @Test("The two lines are horizontally offset, not stacked flush")
    func thePairIsOffsetOnThePicture() throws {
        // The user's actual requirement: "a left/right offset when there's
        // overlap, like movie dialog subtitles, so it's clear there are two
        // different speakers." Two stacked lines that both sit centred satisfy
        // every assertion about rows and colours and still do not read as two
        // speakers.
        let frame = try blankFrame()
        let drawn = try #require(TextOverlayFrame.draw(
            cues: pair, banners: [], on: frame, atOutputTime: 1.0,
            renderSize: CGSize(width: 640, height: 360)) as CGImage?)
        let pixels = drawnPixelsWithX(in: drawn)

        let teal = pixels.filter { $0.g > $0.r + 30 && $0.b > $0.r + 30 }
        let white = pixels.filter { $0.r > 200 && $0.g > 200 && $0.b > 200 }
        let tealCentre = try #require(centreX(of: teal))
        let whiteCentre = try #require(centreX(of: white))

        // Recorded hugs the left, narration the right. Compared against each
        // other rather than against the frame's midpoint, because the words
        // are different lengths and a centred pair would also sit at different
        // x if you only measured one of them.
        #expect(whiteCentre < tealCentre,
                "the recorded line (x=\(whiteCentre)) is not left of the narration (x=\(tealCentre))")
        // A real offset rather than a rounding difference.
        #expect(tealCentre - whiteCentre > 40,
                "the two lines are only \(tealCentre - whiteCentre)pt apart — not a visible offset")
    }

    private func centreX(of pixels: [(x: Int, y: Int, r: Int, g: Int, b: Int)]) -> Int? {
        guard !pixels.isEmpty else { return nil }
        return pixels.reduce(0) { $0 + $1.x } / pixels.count
    }

    /// `drawnPixels`, keeping the x as well.
    private func drawnPixelsWithX(in image: CGImage) -> [(x: Int, y: Int, r: Int, g: Int, b: Int)] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var out: [(x: Int, y: Int, r: Int, g: Int, b: Int)] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                let r = Int(data[p]), g = Int(data[p + 1]), b = Int(data[p + 2])
                let apart = max(abs(r - 128), max(abs(g - 128), abs(b - 128)))
                if apart > 45 { out.append((x, y, r, g, b)) }
            }
        }
        return out
    }

    @Test("A lone caption is still drawn where it always was")
    func soloCaptionIsUnmoved() throws {
        // The regression that would matter most: every recording with one
        // voice must look exactly as it did.
        let frame = try blankFrame()
        let solo = [SubtitleCue(start: 0, end: 4, text: "ALONE")]
        let drawn = try #require(TextOverlayFrame.draw(
            cues: solo, banners: [], on: frame, atOutputTime: 1.0,
            renderSize: CGSize(width: 640, height: 360)) as CGImage?)
        let rows = Set(drawnPixels(in: drawn).map(\.y)).sorted()
        let top = try #require(rows.min(), "the lone caption was not drawn")
        let gaps = zip(rows, rows.dropFirst()).filter { $1 - $0 > 4 }
        #expect(gaps.isEmpty, "a single caption was split across two lines")
        // In the bottom third, where captions live.
        #expect(Double(top) > 360 * 0.6,
                "the lone caption drifted up the frame to row \(top)")
    }
}

/// That the EXPORTER honours the mute, end to end.
///
/// `AudibleSubtitleTests` above proves `AudibleTranscript` and `SubtitleCues`
/// agree — which is a property ADJACENT to the one that matters. The exporter
/// read the raw transcript straight off disk, so both of those could be
/// perfect and every exported file would still carry captions for audio it had
/// muted. This drives a real export and looks at the frames.
struct MutedCaptionExportTests {

    private func bundle(words: [TranscriptWord], muted: [String]) async throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mutedcap-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.5,
                                      size: CGSize(width: 640, height: 360))
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try Transcript(words: words, locale: "en-US").write(to: bundle)
        return bundle
    }

    private func edl(muting muted: [String]) -> EditDecisionList {
        var edl = EditDecisionList(cuts: [], trackStates: [
            TrackState(track: "video"),
            TrackState(track: "microphone", muted: muted.contains("microphone")),
            TrackState(track: "voiceover", muted: muted.contains("voiceover")),
        ])
        edl.showSubtitles = true
        return edl
    }

    /// Frames with anything drawn on them, as a fraction. Captions are the
    /// only overlay these exports carry.
    private func framesCarryingText(in gif: URL) throws -> Int {
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        var marked = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if hasOverlayPixels(frame) { marked += 1 }
        }
        return marked
    }

    /// Whether anything at all was drawn over the flat synthetic frame.
    ///
    /// Measured against the frame's OWN median rather than against white. A
    /// first version looked for near-white pixels and the control failed: a
    /// lone narration caption is drawn teal, so "is there a caption" answered
    /// no for the one case the test existed to confirm. Measuring against
    /// white also could not survive GIF's 256-colour quantisation, which is
    /// free to shift the backdrop.
    private func hasOverlayPixels(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Int](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let p = i * 4
            luma[i] = (Int(data[p]) + Int(data[p + 1]) + Int(data[p + 2])) / 3
        }
        let background = luma.sorted()[luma.count / 2]
        var drawn = 0
        for i in 0..<(width * height) {
            let p = i * 4
            let apart = max(abs(Int(data[p]) - background),
                            max(abs(Int(data[p + 1]) - background),
                                abs(Int(data[p + 2]) - background)))
            if apart > 45 { drawn += 1 }
        }
        return drawn > 20
    }

    private let narration = [
        TranscriptWord(text: "NARRATION", start: 0.2, duration: 0.6,
                       confidence: 1, track: "voiceover"),
    ]

    @Test("Narration is captioned when its track is audible")
    func audibleNarrationIsBurnedIn() async throws {
        // The control. Without it, the assertion below passes against an
        // exporter that never draws captions at all.
        let bundle = try await bundle(words: narration, muted: [])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let out = FileManager.default.temporaryDirectory
            .appending(path: "cap-on-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await MovieExporter.export(bundle: bundle, edl: edl(muting: []),
                                           scale: 1.0, to: out, format: "gif")
        #expect(try framesCarryingText(in: out) > 0,
                "the control drew no captions, so this file proves nothing")
    }

    @Test("Muting the voiceover takes its captions out of the exported file")
    func mutedNarrationIsNotBurnedIn() async throws {
        let bundle = try await bundle(words: narration, muted: ["voiceover"])
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let out = FileManager.default.temporaryDirectory
            .appending(path: "cap-off-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await MovieExporter.export(bundle: bundle, edl: edl(muting: ["voiceover"]),
                                           scale: 1.0, to: out, format: "gif")
        #expect(try framesCarryingText(in: out) == 0,
                "a muted track's speech was captioned — the viewer reads words they cannot hear")
    }
}
