// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Everything the welcome window DECIDES, with none of the AppKit it decides
/// it for.
///
/// Same split `LaunchOpenPrompt` and `DockReopen` already use, and for the
/// same reason: the window itself cannot be exercised in a headless test, so
/// the judgements move out to where they can be. This type is deliberately
/// NOT `@MainActor` — nothing here touches UI, and isolating it would drag
/// every caller onto the main actor for no safety benefit.
///
/// It also deliberately does no FORMATTING. `Entry.modified` is a `Date`, not
/// a string: "2 hours ago" is locale-dependent presentation and belongs to
/// the window, which can hand it to `RelativeDateTimeFormatter` and get the
/// user's own language for free. Testing a formatted string here would mean
/// pinning English.
enum WelcomeContent {

    // MARK: - What the left column says

    /// The window shows one or the other, never both.
    enum Guidance: Equatable {
        /// First run: how to make a recording at all.
        case gettingStarted
        /// Afterwards: one operational tip.
        case tip(String)
    }

    /// Derived from whether there is anything to show in the recents list,
    /// not from a "has launched before" flag.
    ///
    /// A flag set on first launch is spent the moment the window is shown,
    /// so closing it by reflex — or quitting and coming back before
    /// recording anything — loses the help permanently. Deriving it from
    /// state means the getting-started copy stays until the user has
    /// actually got started, which is the question it was there to answer.
    ///
    /// The consequence, accepted: deleting every recording puts the
    /// getting-started copy back. That reads as correct rather than as a
    /// bug — someone with no recordings is starting over.
    static func guidance(hasRecordings: Bool,
                         recordShortcut: String,
                         tipIndex: Int) -> Guidance {
        guard hasRecordings else { return .gettingStarted }
        let all = tips(recordShortcut: recordShortcut)
        // Modulo rather than a bounds check, so a caller can hand this a
        // monotonically increasing launch count and get rotation for free.
        return .tip(all[((tipIndex % all.count) + all.count) % all.count])
    }

    /// Tips teach a MOVE, never a capability.
    ///
    /// The test each one has to pass: it is useless to somebody who has not
    /// installed Snitt. "Select a phrase and those seconds are gone" fails
    /// that — it sells a feature to someone who already bought it. "Hold
    /// Shift to record without focusing" passes, because it is only
    /// actionable in front of the app.
    ///
    /// `recordShortcut` is interpolated rather than hardcoded because the
    /// hotkey is rebindable in Settings, so a literal ⌥⌘5 here would
    /// misreport it for anyone who changed it.
    static func tips(recordShortcut: String) -> [String] {
        [
            "Hold Shift with \(recordShortcut) to record a window without bringing it to the front.",
            "Auto-Trim takes out the dead air in one pass.",
            "Select a phrase in the transcript and press Delete to cut those seconds.",
            "Double-click a cut on the timeline to expand and select it.",
        ]
    }

    // MARK: - Recents

    /// One row in the recents list.
    struct Entry: Equatable {
        let url: URL
        /// The leading, most recognisable part of the bundle's name.
        let title: String
        /// Whatever the name carries after that — the git context, usually —
        /// or nil when the name has nothing more to give.
        let detail: String?
        let modified: Date
    }

    /// The recents list, filtered to bundles that still exist.
    ///
    /// **Existence filtering is new work, not a setting.**
    /// `NSDocumentController.recentDocumentURLs` keeps entries whose files
    /// have been moved or deleted, and `RecentDocuments` passes them through
    /// raw. A launch screen that offers a row which errors when clicked is
    /// worse than a shorter list.
    ///
    /// **Sorted by modification date, not by the order `recentDocumentURLs`
    /// returns.** That order is most-recently-OPENED, which on a list
    /// labelled with dates produces a visibly non-monotonic column — "2
    /// hours ago" above "Tuesday" above "Yesterday". Newest recording first
    /// is also the more useful order for recordings specifically.
    static func recents(from urls: [URL],
                        limit: Int = 4,
                        fileManager: FileManager = .default) -> [Entry] {
        let found: [Entry] = urls.compactMap { url in
            guard let modified = modificationDate(of: url, fileManager: fileManager) else {
                return nil
            }
            let parts = name(forStem: url.deletingPathExtension().lastPathComponent)
            return Entry(url: url, title: parts.title, detail: parts.detail, modified: modified)
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(max(0, limit)))
    }

