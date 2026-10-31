// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Names a bundle after the work it documents (§7), and after what was filmed.
///
/// "A demo arrives as `feature-branch-a1b2c3.snitt` rather than
/// `Screen Recording 2026-09-02.mov`."
///
/// **The recorded window's TITLE is deliberately not here, and must not be
/// added.** The app's name is; the title is not. The difference is not
/// squeamishness, it is this codebase's existing, documented position on that
/// one field:
///
/// - `RecordingCoordinator.openEditor(for:)` already redacts THIS FILENAME
///   from its error messages, because the name embeds the git branch and "a
///   branch called `feat/acme-corp-integration` would name a customer or an
///   unreleased feature" in a line "collected verbatim into `snitt
///   diagnostics export`, which people attach to public support threads". The
///   same comment records a MEASURED leak of this filename through
///   `NSError.userInfo`'s `NSFilePath`. So the filename is a known leak
///   surface that has already had to be patched once.
/// - `DiagnosticsBundle.redactingTarget` replaces the window title with a
///   per-export SALTED hash on the export path, because "§5.1's own worked
///   example of why window-scoping matters is a window titled 'Mail Password
///   Required' — exactly the kind of string this bundle promises never to
///   carry". `DiagnosticsBundleTests` pins that promise.
/// - `RecordingMetadata` carries no title field at all, so the title is not
///   inside the bundle either.
///
/// A length cap would not have helped: it shortens a title, it does not
/// de-identify one, and "Mail Password Required" is 23 characters. An
/// application name ("Safari", "Xcode") is a fixed, low-entropy string drawn
/// from a short list of installed apps, which is why it is safe here and the
/// title is not.
public enum BundleNaming {
    /// Keeps room for the ".snitt" extension and any future suffix within
    /// macOS's ~255-byte filename limit. A branch name over this would
    /// otherwise make `SnittBundle(creatingAt:)` throw an obscure filesystem
    /// error instead of a name Snitt could simply have prevented.
    private static let maxAssembledLength = 200

    /// The application's own allowance, so a pathological `applicationName`
    /// cannot eat the branch's entire budget.
    ///
    /// Capped rather than trusted: `applicationName` is a plain `String` off
    /// `SCRunningApplication`, not a known-short identifier like a commit, and
    /// nothing in ScreenCaptureKit promises it is reasonable. Forty characters
    /// fits every real app name on a Mac with room to spare, and the cap only
    /// ever bites on something absurd.
    private static let maxAppLength = 40

