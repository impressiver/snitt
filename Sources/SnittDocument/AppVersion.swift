// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The app's version, in one place.
///
/// It lived in three: `SnittDocument.version`, a literal in
/// `AutomationHost`, and another in `make-app.sh`'s Info.plist. Sparkle
/// decides whether an update applies by comparing versions, so an app that
/// REPORTS one version and IS another produces "updates sometimes don't
/// appear" — a symptom with no error attached to it. §10 already treats
/// version skew as first-class for the CLI; this is the same hazard one
/// layer down.
///
/// **Two versions, deliberately disjoint.** They used to be one string in
/// both plist keys, which made it impossible for `main` to carry anything
/// other than the version last released: a bare next-version there
/// (`0.5.0`) would make every development build claim to BE 0.5.0, and
/// Sparkle would then refuse the real 0.5.0 when it shipped — 0.5.0 is not
/// newer than 0.5.0. Marking it (`0.5.0-dev`) fixes the claim and breaks
/// the comparison instead, because Sparkle asks that the version it compares
/// be strictly numeric and says to keep a human-readable string disjoint
/// from it. So they are now disjoint, which is Sparkle's own advice:
///
/// - `marketing` — what a person reads. May carry a pre-release marker.
/// - `CFBundleVersion` — what Sparkle compares. A monotonic build number
///   stamped by `Scripts/make-app.sh` from the commit count, never edited by
///   hand, and always larger on a later build than an earlier one.
public enum AppVersion {
    /// The human-readable version, and the single source
    /// `Scripts/make-app.sh` reads when writing `CFBundleShortVersionString`.
    ///
    /// Between releases this carries a `-dev` marker and the NEXT version —
    /// `Scripts/release.sh` sets it there after publishing, so `main` never
    /// claims a version that has already shipped. On a release commit it is
    /// the bare version. Bump it and the plist follows; there is nowhere
    /// else to edit.
    public static let marketing = "0.6.0-dev"

    /// The old name. Kept so `make-app.sh`, `release.sh` and their tests
    /// keep matching on one spelling while the meaning is documented above.
    public static var fallback: String { marketing }

    /// What Sparkle actually compares — the monotonic build number, or "0"
    /// with no bundle. Surfaced so a diagnostics bundle can say which BUILD a
    /// report came from, which `marketing` cannot answer once it carries
    /// `-dev` for every commit between two releases.
    public static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0"
    }

    public static var current: String {
        // No bundle under `swift test` or in `snitt-cli`. An empty string
        // here would reach a diagnostics bundle as "unknown build".
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? marketing
    }
}
