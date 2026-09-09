// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing

// Every Swift file carries the MPL Exhibit A notice.
//
// This is not tidiness. MPL-2.0 is FILE-level copyleft: the obligations attach
// to "Covered Software", and Exhibit A is how a file declares itself covered.
// A file without the notice is arguably not covered at all — so a new file
// added without it silently opts that code out of the only protection the
// licence provides, and nothing else in the repo would notice.
//
// D92 chose MPL over GPL to keep Mac App Store distribution possible. That
// choice is only worth having if the file-level boundary is actually maintained,
// which is a mechanical property and therefore checkable.
@Suite
struct LicenseHeaderTests {
    private static let roots = ["Sources", "Tests"]
    private static let notice = "Mozilla Public"

    private static func swiftFiles() -> [String] {
        roots.flatMap { root -> [String] in
            let files = FileManager.default.enumerator(atPath: root)?
                .compactMap { $0 as? String }
                .filter { $0.hasSuffix(".swift") } ?? []
            return files.map { "\(root)/\($0)" }
        }
    }

    @Test("The scan finds the source tree at all")
    func scanFindsFiles() {
        // Without this the suite passes vacuously if the roots move or the
        // enumerator returns nothing — a green test that checked zero files,
        // which reads as coverage and is worse than no test.
        #expect(Self.swiftFiles().count > 200,
                "found \(Self.swiftFiles().count) Swift files; the scan has drifted")
    }

    @Test("Every Swift file declares itself Covered Software")
    func everyFileCarriesTheNotice() {
        let missing = Self.swiftFiles().filter { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return true }
            return !text.contains(Self.notice)
        }
        #expect(missing.isEmpty, """
            These files carry no MPL notice, so they are arguably not Covered \
            Software and the licence does not protect them: \(missing.sorted()).
            Add the Exhibit A header (see any existing file) rather than \
            deleting this test.
            """)
    }

    @Test("The repository ships the licence the headers point at")
    func licenceFileExists() throws {
        // Exhibit A says "If a copy of the MPL was not distributed with this
        // file, You can obtain one at..." — the notice is honest only if the
        // copy really is distributed. A header pointing at a LICENSE that was
        // never committed is the failure this catches.
        let licence = try String(contentsOfFile: "LICENSE", encoding: .utf8)
        #expect(licence.contains("Mozilla Public License Version 2.0"))
        #expect(licence.contains("Exhibit A - Source Code Form License Notice"))
    }
}
