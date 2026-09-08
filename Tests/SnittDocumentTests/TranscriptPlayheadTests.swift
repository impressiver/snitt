import Testing
import Foundation
@testable import SnittDocument

/// Which word the playhead is inside.
///
/// Every test uses a recording WITH a cut, deliberately. Without one the source
/// and output clocks agree, and an implementation that ignores `keptRanges`
/// entirely passes — which is M4b's Critical #1 shape and the reason
/// `TimelineSampleIndex` is built the same way.
@Suite
struct TranscriptPlayheadTests {
    // 2s removed from 2...4. Output is source minus 2 after the cut.
    private let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 4, end: 20)]

    private static func word(_ text: String, _ start: Double, _ duration: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: duration, confidence: 0.9)
    }

    private let words = [
        word("before", 1.0, 0.5),      // survives, output 1.0
        word("removed", 2.5, 0.5),     // inside the cut — unreachable
        word("after", 5.0, 0.5),       // survives, output 3.0
        word("later", 6.0, 0.5),       // survives, output 4.0
    ]

    @Test("Before any cut, output and source agree")
    func beforeTheCut() {
        let id = TranscriptPlayhead.currentWordID(outputSeconds: 1.2, words: words, keptRanges: kept)
        #expect(id == words[0].id)
    }

    @Test("After a cut, the playhead finds the word by SOURCE time")
    func afterTheCut() {
        // Output 3.2 is source 5.2 — inside "after". An implementation treating
        // output as source finds nothing here (source 3.2 is in the cut), so
        // this is the assertion that catches the whole defect class.
        let id = TranscriptPlayhead.currentWordID(outputSeconds: 3.2, words: words, keptRanges: kept)
        #expect(id == words[2].id, "the playhead did not map through the cut")
    }

    @Test("A word inside a cut is never current")
    func cutWordsAreUnreachable() {
        // No output time maps to source 2.5-3.0 at all; the guarantee falls out
        // of the mapping rather than needing a special case. Sweep the whole
        // output timeline to be sure nothing reaches it.
        let reachable = stride(from: 0.0, to: 18.0, by: 0.05).compactMap {
            TranscriptPlayhead.currentWordID(outputSeconds: $0, words: words, keptRanges: kept)
        }
        #expect(!reachable.contains(words[1].id), "a cut word was highlighted")
    }

    @Test("Silence between words highlights nothing")
    func gapsHighlightNothing() {
        // Output 2.0 is source 4.0 — after the cut, before "after" at 5.0.
        // Holding the previous word lit through a pause would claim someone is
        // still saying it.
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 2.0, words: words,
                                                 keptRanges: kept) == nil)
    }

    @Test("A word's end belongs to the NEXT word, not to it")
    func endIsExclusive() {
        // Contiguous spans are what the recognizer produces within an
        // utterance. An inclusive end lights two words on the same frame.
        let touching = [Self.word("one", 0.0, 0.5), Self.word("two", 0.5, 0.5)]
        let whole = [TimeRange(start: 0, end: 10)]
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 0.5, words: touching,
                                                 keptRanges: whole) == touching[1].id)
    }

    @Test("Past the end of the recording, nothing is current")
    func pastTheEnd() {
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 500, words: words,
                                                 keptRanges: kept) == nil)
    }

    @Test("An empty transcript highlights nothing rather than crashing")
    func emptyTranscript() {
        #expect(TranscriptPlayhead.currentWordID(outputSeconds: 1.0, words: [],
                                                 keptRanges: kept) == nil)
    }
}
