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
/// decides whether an update applies by comparing the appcast against
/// `CFBundleShortVersionString`, so an app that REPORTS one version and IS
/// another produces "updates sometimes don't appear" — a symptom with no
/// error attached to it. §10 already treats version skew as first-class for
/// the CLI; this is the same hazard one layer down.
public enum AppVersion {
    /// The value baked into the binary, and the single source
    /// `Scripts/make-app.sh` reads when writing `CFBundleShortVersionString`.
    /// Bump this and the plist follows; there is nowhere else to edit.
    public static let fallback = "0.1.0"

    public static var current: String {
        // No bundle under `swift test` or in `snitt-cli`. An empty string
        // here would reach a diagnostics bundle as "unknown build".
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallback
    }
}
