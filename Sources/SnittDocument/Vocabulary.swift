import Foundation

/// Terms handed to the speech recogniser so it expects to hear them.
///
/// D62 made transcription a pillar and shipped an in-place correction UI
/// because the recogniser gets things wrong. This is the other half: telling it
/// what to expect BEFORE it guesses. A screen recording's narration is dense
/// with identifiers no general model has seen — `KeptRanges`,
/// `SCContentSharingPicker`, `edit.json` — and every one it mishears is a
/// correction somebody has to make by hand.
///
/// The recogniser takes these as `contextualStrings`, which biases toward them
/// without restricting to them: a term that is never said costs nothing, so an
/// over-broad list is not the failure mode. An unbounded one is, which is what
/// `limit` is for.
public enum Vocabulary {

    /// How many terms are worth sending.
    ///
    /// `SFSpeechRecognitionRequest` documents `contextualStrings` as a
    /// small-scale hint rather than a dictionary, and a list long enough to
    /// contain every identifier in a codebase would dilute the bias it exists
    /// to apply. Truncating is reported rather than silent — see `prepare`.
    public static let limit = 100

    /// The longest single term worth sending.
    ///
    /// A phrase, not a paragraph: something pasted by accident should not
    /// consume the budget.
    public static let maximumTermLength = 60

    /// Clean a caller's list into what the recogniser should receive.
    ///
    /// Trims, drops blanks, removes duplicates case-insensitively while keeping
    /// the caller's own spelling — `keptRanges` and `KeptRanges` bias
    /// identically, and returning the one they typed is what makes a transcript
    /// read the way they write.
    public static func prepare(_ terms: [String]) -> (terms: [String], dropped: Int) {
        var seen = Set<String>()
        var out: [String] = []
        var dropped = 0
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maximumTermLength else {
                if !term.isEmpty { dropped += 1 }
                continue
            }
            guard seen.insert(term.lowercased()).inserted else { continue }
            guard out.count < limit else { dropped += 1; continue }
            out.append(term)
        }
        return (out, dropped)
    }
}
