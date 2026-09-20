// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Naming a fold from the markers around it.
///
/// An automatic trim (D57) produces holes, and a hole says nothing about what
/// used to be in it. A timeline of anonymous gaps has to be expanded one at a
/// time to be understood, which is most of the time the trim just saved.
///
/// The markers are what make this possible and are also why it cannot be
/// copied: competitors' equivalents are audio-driven — Descript shortens word
/// gaps, Screen Studio cuts by hand — and Snitt's flagship recordings are
/// silent agent sessions with no narration at all. What those recordings do
/// have is semantic markers an agent wrote as it worked, so a fold can read
/// "waiting for build — 4m 12s" rather than "3:40 of silence".
public enum FoldLabel {

    /// A duration in the shortest form that stays unambiguous.
    ///
    /// Rounded to the second: a fold is a span of nothing, and tenths of a
    /// second of nothing is a precision that means nothing.
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }

    /// What to call the fold over `span`.
    ///
    /// The marker chosen is the most specific thing known about that stretch:
    /// one INSIDE the span first — it describes the removed material directly —
    /// then the last one BEFORE it, which is what was happening when the gap
    /// began, and is the usual case. An automatic trim never folds over a
    /// marker (markers veto dead air, D57), so the inside case only arises for
    /// a cut somebody made by hand.
    ///
    /// With no marker to draw on, the duration alone. That is less than the
    /// feature promises, and saying "4m 12s" is still better than a nameless
    /// band — but it is the honest answer when nothing described that stretch.
    public static func describe(span: TimeRange, markers: [LoggedEvent]) -> String {
        let length = duration(span.end - span.start)
        let named = markers.filter { $0.kind == .marker && $0.label?.isEmpty == false }

        let inside = named.filter { $0.timeSeconds >= span.start && $0.timeSeconds < span.end }
            .min { $0.timeSeconds < $1.timeSeconds }
        let before = named.filter { $0.timeSeconds <= span.start }
            .max { $0.timeSeconds < $1.timeSeconds }

        guard let marker = inside ?? before, let text = marker.label else { return length }
        return "\(text) (\(length))"
    }
}
