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