    /// Nil when there is nothing at `url` any more.
    ///
    /// A `.snitt` is a DIRECTORY, so this asks for the attributes rather than
    /// using `fileExists(atPath:)` alone: one call answers both "is it still
    /// there" and "when was it last touched", and a bundle whose attributes
    /// cannot be read is one this list should not offer either way.
    private static func modificationDate(of url: URL,
                                         fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Splits a bundle's name into the bit worth reading first and the rest.
    ///
    /// `BundleNaming` assembles `App-branch-commit-timestamp`, so the leading
    /// component is the most recognisable thing in it and the timestamp is
    /// the least. This drops the timestamp and promotes the first component.
    ///
    /// **This couples the welcome list to `BundleNaming`'s shape, knowingly.**
    /// The alternative was reading every bundle's `meta.json` at launch for
    /// the git context, which is more I/O for the same answer and still
    /// could not supply the application name: `RecordingMetadata` carries
    /// `git`, `createdAt` and the pixel size, but deliberately no app name
    /// and no window title. So the name on disk is the only place the app is
    /// recorded, and parsing it is the cheap way to read it.
    ///
    /// Degrades rather than guesses. A name that does not match the shape —
    /// an imported video, a hand-renamed bundle, a display recording with no
    /// app component — comes back whole as the title. It cannot tell a
    /// display recording's leading BRANCH from an application name, and does
    /// not try: either way the first component is the useful one to lead
    /// with.
    static func name(forStem stem: String) -> (title: String, detail: String?) {
        var parts = stem.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return (stem, nil) }
        // Only a trailing all-digit run is the timestamp. A commit like
        // "a1b2c3d" is not, and neither is a branch named "v2".
        if let last = parts.last, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard let title = parts.first else { return (stem, nil) }
        let rest = parts.dropFirst()
        return (title, rest.isEmpty ? nil : rest.joined(separator: " · "))
    }

    // MARK: - Permissions

    /// One permission the window reports on.
    struct PermissionRow: Equatable {
        let service: PermissionOnboarding.Service
        let isGranted: Bool
        /// Whether allowing it in System Settings takes effect only on the
        /// NEXT launch.
        let requiresRelaunch: Bool
    }

    /// Which permissions this user's Snitt actually needs, and whether it has
    /// them.
    ///
    /// **Only what is relevant.** Screen Recording always, because nothing
    /// records without it. Microphone only when voiceover is switched on, and
    /// Input Monitoring only when input logging is — `PermissionOnboarding`'s
    /// own copy says as much ("You turned on voiceover, so…"). Listing all
    /// three unconditionally would show a fresh install two warnings for
    /// features nobody enabled.
    ///
    /// **The window READS this and never acts on it.** `PermissionLadder`
    /// reserves asking for "first use of the feature that needs it — never at
    /// launch", so the welcome window's only move is to report status and
    /// link to Settings. Note that Snitt itself does ask, at first use:
    /// `RecordingCoordinator.startRecording` ensures access before it films,
    /// and the Settings toggles run the full ladder.
    static func permissionRows(screenRecordingGranted: Bool,
                               microphoneGranted: Bool,
                               inputMonitoringGranted: Bool,
                               microphoneEnabled: Bool,
                               inputLoggingEnabled: Bool) -> [PermissionRow] {
        var rows = [
            // Screen Recording and Input Monitoring both land on the next
            // launch — spike S5 measured `CGRequestScreenCaptureAccess()`
            // returning false while the user was granting, and both access
            // types document it. Microphone does not: AVFoundation reports
            // authorization live, so a grant shows up on the next read.
            PermissionRow(service: .screenRecording,
                          isGranted: screenRecordingGranted,
                          requiresRelaunch: true),
        ]
        if microphoneEnabled {
            rows.append(PermissionRow(service: .microphone,
                                      isGranted: microphoneGranted,
                                      requiresRelaunch: false))
        }
        if inputLoggingEnabled {
            rows.append(PermissionRow(service: .inputMonitoring,
                                      isGranted: inputMonitoringGranted,
                                      requiresRelaunch: true))
        }
        return rows
    }

    /// Whether the window shows the permission section at all.
    ///
    /// Nothing missing means no section: a healthy launch should carry no
    /// permission UI, not a row of green ticks. The granted rows are still
    /// worth showing ALONGSIDE a missing one, so the picture is complete
    /// exactly when it matters.
    static func needsAttention(_ rows: [PermissionRow]) -> Bool {
        rows.contains { !$0.isGranted }
    }
}
