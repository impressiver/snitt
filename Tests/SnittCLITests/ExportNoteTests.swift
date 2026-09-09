// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_cli
import SnittDocument

/// Guards finding #1 of the M3d fix wave: the CLI's `emit(manifest)` prints
/// the JSON, where `maxSizeMet: false` is present and honest, but the
/// human-readable stderr line an agent (or a person piping stderr to a log)
/// actually reads said nothing about a missed size budget at all — the exact
/// silent-success collapse §8 exists to prevent, reintroduced one layer above
/// `ExportManifest` itself.
@Test("A manifest that missed its size budget mentions the miss, with both numbers")
func exportNoteReportsAMissedBudget() throws {
    // Discriminates against the pre-fix implementation, which built its note
    // from `outputPath` and `byteSize` alone and never looked at
    // `maxSizeMet`/`maxSizeBytes` — that implementation produces a note with
    // no "over budget" text and no mention of 5.0 MB, and this test fails
    // against it.
    let manifest = ExportManifest(outputPath: "/tmp/demo.mp4", format: "mp4",
                                  byteSize: 9_000_000, durationSeconds: 10,
                                  width: 100, height: 100, scale: 1.0,
                                  maxSizeBytes: 5_000_000, maxSizeMet: false)
    let note = exportNote(manifest)
    #expect(note.contains("9.0 MB"))
    #expect(note.contains("5.0 MB"))
    #expect(note.lowercased().contains("over budget")
         || note.lowercased().contains("miss"),
            "the note must say something happened, not just repeat the numbers silently")
}

@Test("A manifest with no size target mentions no budget at all")
func exportNoteStaysSilentWithNoTarget() throws {
    // Discriminates against an implementation that always appends a budget
    // clause (e.g. checking `byteSize <= maxSizeBytes` with a force-unwrap
    // default), which would crash or print a nonsensical "over budget: X >
    // nil" for the overwhelming majority of exports that never asked for a
    // size target at all.
    let manifest = ExportManifest(outputPath: "/tmp/demo.mp4", format: "mp4",
                                  byteSize: 9_000_000, durationSeconds: 10,
                                  width: 100, height: 100, scale: 1.0)
    let note = exportNote(manifest)
    #expect(!note.lowercased().contains("budget"))
    #expect(!note.lowercased().contains("mb requested"))
}

@Test("A manifest that met its size budget mentions no miss")
func exportNoteStaysSilentWhenMet() throws {
    let manifest = ExportManifest(outputPath: "/tmp/demo.mp4", format: "mp4",
                                  byteSize: 3_000_000, durationSeconds: 10,
                                  width: 100, height: 100, scale: 1.0,
                                  maxSizeBytes: 5_000_000, maxSizeMet: true)
    let note = exportNote(manifest)
    #expect(!note.lowercased().contains("over budget"))
}
