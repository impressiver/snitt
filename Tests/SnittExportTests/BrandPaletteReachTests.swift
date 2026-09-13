// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import SnittBrand

/// That the brand palette is reachable from the layer that draws exports.
///
/// This test being able to COMPILE is most of its value — it lives in
/// `SnittExportTests`, so if `SnittExport` ever loses its dependency on
/// `SnittBrand` the suite stops building rather than silently growing a second
/// copy of the colours somewhere.
struct BrandPaletteReachTests {

    @Test("Export can read the brand colours directly")
    func paletteIsVisibleFromExport() {
        // The reason the palette moved out of `SnittApp`: a burned-in overlay
        // is the one place a brand colour becomes permanent, and export could
        // not see them. The alternative was a second copy pinned by a test —
        // which `Scripts/generate-app-icon.swift` already needs, and one
        // guarded duplicate is a compromise while two is a pattern.
        #expect(SnittPalette.signal.alphaComponent == 1)
        #expect(SnittPalette.ink0.alphaComponent == 1)
    }

    @Test("The brand target depends on nothing")
    func brandHasNoDependencies() throws {
        // A palette that pulled in the document model would make every
        // consumer of a colour a consumer of `SnittDocument`, and the reason
        // it can sit under every layer is precisely that it sits under all of
        // them. Read from the manifest, because that is where the mistake
        // would be made.
        let manifest = try String(
            contentsOfFile: FileManager.default.currentDirectoryPath + "/Package.swift",
            encoding: .utf8)
        #expect(manifest.contains(".target(name: \"SnittBrand\"),"),
                "SnittBrand has gained dependencies, or was renamed")
        #expect(manifest.contains("\"SnittBrand\", \"SnittDocument\""),
                "SnittExport no longer depends on SnittBrand")
    }
}
