// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

private func makeTempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
}

@Test("Creating a bundle makes a directory with the expected layout")
func createsBundleLayout() throws {
    let url = makeTempURL()
    let bundle = try SnittBundle(creatingAt: url)
    defer { try? FileManager.default.removeItem(at: url) }

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
    #expect(isDir.boolValue)

    #expect(bundle.captureURL.lastPathComponent == "capture.mov")
    #expect(bundle.eventsURL.lastPathComponent == "events.json")
    #expect(bundle.editURL.lastPathComponent == "edit.json")
    #expect(bundle.metaURL.lastPathComponent == "meta.json")
    #expect(bundle.posterURL.lastPathComponent == "poster.png")
}

@Test("Creating a bundle where one already exists throws")
func refusesToOverwrite() throws {
    let url = makeTempURL()
    _ = try SnittBundle(creatingAt: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: SnittBundleError.alreadyExists) {
        _ = try SnittBundle(creatingAt: url)
    }
}

@Test("Opening a path that is not a directory throws")
func rejectsNonDirectory() throws {
    let url = makeTempURL()
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: SnittBundleError.notADirectory) {
        _ = try SnittBundle(opening: url)
    }
}

@Test("Creating a bundle under a nonexistent parent throws rather than fabricating it")
func refusesToCreateMissingParents() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let nested = parent
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    defer { try? FileManager.default.removeItem(at: parent) }

    #expect(throws: (any Error).self) {
        _ = try SnittBundle(creatingAt: nested)
    }
    #expect(!FileManager.default.fileExists(atPath: parent.path))
}
