// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// One caption on screen: what it says, and when.
public struct SubtitleCue: Equatable, Sendable {
    /// OUTPUT time — the clock the exported file and the preview both use.
    public let start: Double
    public let end: Double
    /// Already wrapped to at most `SubtitleCues.maximumLines` lines, joined by
    /// newlines. Wrapped here rather than at draw time so the preview and the
    /// burn-in cannot break the same sentence in two different places.
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: Double { end - start }
}

/// Captions, from the TRANSCRIPT.
///
/// **Subtitles are what was said; markers are what was noted.** Those used to
/// be the same thing — `WebVTTSubtitles` rendered a marker's `transcript`
/// field as a caption — and conflating them meant a recording with no markers
/// had no subtitles at all, however much was spoken. Speech now comes from the
/// transcript, and markers get their own banner, which is a different shape on
/// screen because it is a different kind of statement.
///
/// Word timings make this possible at all: `SpeechAnalyzer` reports an
/// `audioTimeRange` per word, so a cue can end when its last word does rather
/// than at a guess.
public enum SubtitleCues {

    /// 42 characters is the line length BBC and Netflix subtitle guidelines
    /// both settle on — long enough not to fragment a sentence, short enough
    /// to read without tracking across the frame.
    public static let maximumCharactersPerLine = 42
    /// Two lines. A third is a wall of text over the thing being demonstrated,
    /// which is the content the caption is describing.
    public static let maximumLines = 2

    /// Reading speed and cue bounds come from `WebVTTSubtitles`, deliberately.
    /// Its own comment says the two readers should move together when either
    /// is measured; two copies of a reading-speed constant is how they stop.
    public static var wordsPerSecond: Double { WebVTTSubtitles.wordsPerSecond }
    public static var minimumCueSeconds: Double { WebVTTSubtitles.minimumCueSeconds }
    public static var maximumCueSeconds: Double { WebVTTSubtitles.maximumCueSeconds }

    /// A pause this long ends a cue. Shared with `TranscriptParagraphs`, which
    /// breaks the transcript pane's paragraphs at the same silences — the pane
    /// and the captions should agree about where a sentence ended.
    public static var breakSeconds: Double { TranscriptParagraphs.breakSeconds }

    /// Cues in OUTPUT time, with words inside cuts dropped.
    ///
    /// - Parameters:
    ///   - words: transcript words, in SOURCE time.
    ///   - keptRanges: what survives the edit. A word inside a cut has no
    ///     output time and no caption — the same rule `ClickOverlay.marks`
    ///     applies to clicks, for the same reason.
    public static func cues(words: [TranscriptWord],
                            keptRanges: [TimeRange]) -> [SubtitleCue] {
        guard !keptRanges.isEmpty else { return [] }

        // Mapped first, then grouped. Grouping in source time and mapping
        // afterwards would join two words that a cut separated by a minute,
        // producing a caption whose first and last words were never adjacent.
        let placed: [(start: Double, end: Double, text: String)] = words.compactMap { word in
            guard let start = TimeRangeMapping.trimmedTime(of: word.start,
                                                           keptRanges: keptRanges)
            else { return nil }
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (start, start + max(0, word.duration), text)
        }.sorted { $0.start < $1.start }

        var cues: [SubtitleCue] = []
        var current: [(start: Double, end: Double, text: String)] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let words = current.map(\.text)
            let spoken = last.end - first.start
            // The cue lasts as long as the speech, then at least long enough
            // to read: a fast "yes" is on screen for `minimumCueSeconds`, not
            // for the 0.2s it took to say.
            let readable = Double(words.count) / wordsPerSecond
            let held = min(maximumCueSeconds, max(minimumCueSeconds, max(spoken, readable)))
            cues.append(SubtitleCue(start: first.start,
                                    end: first.start + held,
                                    text: wrap(words)))
            current = []
        }

        for word in placed {
            if let last = current.last {
                let paused = word.start - last.end >= breakSeconds
                let tooLong = word.end - (current.first?.start ?? word.start) > maximumCueSeconds
                let tooWide = width(of: current.map(\.text) + [word.text])
                    > maximumCharactersPerLine * maximumLines
                if paused || tooLong || tooWide { flush() }
            }
            current.append(word)
        }
        flush()

        return trimOverlaps(cues)
    }

    /// A cue must never still be on screen when the next one starts.
    ///
    /// The hold above can push a cue past its successor — a short utterance
    /// held for `minimumCueSeconds` runs into the next line when someone
    /// speaks quickly. Two captions drawn at once is not a subtle defect: they
    /// overlap in the same place on the frame.
    private static func trimOverlaps(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count > 1 else { return cues }
        var out: [SubtitleCue] = []
        for (index, cue) in cues.enumerated() {
            if index + 1 < cues.count {
                let next = cues[index + 1].start
                out.append(SubtitleCue(start: cue.start,
                                       end: min(cue.end, next),
                                       text: cue.text))
            } else {
                out.append(cue)
            }
        }
        return out
    }

    private static func width(of words: [String]) -> Int {
        words.reduce(0) { $0 + $1.count } + max(0, words.count - 1)
    }

    /// Greedy wrap to at most `maximumLines`.
    ///
    /// Greedy rather than balanced: a balanced wrap looks better on a poster
    /// and worse in motion, because the first line's length changes as the
    /// cue grows and the eye has to re-find the start.
    static func wrap(_ words: [String]) -> String {
        var lines: [String] = []
        var line = ""
        for word in words {
            let candidate = line.isEmpty ? word : line + " " + word
            if candidate.count <= maximumCharactersPerLine || line.isEmpty {
                line = candidate
            } else {
                lines.append(line)
                line = word
            }
        }
        if !line.isEmpty { lines.append(line) }
        // Anything past the line budget joins the last line rather than being
        // dropped: a truncated caption is a caption that lies about what was
        // said, and the grouping above already bounds how much can arrive.
        if lines.count > maximumLines {
            let kept = lines.prefix(maximumLines - 1)
            let rest = lines.dropFirst(maximumLines - 1).joined(separator: " ")
            lines = Array(kept) + [rest]
        }
        return lines.joined(separator: "\n")
    }

    /// The cue visible at `outputTime`, if any.
    public static func cue(at outputTime: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        cues.last { $0.start <= outputTime && outputTime < $0.end }
    }
}