    /// The timestamp is ALWAYS part of the name, git context or not.
    ///
    /// It used to appear only in the no-git fallback, which made the name a
    /// pure function of branch+commit. `outputDirectory` is fixed and
    /// `SnittBundle(creatingAt:)` throws `.alreadyExists`, so the ordinary
    /// edit-review-retry loop — record, stop, record again without
    /// committing — failed permanently with an internal error naming a
    /// filesystem enum, until a human moved the first bundle out of the way.
    /// Two recordings of the same commit are the normal case, not a
    /// collision to be reported.
    ///
    /// `app` defaults to nil, and with it nil this returns BYTE-IDENTICAL
    /// names to the version before the app name existed — pinned by
    /// `noApplicationIsByteIdenticalToTheOldName`. A display recording, or
    /// any caller that cannot name an application, keeps the name it had.
    public static func filename(app: String? = nil,
                                git: GitContext?,
                                timestamp: Int) -> String {
        let suffix = "-\(timestamp)"
        let budget = maxAssembledLength - suffix.utf8.count

        // LABELLED FIELDS, NOT A POSITIONAL ARRAY, and that is the whole
        // reason this function was restructured rather than extended.
        //
        // The budget arithmetic used to index a two-slot `[branch, commit]`
        // array and branch on `parts.count == 2`, truncating `parts[0]`. That
        // was correct only while there were exactly two optional components.
        // Prepending the app made `parts[0]` the APP, so the rule this
        // function documents — truncate the branch, never the commit — would
        // have silently become "truncate the app" and shredded the app name
        // while a 400-character branch sailed through untouched.
        // `longBranchTruncatesBeforeTheApplication` is the regression test;
        // it is the only test in the file that a revert to positional
        // truncation fails.
        let appPart = applicationPart(app)
        let commitPart = git?.commit.map(sanitize).flatMap(nonEmpty)
        let branchPart = git?.branch.map(sanitize).flatMap(nonEmpty)

        guard appPart != nil || commitPart != nil || branchPart != nil else {
            return "Snitt\(suffix).snitt"
        }

        // The branch is the only truncatable field, so everything else is
        // fixed cost and the branch gets what is left. Ordered app, branch,
        // commit: the app says what you were looking at, and the commit stays
        // adjacent to the timestamp where it reads as provenance.
        let fixed = [appPart, commitPart].compactMap { $0 }
        let fixedBytes = fixed.reduce(0) { $0 + $1.utf8.count }
        // One separator per fixed field once the branch joins them, which is
        // also exactly `fixed.count` when the branch is absent and one of the
        // joins disappears with it.
        let allowance = max(0, budget - fixedBytes - fixed.count)

        // `prefix` counts Characters while the budget is in UTF-8 bytes, so a
        // multi-byte branch name can still exceed `budget` here. That slack
        // is pre-existing and deliberate — the figure is a safety margin
        // under 255, not an exact quota — and `finalClamp` below is what
        // keeps it inside the filesystem's actual limit.
        let branch = branchPart.map { String($0.prefix(allowance)) }.flatMap(nonEmpty)

        let assembled = [appPart, branch, commitPart].compactMap { $0 }.joined(separator: "-")

        // A LEADING dot is stripped separately from the general sanitisation
        // below: dots are fine inside a name ("release.2", "v1.2"), but a
        // branch called ".hidden-wip" would produce a dot-prefixed bundle
        // that Finder and `ls` hide — the CLI would report success, print a
        // path, and the user would see nothing where their recording should
        // be. Applied to the ASSEMBLED name, not per-part, so ".hidden"
        // joined with a commit is still caught.
        //
        // The literal ".." is not a risk here: the timestamp and ".snitt" are
        // always appended after this strip, so the assembled name can never
        // BE ".." — only ever start with it as a substring, which is exactly
        // what this trims away.
        //
        // Leading hyphens go with the dots. `sanitize` turns any character it
        // does not allow into "-", so a branch named "." or "/wip" assembles
        // to a name beginning with a hyphen — harmless to the filesystem, but
        // a leading "-" makes the bundle awkward to pass to any command line.
        let unhidden = String(assembled.drop { $0 == "." || $0 == "-" })

        let name = unhidden.isEmpty ? "Snitt" : String(unhidden.prefix(budget))
        return name + suffix + ".snitt"
    }

    /// The application's contribution, or nil when it has none to make.
    ///
    /// Hyphen runs are collapsed HERE and nowhere else, deliberately. A real
    /// app name does produce them — "Adobe Photoshop (Beta)" sanitises to
    /// "Adobe-Photoshop--Beta-", a double hyphen and a trailing one — and
    /// both are ugly in a name a human reads in Finder. Branch and commit are
    /// left exactly as they were so that an `app: nil` call still returns the
    /// old bytes; collapsing globally would have quietly renamed every
    /// recording whose branch contained a run, which is a change nobody
    /// asked for.
    private static func applicationPart(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = collapsingHyphens(sanitize(raw))
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return nonEmpty(String(trimmed.prefix(maxAppLength)))
    }

    private static func collapsingHyphens(_ raw: String) -> String {
        var out = ""
        for character in raw where !(character == "-" && out.last == "-") {
            out.append(character)
        }
        return out
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    /// Branch names legitimately contain "/" and ":". The result is appended to
    /// a directory URL, so an unsanitised slash would target a subdirectory that
    /// does not exist rather than naming the bundle.
    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
