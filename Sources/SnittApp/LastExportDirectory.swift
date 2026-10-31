// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The folder the last export was written to, so the next one starts there.
///
/// **This reverses a documented decision.** `defaultExportURL` used to put an
/// export beside its bundle, arguing *"a `.snitt` bundle already lives where
/// its owner put it, and the export belongs with the thing it was made
/// from"*, and `SettingsWindowController`'s "Recordings folder" comment
/// repeated the claim from the other side. Both are rewritten by this change.
/// The reversal is the product owner's, and the reasoning that replaced it is
/// simpler: an export is a file you are about to do something ELSE with —
/// attach it, upload it, drag it into a message — and `~/Downloads` is where
/// the rest of that traffic already lands. Where the bundle lives stopped
/// being the interesting question once the export stopped being an archive.
///
/// **Remembered, not configured, and that is a deliberately smaller
/// promise.** This is not a sibling of `OutputDirectorySettings`: there is no
/// Settings row, nothing to choose up front, and no claim that Snitt will put
/// exports anywhere in particular. It is a memory of what you last did, which
/// is why it is written on a SUCCESSFUL export rather than when a folder is
/// picked — choosing a folder and then cancelling the sheet expressed no
/// preference, and remembering it would make the next export start somewhere
/// the user never actually exported to.
///
/// Stored as a plain `String` path for the same reason
/// `OutputDirectorySettings` is: Snitt is not sandboxed, so there is no
/// security scope to resume and an ordinary path is all a non-sandboxed
/// process needs.
public struct LastExportDirectory: Sendable, Equatable {
    public var directory: URL

    private static let directoryKey = "com.impressiver.snitt.lastExportDirectory"

    /// Test seam: the key, so a test can plant a corrupt value under it
    /// rather than asserting against a string it has duplicated.
    static var directoryKeyForTesting: String { directoryKey }

    /// `~/Downloads`, resolved through `FileManager` rather than built from
    /// the home directory by hand.
    ///
    /// `OutputDirectorySettings.defaultDirectory` builds its path by
    /// appending to `homeDirectoryForCurrentUser`, which is right for it
    /// because `Documents/Snitt` is a folder Snitt invents. Downloads is a
    /// folder the SYSTEM owns and the user can relocate, so asking
    /// `FileManager` is the only way to get the real one. Re-made with the
    /// plain `URL(fileURLWithPath:)` initialiser from the answer's `path`,
    /// because `urls(for:in:)` hands back a directory-hinted URL that
    /// compares unequal — via `URL`'s own `Equatable` — to the same folder
    /// named without the hint, including the one `NSOpenPanel` returns. That
    /// is the identical trap `OutputDirectorySettings.load` documents, met
    /// from the other direction.
    public static let defaultDirectory: URL = {
        let resolved = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
        return URL(fileURLWithPath: resolved.path)
    }()

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory
    }

    public static func load(_ defaults: UserDefaults = .standard) -> LastExportDirectory {
        guard let path = defaults.string(forKey: directoryKey), !path.isEmpty else {
            return LastExportDirectory()
        }
        return LastExportDirectory(directory: URL(fileURLWithPath: path))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(directory.path, forKey: Self.directoryKey)
    }

    /// The folder an export should default to, and the folder that was taken
    /// away when one was.
    ///
    /// **Falls back, where `RecordingCoordinator.prepareOutputDirectory`
    /// refuses, and the difference is reported visibility rather than a
    /// different opinion about surprise.** That function will not substitute
    /// a directory for recordings, because "a person who deliberately
    /// pointed recordings at, say, an unmounted external volume would be
    /// badly surprised — possibly days later — to learn recordings had
    /// quietly been landing on the internal disk instead". A recording is
    /// written with nobody watching; an export is chosen in a sheet that
    /// shows the destination first.
    ///
    /// But only just: `ExportSheet` renders the folder's `lastPathComponent`
    /// alone, so a bare fallback would display "Downloads" and be
    /// indistinguishable from having picked Downloads. `unavailable` is what
    /// closes that gap — the fallback is permitted BECAUSE the sheet says it
    /// happened. Drop the reporting and this becomes exactly the silent
    /// redirect the recording path refuses.
    ///
    /// Returns `nil` for `unavailable` when the remembered folder already IS
    /// the fallback, so a fresh install does not warn about `~/Downloads`
    /// while writing to it happily.
    public static func resolve(remembered: URL,
                               fallback: URL = defaultDirectory,
                               fileManager: FileManager = .default)
        -> (directory: URL, unavailable: URL?) {
        if isUsable(remembered, fileManager: fileManager) {
            return (remembered, nil)
        }
        // Nothing was taken away if the remembered folder was the fallback.
        let substituted = remembered == fallback ? nil : remembered
        return (fallback, substituted)
    }

    /// A folder that exists, is a directory, and can be written to.
    ///
    /// All three checked, not just existence: an unmounted volume's mount
    /// point can survive as an ordinary unwritable directory, and a path
    /// where a FILE now sits would otherwise pass an existence check and
    /// then fail at write time with the export already composed.
    private static func isUsable(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return fileManager.isWritableFile(atPath: url.path)
    }
}
