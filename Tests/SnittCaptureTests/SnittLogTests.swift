// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittCapture

@Test("Loggers carry the target as subsystem suffix and the category")
func loggerNamesAreStructured() {
    // These two fields are what a diagnostics bundle FILTERS on (S8), so
    // they are a contract rather than cosmetics.
    #expect(SnittLog.subsystemName(for: "SnittCapture") == "com.impressiver.snitt.SnittCapture")
    #expect(SnittLog.subsystemName(for: "SnittExport") == "com.impressiver.snitt.SnittExport")
}

@Test("Every subsystem shares the prefix a diagnostics filter matches")
func subsystemsSharePrefix() {
    // DiagnosticsBundle selects entries by prefix; a target that invented
    // its own root would vanish from every exported bundle while looking
    // fine in the console.
    for target in ["SnittCapture", "SnittExport", "SnittApp", "SnittAutomation"] {
        #expect(SnittLog.subsystemName(for: target).hasPrefix(SnittLog.subsystem))
    }
}
