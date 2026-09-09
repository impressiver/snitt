// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Turns a selection of transcript words into the cut that removes them.
///
/// This is D62's payoff: deleting a phrase in text becomes a `Cut` over its
/// span, going through exactly the EDL every other edit uses — so a text
/// deletion is undoable, visible as a fold on the timeline, and preserved by
/// `snitt trim` like any hand-made cut. There is no second editing model.
public enum TranscriptEditing {
    /// The source-time span removing `selected` would cut.
    ///
    /// The span runs from the first selected word's START to the last selected
    /// word's END — the words themselves, not the silence around them. The gap
    /// before the next word survives, deliberately: that pause is the speaker
    /// breathing between sentences, and swallowing it makes the edit audible
    /// as an unnaturally hard splice. Removing dead air is D57's job, with its
    /// own criteria; a text deletion should remove exactly what was selected.
    ///
    /// Non-contiguous selections produce one span PER RUN of adjacent words,
    /// not one span bridging them — bridging would delete unselected words in
    /// the middle.
    public static func cutRanges(removing selected: [TranscriptWord],
                                 from transcript: Transcript) -> [TimeRange] {
        guard !selected.isEmpty else { return [] }
        let ordered = transcript.words
        let selectedIDs = Set(selected.map(\.id))
        var indices = ordered.indices.filter { selectedIDs.contains(ordered[$0].id) }.sorted()
        guard !indices.isEmpty else { return [] }

        var ranges: [TimeRange] = []
        while !indices.isEmpty {
            let runStart = indices.removeFirst()
            var runEnd = runStart
            while let next = indices.first, next == runEnd + 1 {
                runEnd = next
                indices.removeFirst()
            }
            let start = ordered[runStart].start
            let end = ordered[runEnd].end
            if end > start { ranges.append(TimeRange(start: start, end: end)) }
        }
        return ranges
    }

    /// Which words are currently cut, by id — for striking them through.
    ///
    /// Derived from the EDL every time rather than stored on the word: the EDL
    /// is the single source of what is removed, and a word "remembering" it was
    /// deleted would survive the cut's own undo.
    ///
    /// A word counts as cut when its MIDPOINT falls inside a cut. Boundary
    /// words sliced by a hand-made cut are genuinely half-audible; the midpoint
    /// says which half, which matches what a viewer hears better than either
    /// all-or-nothing rule.
    public static func cutWordIDs(in transcript: Transcript,
                                  cuts: [Cut]) -> Set<UUID> {
        guard !cuts.isEmpty else { return [] }
        var ids = Set<UUID>()
        for word in transcript.words {
            let mid = word.start + word.duration / 2
            if cuts.contains(where: { mid >= $0.range.start && mid < $0.range.end }) {
                ids.insert(word.id)
            }
        }
        return ids
    }
}
