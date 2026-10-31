// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// Where an export lands, and what happens when that folder is gone.
///
/// **This reverses a documented decision, deliberately and on the product
/// owner's direction.** `EditorWindowController.defaultExportURL` used to put
/// the export beside the bundle, and said why: *"Beside rather than in Movies
/// or Downloads because a `.snitt` bundle already lives where its owner put
/// it, and the export belongs with the thing it was made from."*
/// `SettingsWindowController` repeated the claim from the other side.
/// Both comments are updated by this change rather than left to rot, because
/// a reversed decision whose comment still argues the old way is
/// indistinguishable from a bug.
@Suite(.serialized)
struct LastExportDirectoryTests {

    /// A defaults domain per test, so one test's stored folder cannot decide
    /// another's result and neither can the developer's real preferences.
    private func scratchDefaults() -> UserDefaults {
        let suite = "com.impressiver.snitt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("With nothing remembered, an export defaults to ~/Downloads")
    func absentKeyReadsAsDownloads() {
        let loaded = LastExportDirectory.load(scratchDefaults())
        #expect(loaded.directory == LastExportDirectory.defaultDirectory)
        #expect(loaded.directory.lastPathComponent == "Downloads")
    }

    @Test("A remembered folder survives a round trip")
    func roundTrips() {
        let defaults = scratchDefaults()
        let folder = URL(fileURLWithPath: "/Users/somebody/Desktop/demos")
        LastExportDirectory(directory: folder).save(to: defaults)
        #expect(LastExportDirectory.load(defaults).directory == folder)
    }

    @Test("An empty or non-string stored value reads as the default")
    func corruptStoredValueReadsAsDefault() {
        // The same discriminator `OutputDirectorySettings.load` gives its own
        // reasoning for: `string(forKey:)` returns nil both when the key was
        // never written and when what is stored is not a String, so absent
        // and invalid fall through to one default rather than one of them
        // coercing into something else.
        let defaults = scratchDefaults()
        defaults.set("", forKey: LastExportDirectory.directoryKeyForTesting)
        #expect(LastExportDirectory.load(defaults).directory
                == LastExportDirectory.defaultDirectory)

        defaults.set(["not", "a", "path"], forKey: LastExportDirectory.directoryKeyForTesting)
        #expect(LastExportDirectory.load(defaults).directory
                == LastExportDirectory.defaultDirectory)
    }

    // MARK: - Resolving a folder that may no longer be there

    @Test("A writable remembered folder resolves to itself, with nothing substituted")
    func writableFolderIsUsed() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let resolved = LastExportDirectory.resolve(remembered: folder)
        #expect(resolved.directory == folder)
        #expect(resolved.unavailable == nil,
                "nothing was substituted, so the sheet has nothing to report")
    }

    @Test("A missing remembered folder falls back AND names what it replaced")
    func missingFolderFallsBackVisibly() {
        // The visibility is the whole ruling. `RecordingCoordinator`'s
        // `prepareOutputDirectory` refuses rather than redirecting, and says
        // why: "A person who deliberately pointed recordings at, say, an
        // unmounted external volume would be badly surprised — possibly days
        // later — to learn recordings had quietly been landing on the
        // internal disk instead."
        //
        // Export differs in one respect that makes a fallback acceptable: the
        // destination is shown in the sheet BEFORE anything is written, so it
        // can be corrected. But `ExportSheet` renders only the folder's
        // `lastPathComponent`, so a silent fallback displays "Downloads" and
        // is indistinguishable from having chosen Downloads. Hence
        // `unavailable`: the fallback is allowed precisely because it is
        // reported, and this is the test that keeps it reported.
        let gone = URL(fileURLWithPath: "/Volumes/NoSuchVolume/demos")
        let resolved = LastExportDirectory.resolve(remembered: gone)
        #expect(resolved.directory == LastExportDirectory.defaultDirectory)
        #expect(resolved.unavailable == gone,
                "a silent substitution is the failure mode this field exists to prevent")
    }

    @Test("A file where the folder should be is treated as unavailable")
    func aFileIsNotAFolder() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let resolved = LastExportDirectory.resolve(remembered: file)
        #expect(resolved.directory == LastExportDirectory.defaultDirectory)
        #expect(resolved.unavailable == file)
    }

    @Test("An unwritable remembered folder falls back")
    func unwritableFolderFallsBack() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        let resolved = LastExportDirectory.resolve(remembered: folder)
        #expect(resolved.directory == LastExportDirectory.defaultDirectory)
        #expect(resolved.unavailable == folder)
    }

    @Test("The fallback itself is never reported as a substitution of itself")
    func fallbackIsNotItsOwnSubstitute() {
        // Nothing was taken away, so there is nothing to tell the user. Were
        // this to report a substitution, every export on a fresh install
        // would open the sheet carrying a warning about ~/Downloads being
        // unavailable while writing to it perfectly well.
        let resolved = LastExportDirectory.resolve(
            remembered: LastExportDirectory.defaultDirectory)
        #expect(resolved.unavailable == nil)
    }

    // MARK: - The name the export gets

    @Test("An export is named after the recording, inside the resolved folder")
    @MainActor
    func exportIsNamedAfterTheRecordingInTheChosenFolder() {
        // The REPLACEMENT for `defaultDestinationSitsBesideTheBundle`, which
        // pinned the reversed decision. The part that must survive the
        // reversal is the part that was never about the folder: a `.snitt` IS
        // a directory, so `appendingPathComponent` on it compiles, runs, and
        // writes the export INSIDE the document bundle, where the next open
        // would find a stray movie beside `capture.mov`.
        let bundle = URL(fileURLWithPath: "/Users/somebody/Documents/Snitt/Standup.snitt")
        let folder = URL(fileURLWithPath: "/Users/somebody/Downloads")
        let export = EditorWindowController.defaultExportURL(forBundle: bundle, in: folder)
        #expect(export.path == "/Users/somebody/Downloads/Standup.mp4")
        #expect(!export.path.contains(".snitt"),
                "the export must never land inside the bundle it came from")
    }

    @Test("A bundle and a folder that coincide still name the export correctly")
    @MainActor
    func exportBesideTheBundleStillWorks() {
        // The old behaviour is now simply one case of the new one: point the
        // folder at the bundle's own parent and you get the pre-change path.
        // Kept as a test because that equivalence is what makes this a
        // generalisation rather than a different feature.
        let bundle = URL(fileURLWithPath: "/Users/somebody/Desktop/Standup.snitt")
        let export = EditorWindowController.defaultExportURL(
            forBundle: bundle, in: bundle.deletingLastPathComponent())
        #expect(export.path == "/Users/somebody/Desktop/Standup.mp4")
    }
}

