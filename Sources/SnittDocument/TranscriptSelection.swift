// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Selecting a run of words in the transcript.
///
/// Pure, and here rather than in the pane, because the interesting part is not
/// the gesture: it is WHICH ORDER a shift-click extends along. The pane no
/// longer draws words in `transcript.words` order — rows are grouped by voice,
/// so a narrator's phrase is one row even though its words interleave in time
/// with the speech beside it. Extending along the stored order would select
/// words the reader can see are not between the two they clicked.
public enum TranscriptSelection {

    /// The words the pane actually draws, in the order it draws them.
    ///
    /// The rows, flattened. This is the sequence a reader's eye follows, and
    /// therefore the sequence "everything from here to there" has to mean.
    public static func displayOrder(_ words: [TranscriptWord]) -> [TranscriptWord] {
        TranscriptParagraphs.split(words).flatMap(\.words)
    }

    /// Every word between `anchor` and `target` inclusive, in display order.
    ///
    /// Either end may be the earlier one: a selection dragged upward is the
    /// same selection dragged downward, which is how text selection behaves
    /// everywhere else on the platform.
    ///
    /// An id that is not on screen yields just the target. That is the muted
    /// case: mute a track and its words leave the pane, so an anchor set
    /// before the mute is a click on something no longer visible — and
    /// silently selecting from a word nobody can see to one they can is worse
    /// than starting again.
    public static func range(from anchor: UUID?, to target: UUID,
                             in words: [TranscriptWord]) -> Set<UUID> {
        let ordered = displayOrder(words)
        guard let anchor,
              let anchorIndex = ordered.firstIndex(where: { $0.id == anchor }),
              let targetIndex = ordered.firstIndex(where: { $0.id == target })
        else { return [target] }
        let span = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(ordered[span].map(\.id))
    }
}
