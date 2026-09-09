// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing
@testable import SnittDocument

/// Preparing recogniser hints (D81).
@Suite
struct VocabularyTests {

    @Test("Blank and whitespace-only terms are dropped, not sent")
    func blanksAreDropped() {
        let (terms, _) = Vocabulary.prepare(["KeptRanges", "", "   ", "\n"])
        #expect(terms == ["KeptRanges"])
    }

    @Test("Terms are trimmed, so a trailing space is not a different word")
    func termsAreTrimmed() {
        #expect(Vocabulary.prepare([" SCStream "]).terms == ["SCStream"])
    }

    @Test("Duplicates collapse case-insensitively, keeping the caller's spelling")
    func duplicatesCollapseKeepingSpelling() {
        // `keptRanges` and `KeptRanges` bias identically, so sending both wastes
        // budget. Returning the FIRST spelling is what makes a transcript read
        // the way the caller writes.
        let (terms, _) = Vocabulary.prepare(["KeptRanges", "keptranges", "KEPTRANGES"])
        #expect(terms == ["KeptRanges"])
    }

    @Test("The list is capped, and says how much it dropped")
    func longListsAreCappedAndReported() {
        // `contextualStrings` is a hint, not a dictionary: a list long enough
        // to hold every identifier in a codebase dilutes the bias it exists to
        // apply. Truncating silently would leave a caller wondering why the
        // last forty terms did nothing.
        let many = (0..<150).map { "Symbol\($0)" }
        let (terms, dropped) = Vocabulary.prepare(many)
        #expect(terms.count == Vocabulary.limit)
        #expect(dropped == 50, "dropped \(dropped)")
        #expect(terms.first == "Symbol0", "kept the wrong end of the list")
    }

    @Test("A pasted paragraph is dropped rather than eating the budget")
    func overlongTermsAreDropped() {
        let sentence = String(repeating: "a", count: Vocabulary.maximumTermLength + 1)
        let (terms, dropped) = Vocabulary.prepare(["SCStream", sentence])
        #expect(terms == ["SCStream"])
        #expect(dropped == 1)
    }

    @Test("An empty request stays empty rather than becoming a blank hint")
    func emptyStaysEmpty() {
        #expect(Vocabulary.prepare([]).terms.isEmpty)
        #expect(Vocabulary.prepare(["  "]).terms.isEmpty)
    }
}

/// The vocabulary travels with the recording (D81).
@Suite
struct RecordingVocabularyTests {

    @Test("Metadata round-trips the vocabulary")
    func vocabularyRoundTrips() throws {
        let meta = RecordingMetadata(createdAt: Date(), initiator: .agent,
                                     vocabulary: ["KeptRanges", "SCStream"])
        let decoded = try JSONDecoder().decode(
            RecordingMetadata.self, from: JSONEncoder().encode(meta))
        #expect(decoded.vocabulary == ["KeptRanges", "SCStream"])
    }

    @Test("Metadata written before vocabulary existed still decodes")
    func legacyMetadataDecodes() throws {
        // Every recording made before today has no `vocabulary` key, and D54
        // makes updates hand-delivered, so old and new bundles coexist.
        let json = Data(#"{"schemaVersion": 1, "createdAt": 0, "initiator": "human"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let meta = try decoder.decode(RecordingMetadata.self, from: json)
        #expect(meta.vocabulary == nil)
    }
}