/// The wording the sheet uses when the remembered folder was not there.
///
/// `@MainActor` because `ExportSheet` is a SwiftUI `View` and so is
/// main-actor isolated, which makes `unavailableNote` isolated too. Stated
/// rather than inferred: the local toolchain (Swift 6.4) accepted the
/// un-annotated suite and CI's macos-26 runner rejected it with
/// "call to main actor-isolated static method ... in a synchronous
/// nonisolated context". Explicit is the fix, not a toolchain pin.
@Suite
@MainActor
struct ExportUnavailableNoteTests {

    @Test("No substitution means no note")
    func noNoteWhenNothingWasSubstituted() {
        #expect(ExportSheet.unavailableNote(for: nil) == nil)
    }

    @Test("The note names the FULL path of what went missing")
    func theNoteNamesTheFullPath() {
        // The full path, not `lastPathComponent`. "demos is unavailable" is
        // useless when the folder you meant was `/Volumes/Archive/demos`, and
        // an unmounted volume is precisely the case this note exists for.
        let note = ExportSheet.unavailableNote(
            for: URL(fileURLWithPath: "/Volumes/Archive/demos"))
        #expect(note?.contains("/Volumes/Archive/demos") == true)
        #expect(note?.contains("Downloads") == true,
                "it must also say where the export is going instead")
    }
}
