// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// One thing on the timeline a screen reader can reach.
public struct TimelineAccessibilityElement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case mark, fold }
    public let kind: Kind
    /// Where it sits, in OUTPUT time — the same clock as the playhead.
    public let outputSeconds: Double
    /// What VoiceOver says.
    public let label: String
}

/// A fold, as the view already knows it.
public struct FoldDescriptor: Equatable, Sendable {
    public let outputSeconds: Double
    public let removedSeconds: Double
    public init(outputSeconds: Double, removedSeconds: Double) {
        self.outputSeconds = outputSeconds
        self.removedSeconds = removedSeconds
    }
}

/// Making the timeline reachable without a pointer.
///
/// The timeline is a raw `NSView` drawing with Core Graphics: marks, folds and
/// the playhead are pixels, and pixels have no accessibility. Everything on it
/// was unreachable to VoiceOver and to anyone not using a mouse — including
/// the marks, which are how you navigate a Snitt recording and the one thing
/// carrying the agent-authored labels.
///
/// Pure, so the wording and the ordering are testable without the
/// accessibility runtime, which is not something a unit test can interrogate.
public enum TimelineAccessibility {

    /// Everything reachable, in time order.
    ///
    /// Marks and folds are interleaved rather than grouped, because the rotor
    /// steps through them in the order given and a listener building a mental
    /// model of the recording needs "mark, fold, mark" — not every mark
    /// followed by every fold, which describes a different recording.
    public static func elements(marks: [JumpPoint],
                                folds: [FoldDescriptor]) -> [TimelineAccessibilityElement] {
        let markElements = marks.map {
            TimelineAccessibilityElement(kind: .mark, outputSeconds: $0.timeSeconds,
                                         label: markLabel($0))
        }
        let foldElements = folds.map {
            TimelineAccessibilityElement(kind: .fold, outputSeconds: $0.outputSeconds,
                                         label: foldLabel($0))
        }
        return (markElements + foldElements).sorted { $0.outputSeconds < $1.outputSeconds }
    }

    /// A mark reads as its own words first.
    ///
    /// The label is the differentiator — it is what an agent writes and what
    /// `snitt_inspect` reads back — so it leads, and the time follows as
    /// context. "Mark 3 of 7" would describe the list; this describes the
    /// recording.
    static func markLabel(_ mark: JumpPoint) -> String {
        let text = mark.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = clock(mark.timeSeconds)
        // An unlabelled mark is a real case — a hotkey press with nothing
        // typed after it — and an empty string would be announced as silence,
        // which is indistinguishable from the rotor having nothing there.
        guard !text.isEmpty else { return "Unlabelled mark, at \(when)" }
        return "\(text), mark at \(when)"
    }

    /// A fold says what it REMOVED, not where it is.
    ///
    /// The question a listener has at a fold is "what am I not hearing", and
    /// the answer is a duration. Its position is already implied by where the
    /// rotor is.
    static func foldLabel(_ fold: FoldDescriptor) -> String {
        let removed = max(0, fold.removedSeconds)
        let amount = removed < 1
            ? String(format: "%.1f seconds", removed)
            : "\(clock(removed))"
        return "Fold, \(amount) removed, at \(clock(fold.outputSeconds))"
    }

    /// What the timeline itself reports as its value.
    public static func playheadValue(outputSeconds: Double, duration: Double) -> String {
        "\(clock(outputSeconds)) of \(clock(duration))"
    }

    /// `m:ss`, the app's one spoken time format — the same one the menu-bar
    /// item and the recording HUD use. A third rendering of a duration is a
    /// third thing that can disagree about what 90 seconds is called.
    static func clock(_ seconds: Double) -> String {
        RecordingState.clock(seconds)
    }
}
