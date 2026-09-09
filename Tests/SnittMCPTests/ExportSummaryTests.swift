// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_mcp
import SnittDocument
import SnittAutomation

/// Mirrors `SnittCLITests/ExportNoteTests.swift` for the MCP frontend — §4.8
/// requires the two frontends not to diverge, so both surfaces need the same
/// coverage of finding #1: an agent that asked for `maxSize: "5MB"` and got
/// 9MB back must be TOLD, in the text it reads, not just handed a JSON field
/// it was never asked to inspect.
@Test("A manifest that missed its size budget mentions the miss, with both numbers")
func exportSummaryReportsAMissedBudget() throws {
    let manifest = ExportManifest(outputPath: "/tmp/demo.mp4", format: "mp4",
                                  byteSize: 9_000_000, durationSeconds: 10,
                                  width: 100, height: 100, scale: 1.0,
                                  maxSizeBytes: 5_000_000, maxSizeMet: false)
    let text = exportSummary(manifest)
    #expect(text.contains("9.0 MB"))
    #expect(text.contains("5.0 MB"))
    #expect(text.lowercased().contains("over budget")
         || text.lowercased().contains("miss"))
}

@Test("A manifest with no size target mentions no budget at all")
func exportSummaryStaysSilentWithNoTarget() throws {
    let manifest = ExportManifest(outputPath: "/tmp/demo.mp4", format: "mp4",
                                  byteSize: 9_000_000, durationSeconds: 10,
                                  width: 100, height: 100, scale: 1.0)
    let text = exportSummary(manifest)
    #expect(!text.lowercased().contains("budget"))
}

@Test("A manifest that met its size budget mentions no miss")
func exportSummaryStaysSilentWhenMet() throws {
    let manifest = ExportManifest(outputPath: "/tmp/demo.mp4", format: "mp4",
                                  byteSize: 3_000_000, durationSeconds: 10,
                                  width: 100, height: 100, scale: 1.0,
                                  maxSizeBytes: 5_000_000, maxSizeMet: true)
    let text = exportSummary(manifest)
    #expect(!text.lowercased().contains("over budget"))
}

/// Mirrors `Tests/SnittCLITests` coverage of the same rendering job for the
/// MCP frontend (§4.8): the text an agent reads back must say where the
/// file went and roughly what it contains, not just "done".
@Test("The diagnostics summary names the path and roughly what the bundle contains")
func diagnosticsSummaryDescribesTheBundle() {
    let report = DiagnosticsReport(
        appVersion: "1.2.3",
        protocolVersion: 2,
        generatedAt: Date(),
        permissions: ["screenRecording": "granted", "inputMonitoring": "not granted"],
        recentSessions: [
            AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent", startedAt: Date()),
        ],
        logLines: ["[com.snitt/automation] hello"])

    let text = diagnosticsSummary(report, outputPath: "/tmp/diagnostics.json")

    // The discriminating assertions: a renderer that ignores its arguments
    // and always prints a fixed "Wrote diagnostics bundle" string would
    // pass a bare non-emptiness check, but would tell a person nothing they
    // could use to sanity-check the export.
    #expect(text.contains("/tmp/diagnostics.json"))
    #expect(text.contains("1"), "the session count must appear")
    #expect(text.contains("1.2.3"))
    #expect(text.contains("granted"))
}

/// Guards §12's "off vs none found" promise at the text an MCP client
/// actually reads: `diagnosticsSummary` had no coverage of this distinction
/// before this pair of tests, so a renderer collapsing "we weren't looking"
/// into "nothing crashed" would have shipped invisibly.
@Test("With crash reporting off, the MCP summary says so, not \"0 crash reports\"")
func diagnosticsSummarySaysOffWhenDisabled() throws {
    // Discriminates against the exact mutant the review named: hardcoding
    // `"\(report.crashReports.count) crash report(s)"` unconditionally, which
    // renders "0 crash report(s)" here — indistinguishable from "opted in,
    // found nothing".
    let report = DiagnosticsReport(
        appVersion: "1.2.3", protocolVersion: 2, generatedAt: Date(),
        permissions: [:], recentSessions: [], logLines: [],
        crashReportingEnabled: false, crashReports: [])

    let text = diagnosticsSummary(report, outputPath: "/tmp/diagnostics.json")

    #expect(text.lowercased().contains("off"),
            "the summary must say collection was off")
    #expect(!text.contains("0 crash report"),
            "\"0 crash report(s)\" is indistinguishable from \"nothing crashed\" and must not appear when collection was off")
}

@Test("With crash reporting on, the MCP summary gives a count, not \"off\"")
func diagnosticsSummaryGivesCountWhenEnabled() throws {
    let report = DiagnosticsReport(
        appVersion: "1.2.3", protocolVersion: 2, generatedAt: Date(),
        permissions: [:], recentSessions: [], logLines: [],
        crashReportingEnabled: true, crashReports: [])

    let text = diagnosticsSummary(report, outputPath: "/tmp/diagnostics.json")

    #expect(text.contains("0 crash report"),
            "collection was ON and found none — that is a different state from \"off\" and must say so")
    #expect(!text.lowercased().contains("crash reporting off"))
}
