// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Markers as a WebVTT chapter sidecar (§4.12).
///
/// Exists so a reviewer can scrub a three-minute demo instead of watching it
/// linearly — and so an agent can name what it recorded.
///
/// Callers pass ALREADY-MAPPED marker times — i.e. positions in the trimmed
/// export, not raw bundle timestamps. This type has no way to know about
/// cuts; see `MarkerMapping` for the piece that maps bundle time into export
/// time before markers reach here.
public enum WebVTTChapters {
    public static func render(markers: [LoggedEvent], duration: Double) -> String {
        let titled = titledMarkers(markers)
        guard !titled.isEmpty else { return "WEBVTT\n" }

        var out = "WEBVTT\n"
        for (index, entry) in titled.enumerated() {
            let start = min(max(0, entry.time), duration)
            let end = index + 1 < titled.count
                ? min(max(start, titled[index + 1].time), duration)
                : duration
            out += "\n\(timestamp(start)) --> \(timestamp(end))\n\(entry.title)\n"
        }
        return out
    }

    /// Non-marker events filtered out, sorted, and given a fallback title —
    /// shared with `MovieExporter` so the manifest's `chapters` list and the
    /// WebVTT sidecar it points at always agree on titles and ordering.
    static func titledMarkers(_ markers: [LoggedEvent]) -> [(time: Double, title: String)] {
        markers
            .filter { $0.kind == .marker }
            .sorted { $0.timeSeconds < $1.timeSeconds }
            .enumerated()
            .map { index, marker in
                // An unlabelled marker still needs a name: a reviewer cannot
                // click a blank chapter.
                (time: marker.timeSeconds, title: marker.label ?? "Chapter \(index + 1)")
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
