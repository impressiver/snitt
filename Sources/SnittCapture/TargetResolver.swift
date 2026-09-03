import Foundation

public enum TargetResolutionError: Error, Equatable {
    /// The human dismissed the picker without choosing.
    case cancelled
    /// No previously-approved target exists to reuse.
    case noCachedTarget
    /// A cached target's application is no longer running or has no windows.
    case targetGone(String)
    /// The application IS running with windows on screen, but none of them
    /// clears `CachedTargetResolver.minimumWindowEdge`.
    ///
    /// Distinct from `targetGone` because the two need opposite advice. Folding
    /// this into "no longer available" tells an agent its running app is not
    /// running, so it retries or gives up instead of resizing the window or
    /// recording a display.
    case targetTooSmall(String)
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
