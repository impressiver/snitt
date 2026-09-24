// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Catches `Contents/MacOS/Snitt status` — the app binary run as if it were
/// the CLI.
///
/// **Why this is worse than an ordinary typo.** macOS volumes are
/// case-insensitive by default, so `Contents/MacOS/snitt` and
/// `Contents/MacOS/Snitt` are THE SAME FILE: the 11 MB AppKit application. The
/// CLI is a different binary, `Contents/Helpers/snitt`. Someone reaching for
/// the CLI at the obvious-looking path therefore gets a path that exists, is
/// executable, and runs — and then starts a run loop, prints nothing, and never
/// exits. Every instinct says the binary is right and the app is wedged.
///
/// It is not hypothetical. A caller building demo scripts lost hours to it,
/// filed a detailed bug report against the CLI, and could not see the help text
/// that would have answered the question — because `snitt help` was the app
/// binary too, printing nothing. Three of that report's four findings traced
/// back to this one trap.
///
/// A one-line refusal turns all of that into an instant, actionable message.
public enum CLIMisuse {
    /// Every verb the CLI accepts as its first argument.
    ///
    /// Shared with `CommandLineParser` rather than restated, because a copy
    /// would drift: a verb added there and missed here means the trap quietly
    /// comes back for exactly that verb.
    public static let verbs: Set<String> = [
        "help", "--help", "-h",
        "status", "targets", "record", "inspect", "recordings", "transcript",
        "editor", "overlays", "narrate", "trim", "setup", "crop", "estimate",
        "auto-deep-trim", "export", "diagnostics",
    ]

    /// What to print when `argv` is a CLI invocation aimed at the app binary,
    /// or `nil` when it is an ordinary app launch.
    ///
    /// Matches only on a KNOWN VERB in first position. The app is legitimately
    /// launched with arguments — `--launched-by-agent`, and whatever a debugger
    /// adds — and nothing about those looks like `status` or `record`. Matching
    /// loosely would turn this guard into its own trap, refusing to start the
    /// app somebody wanted.
    public static func complaint(forArguments argv: [String]) -> String? {
        guard argv.count > 1 else { return nil }
        let first = argv[1]
        guard verbs.contains(first) else { return nil }

        return """
        snitt: `\(first)` is a CLI command, and this is the Snitt application.

        They are two different binaries, and on a case-insensitive volume the \
        app answers to both spellings of its name:

          Contents/MacOS/Snitt       the app      (what you just ran)
          Contents/Helpers/snitt     the CLI      (what you want)

        Run `Contents/Helpers/snitt \(first)` instead. `snitt help` lists every \
        command.

        """
    }
}
