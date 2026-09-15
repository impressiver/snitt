// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Marker transcripts as a WebVTT subtitle sidecar (D50).
///
/// Distinct from `WebVTTChapters`, which turns a marker's `label` into a
/// navigation entry spanning to the next marker. A subtitle is not navigation:
/// it is speech, it uses `transcript` rather than `label`, and it must
/// DISAPPEAR when it has been read. A chapter that runs to the next marker is
/// correct; a caption that does is a wall of text sitting on screen for two
/// minutes.
///
/// Callers pass ALREADY-MAPPED times, exactly as `WebVTTChapters` requires —
/// see `MarkerMapping` for the piece that converts bundle time to export time.
public enum WebVTTSubtitles {
    /// Reading speed, in words per second — `SpeechRate`'s, not a second copy.
    ///
    /// The number moved down to `SnittDocument` when authored narration needed
    /// it too: `SnittExport` may depend on that module and not the reverse, so
    /// a constant declared here was unreachable from the layer that writes the
    /// words. Kept as a forwarding property because this is the name the
    /// caption code and its tests already ask for.
    public static var wordsPerSecond: Double { SpeechRate.wordsPerSecond }
    /// No cue shorter than this, however few words: a caption that flashes is
    /// worse than none.
    public static let minimumCueSeconds = 1.2
    /// No cue longer than this, however many words. A very long transcript is
    /// a sign the marker is carrying a paragraph, and holding it for half a
    /// minute is worse than truncating its welcome.
    public static let maximumCueSeconds = 7.0

    public static func render(markers: [LoggedEvent], duration: Double) -> String {
        let cues = self.cues(markers: markers, duration: duration)
        guard !cues.isEmpty else { return "WEBVTT\n" }
        var out = "WEBVTT\n"
        for cue in cues {
            out += "\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }
        return out
    }

    /// Cue spans, exposed so the timing rules can be tested without parsing
    /// WebVTT back out of a string.
    public static func cues(markers: [LoggedEvent],
                            duration: Double) -> [(start: Double, end: Double, text: String)] {
        // Only markers WITH a transcript. A marker labelled "opened settings"
        // and nothing else is a chapter, not something anyone said — rendering
        // its label as a caption would put UI notes in the subtitle track.
        let spoken = markers
            .filter { $0.kind == .marker }
            .compactMap { marker -> (time: Double, text: String)? in
                guard let transcript = marker.transcript,
                      !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (marker.timeSeconds, transcript)
            }
            .sorted { $0.time < $1.time }

        return spoken.enumerated().compactMap { index, entry in
            let start = min(max(0, entry.time), duration)
            guard start < duration else { return nil }
            let words = entry.text.split(whereSeparator: \.isWhitespace).count
            let reading = min(max(Double(words) / wordsPerSecond, minimumCueSeconds),
                              maximumCueSeconds)
            // Never overlap the next cue: two captions on screen at once is a
            // rendering bug in every player, not a stylistic choice.
            let nextStart = index + 1 < spoken.count ? spoken[index + 1].time : duration
            let end = min(start + reading, min(nextStart, duration))
            guard end > start else { return nil }
            return (start, end, entry.text)
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}
