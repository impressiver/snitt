// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_cli
import SnittAutomation
import SnittDocument

/// Guards §12's "off vs none found" promise at the actual text a person
/// reads after `snitt diagnostics export`: `diagnosticsNote` had no coverage
/// at all before this file, so a renderer that always printed
/// "N crash report(s)" — collapsing "we weren't looking" into "nothing
/// crashed" — would have shipped invisibly.
@Test("With crash reporting off, the CLI note says so, not \"0 crash reports\"")
func diagnosticsNoteSaysOffWhenDisabled() throws {
    // Discriminates against the exact mutant the review named: hardcoding
    // `"\(report.crashReports.count) crash report(s)"` unconditionally. That
    // mutant renders "0 crash report(s)" here, which reads identically to a
    // machine that opted in and found nothing — this asserts against that
    // conflation directly, not just for the presence of some text.
    let report = DiagnosticsReport(
        appVersion: "1.2.3", protocolVersion: 2, generatedAt: Date(),
        permissions: [:], recentSessions: [], logLines: [],
        crashReportingEnabled: false, crashReports: [])

    let note = diagnosticsNote(report, outputPath: "/tmp/diagnostics.json")

    #expect(note.lowercased().contains("off"),
            "the note must say collection was off")
    #expect(!note.contains("0 crash report"),
            "\"0 crash report(s)\" is indistinguishable from \"nothing crashed\" and must not appear when collection was off")
}

@Test("With crash reporting on, the CLI note gives a count, not \"off\"")
func diagnosticsNoteGivesCountWhenEnabled() throws {
    let report = DiagnosticsReport(
        appVersion: "1.2.3", protocolVersion: 2, generatedAt: Date(),
        permissions: [:], recentSessions: [], logLines: [],
        crashReportingEnabled: true, crashReports: [])

    let note = diagnosticsNote(report, outputPath: "/tmp/diagnostics.json")

    #expect(note.contains("0 crash report"),
            "collection was ON and found none — that is a different state from \"off\" and must say so")
    #expect(!note.lowercased().contains("crash reporting off"))
}
