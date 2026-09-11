// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

@Test("A version is always reported, even with no bundle")
func versionIsNeverEmpty() {
    // Under `swift test` there is no CFBundleShortVersionString. An empty
    // string here would reach `snitt --version` and every diagnostics
    // bundle, where it reads as "unknown build" to a support engineer.
    #expect(!AppVersion.current.isEmpty)
}

@Test("The marketing version looks like a version, marker and all")
func versionIsWellFormed() {
    // This test used to require every component to be numeric, because this
    // string was ALSO what Sparkle compared. It is not any more — the two
    // plist keys are disjoint, and the numeric requirement moved with the
    // comparison to `build` below.
    //
    // What is still required is that it reads as a version: `main` carries a
    // `-dev` marker between releases, and that marker is allowed exactly
    // where it cannot do harm.
    let parts = AppVersion.current.split(separator: ".")
    #expect(parts.count >= 2)
    let numeric = AppVersion.current.split(separator: "-").first ?? ""
    let allNumeric = numeric.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
    #expect(allNumeric,
            "\(AppVersion.current) is not a dotted-numeric version with an optional marker")
}

@Test("The build number is strictly numeric — it is what Sparkle compares")
func buildIsNumeric() {
    // The requirement that moved off `current`. Sparkle asks that the version
    // it compares be a plain increasing number, and a non-numeric one makes
    // every comparison meaningless with no error attached — "updates never
    // appear". Under `swift test` there is no bundle, so this is the "0"
    // fallback; the built app's real value is asserted where the plist is.
    let build = AppVersion.build
    let numeric = build.allSatisfy(\.isNumber)
    #expect(!build.isEmpty)
    #expect(numeric, "CFBundleVersion must be numeric, got \(build)")
}

@Test("A -dev marker never reaches the number Sparkle compares")
func markerNeverReachesTheComparison() {
    // The property the whole split exists for. A `-dev` marker on the number
    // Sparkle compares is the failure this design avoids: it would make the
    // comparison undefined, and the alternative — a BARE next version — makes
    // a development build claim to be a release it will then refuse.
    #expect(!AppVersion.build.contains("-"))
}
