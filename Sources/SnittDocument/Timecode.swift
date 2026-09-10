// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Reading a time somebody typed.
///
/// The transport's readout is a field rather than a label so a precise jump
/// does not require scrubbing for it. That only works if the field accepts
/// what a person would actually type — which is not one format. `1:30`,
/// `90`, `1:30.5` and `0:08.27` are all the same intent, and refusing three
/// of them to accept one is the kind of strictness that makes a control feel
/// broken.
public enum Timecode {

    /// Seconds, or nil if the text is not a time.
    ///
    /// Nil rather than zero: a caller that cannot tell "they typed nonsense"
    /// from "they typed the start" would silently jump to the beginning on a
    /// typo, which is a destructive-feeling surprise in the middle of an edit.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var total: Double = 0
        for (index, part) in parts.enumerated() {
            // The LAST component may carry a fraction ("1:30.5"); the others
            // are whole minutes or hours, and "1.5:30" is not a time anybody
            // means.
            let isLast = index == parts.count - 1
            guard let value = Double(part), value >= 0,
                  isLast || value == value.rounded(),
                  // Only the leading component may exceed 59: "90" is ninety
                  // seconds, but "1:90" is not a time, and accepting it would
                  // quietly mean 2:30.
                  index == 0 || value < 60
            else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
