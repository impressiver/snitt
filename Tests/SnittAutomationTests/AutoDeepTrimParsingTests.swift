// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing
@testable import SnittAutomation
@testable import SnittDocument

/// `snitt auto-deep-trim` (D57), which exposes the presets AND the individual
/// criteria the presets are made of.
@Suite
struct AutoDeepTrimParsingTests {

    /// The preset, plus the one thing the CLI sets on top of it.
    ///
    /// `DeepTrimCriteria.preset` leaves `trimBookends` off, because the editor's
    /// deep trim has a timeline and a pair of trim handles beside it; `snitt
    /// auto-deep-trim` turns it on, because tidying a recording from a command
    /// line is one intent that used to cost two commands (PR I). Every
    /// expectation here is therefore the preset with that flip applied, and
    /// writing it as a function rather than a literal keeps the rest of the
    /// preset genuinely under test.
    private func asTyped(_ criteria: DeepTrimCriteria) -> DeepTrimCriteria {
        var criteria = criteria
        criteria.trimBookends = true
        return criteria
    }

    private func criteria(_ args: [String]) -> DeepTrimCriteria? {
        guard case .success(.autoDeepTrim(_, let criteria)) =
                CommandLineParser.parse(["auto-deep-trim"] + args) else { return nil }
        return criteria
    }

    @Test("With no options it uses the default preset")
    func bareInvocationUsesTheDefault() throws {
        let parsed = try #require(criteria(["rec.snitt"]))
        #expect(parsed == asTyped(DeepTrimCriteria.preset(.default)))
    }

    @Test("The path is carried through")
    func pathIsCarried() {
        guard case .success(.autoDeepTrim(let path, _)) =
                CommandLineParser.parse(["auto-deep-trim", "rec.snitt"]) else {
            Issue.record("did not parse"); return
        }
        #expect(path == "rec.snitt")
    }

    @Test("A preset selects all five criteria at once")
    func presetSelectsEverything() throws {
        #expect(try #require(criteria(["rec.snitt", "--preset", "aggressive"]))
                == asTyped(DeepTrimCriteria.preset(.aggressive)))
        #expect(try #require(criteria(["rec.snitt", "--preset", "conservative"]))
                == asTyped(DeepTrimCriteria.preset(.conservative)))
    }

    @Test("Each flag overrides exactly one criterion")
    func eachFlagOverridesOneField() throws {
        let base = DeepTrimCriteria.preset(.default)
        let parsed = try #require(criteria(["rec.snitt", "--min-span", "5"]))
        #expect(parsed.minimumSpan == 5)
        // The other four must be untouched. A parser that rebuilt the whole
        // struct from defaults would pass an assertion on `minimumSpan` alone.
        #expect(parsed.audioSilenceFraction == base.audioSilenceFraction)
        #expect(parsed.frameStillnessThreshold == base.frameStillnessThreshold)
        #expect(parsed.inputPadding == base.inputPadding)
        #expect(parsed.subtitleReadingTime == base.subtitleReadingTime)
    }

    @Test("All five criteria are individually settable")
    func everyCriterionHasAFlag() throws {
        let parsed = try #require(criteria([
            "rec.snitt",
            "--min-span", "4", "--audio-silence", "0.2",
            "--frame-stillness", "0.03", "--input-padding", "2",
            "--reading-time", "1.25",
        ]))
        #expect(parsed.minimumSpan == 4)
        #expect(abs(parsed.audioSilenceFraction - 0.2) < 0.0001)
        #expect(abs(parsed.frameStillnessThreshold - 0.03) < 0.0001)
        #expect(parsed.inputPadding == 2)
        #expect(parsed.subtitleReadingTime == 1.25)
    }

    @Test("Every flag overrides the preset it follows without discarding the rest")
    func flagsComposeWithAPreset() throws {
        // D57 asks for both forms. Making them exclusive would mean anyone
        // wanting "aggressive, but keep two seconds around clicks" has to
        // restate all five values.
        //
        // EVERY flag, not one of them: each has its own branch in the parser,
        // and an earlier version of this test exercised only `--input-padding`
        // — a mutant that reset the other four criteria inside the
        // `--min-span` branch survived it untouched.
        let base = DeepTrimCriteria.preset(.aggressive)
        let flags: [(String, String, (DeepTrimCriteria) -> Bool)] = [
            ("--min-span", "9", { $0.minimumSpan == 9 }),
            ("--audio-silence", "0.5", { abs($0.audioSilenceFraction - 0.5) < 0.0001 }),
            ("--frame-stillness", "0.09", { abs($0.frameStillnessThreshold - 0.09) < 0.0001 }),
            ("--input-padding", "2", { $0.inputPadding == 2 }),
            ("--reading-time", "3", { $0.subtitleReadingTime == 3 }),
        ]
        for (flag, value, applied) in flags {
            let parsed = try #require(criteria(["rec.snitt", "--preset", "aggressive", flag, value]),
                                      "\(flag) did not parse")
            #expect(applied(parsed), "\(flag) was not applied: \(parsed)")
            // Everything the flag did NOT name must still be the preset's.
            var expected = asTyped(base)
            switch flag {
            case "--min-span": expected.minimumSpan = 9
            case "--audio-silence": expected.audioSilenceFraction = 0.5
            case "--frame-stillness": expected.frameStillnessThreshold = 0.09
            case "--input-padding": expected.inputPadding = 2
            default: expected.subtitleReadingTime = 3
            }
            #expect(parsed == expected, "\(flag) discarded the rest of the preset: \(parsed)")
        }
    }

    // MARK: - Refusals

    @Test("An unknown preset is refused, and the message lists the real ones")
    func unknownPresetIsRefused() {
        guard case .failure(let failure) =
                CommandLineParser.parse(["auto-deep-trim", "rec.snitt", "--preset", "brutal"]) else {
            Issue.record("accepted an unknown preset"); return
        }
        for preset in DeepTrimPreset.allCases {
            #expect(failure.message.contains(preset.rawValue),
                    "the message does not name \(preset.rawValue): \(failure.message)")
        }
    }

    @Test("An unknown option is refused rather than ignored")
    func unknownOptionIsRefused() {
        // Silently ignoring it is how someone runs a trim that does something
        // other than what they typed, on a command whose job is deletion.
        guard case .failure = CommandLineParser.parse(
            ["auto-deep-trim", "rec.snitt", "--agressive"]) else {
            Issue.record("an unknown flag was ignored"); return
        }
    }

    @Test("A flag with no value, or a nonsense value, is refused")
    func missingOrBadValuesAreRefused() {
        for args in [["auto-deep-trim", "rec.snitt", "--min-span"],
                     ["auto-deep-trim", "rec.snitt", "--min-span", "soon"],
                     ["auto-deep-trim", "rec.snitt", "--input-padding", "-1"],
                     ["auto-deep-trim", "rec.snitt", "--preset"]] {
            guard case .failure = CommandLineParser.parse(args) else {
                Issue.record("accepted \(args)"); continue
            }
        }
    }

    @Test("Without a bundle path it says which path it wants")
    func missingPathIsRefused() {
        guard case .failure(let failure) = CommandLineParser.parse(["auto-deep-trim"]) else {
            Issue.record("accepted a bare invocation"); return
        }
        #expect(failure.message.contains(".snitt"))
    }
}
