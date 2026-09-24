// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

public enum TargetResolutionError: Error, Equatable {
    /// The human dismissed the picker without choosing.
    case cancelled
    /// No previously-approved target exists to reuse.
    case noCachedTarget
    /// A cached target's application is no longer running or has no windows.
    case targetGone(String)
    /// The application has SEVERAL recordable windows and nothing chose between
    /// them. Carries their ids and titles so the caller can name one.
    ///
    /// Refusing rather than guessing is the whole point: the largest-window
    /// rule silently recorded a private pull request when an agent asked for a
    /// Chrome window and ten were open. An error an agent can act on beats a
    /// recording of the wrong thing, which nobody discovers until they watch
    /// it — or worse, until they have already attached it to a PR.
    case ambiguousWindows(application: String, candidates: [AmbiguousWindow])

    /// One of the windows an ambiguous match could have meant.
    ///
    /// A named type rather than a tuple: a tuple payload blocks Equatable
    /// synthesis, and this error is compared in tests.
    public struct AmbiguousWindow: Equatable, Sendable {
        public let id: UInt32
        public let title: String?

        public init(id: UInt32, title: String?) {
            self.id = id
            self.title = title
        }
    }
    /// The application IS running with windows on screen, but none of them
    /// clears `CachedTargetResolver.minimumWindowEdge`.
    ///
    /// Distinct from `targetGone` because the two need opposite advice. Folding
    /// this into "no longer available" tells an agent its running app is not
    /// running, so it retries or gives up instead of resizing the window or
    /// recording a display.
    case targetTooSmall(String)
    /// A WINDOW ID was named and nothing on screen carries it.
    ///
    /// Its own case because the previous two could not express it, and the one
    /// it fell into said something false. `failure(for:among:)` asked only
    /// "does this app have any window on screen?" — so naming a stale or
    /// mistyped id for an app that is running and perfectly recordable produced
    /// `targetTooSmall`: "Chrome has no window larger than 100×100 to record",
    /// about an application with thirteen windows, followed by advice to resize
    /// one. Measured by a caller who then had nothing true to act on.
    ///
    /// Carries the id, because "which one" is the whole question, and the
    /// remedy is to list targets again rather than to resize anything.
    case windowNotFound(id: UInt32, app: String)
    /// The picker is unavailable on this system.
    case unavailable
}

/// Produces a target ready to record.
///
/// Two conformers exist: `PickerTargetResolver` (interactive, human-driven) and
/// `CachedTargetResolver` (re-resolves a stored reference). Callers depend on
/// this protocol so they can be tested without picker UI or a real screen.
public protocol TargetResolver: Sendable {
    func resolve() async throws -> ResolvedTarget
}
