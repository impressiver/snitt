import Foundation
import ScreenCaptureKit

/// A window observed on screen right now, reduced to the fields matching needs.
///
/// Separated from `SCWindow` so the matching logic is pure and testable without
/// a real screen.
public struct WindowCandidate: Sendable, Equatable {
    public var windowID: UInt32
    public var bundleIdentifier: String?
    public var title: String?
    public var width: Int
    public var height: Int

    public init(windowID: UInt32, bundleIdentifier: String?,
                title: String?, width: Int, height: Int) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.width = width
        self.height = height
    }
}

/// Re-resolves a stored `TargetReference` against what is on screen now.
///
/// - Important: This is the bypass path. It calls `SCShareableContent`, which
///   incurs the macOS monthly re-consent prompt (§5.2). That is the accepted
///   cost of instant capture (§4.11) — there is no picker API that can replay a
///   prior selection (V12), so this is not an oversight to be optimised away.
public struct CachedTargetResolver: TargetResolver {
    private let reference: TargetReference

    public init(reference: TargetReference) {
        self.reference = reference
    }

    /// Below this, on either axis, a window is a palette or a utility panel
    /// rather than something worth recording.
    ///
    /// The agent path always passes `titleHint: nil` — `--app <bundle-id>` has
    /// no title to give — so without a floor an agent asking to record an app
    /// with a floating inspector could silently capture a 60×200 strip and be
    /// told it succeeded. Refusing is better: `target_not_found` is a fact the
    /// agent can act on, an unusable recording is not.
    static let minimumWindowEdge = 100

    /// Chooses the window that best matches a stored reference.
    ///
    /// Window ids are deliberately ignored: they change every relaunch (V10).
    /// Matching is by bundle identifier, with the title used only to
    /// disambiguate — a stale title falls back to the app's LARGEST window
    /// rather than failing, because recording the right app beats recording
    /// nothing.
    ///
    /// Largest, not first: `content.windows` order is ScreenCaptureKit's, not a
    /// ranking, so `first` meant "an arbitrary window of that app". Ties keep
    /// the earliest candidate, so the order is stable rather than dependent on
    /// how `max(by:)` breaks ties.
    static func bestMatch(for reference: TargetReference,
                          among candidates: [WindowCandidate]) -> WindowCandidate? {
        guard let bundleID = reference.bundleIdentifier else { return nil }
        let sameApp = candidates.filter {
            $0.bundleIdentifier == bundleID
                && $0.width >= minimumWindowEdge
                && $0.height >= minimumWindowEdge
        }
        guard let first = sameApp.first else { return nil }

        if let hint = reference.titleHint,
           let exact = sameApp.first(where: { $0.title == hint }) {
            return exact
        }
        return sameApp.dropFirst().reduce(first) { best, candidate in
            candidate.width * candidate.height > best.width * best.height
                ? candidate : best
        }
    }

    public func resolve() async throws -> ResolvedTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        switch reference.kind {
        case .display:
            guard let displayID = reference.displayID else {
                throw TargetResolutionError.targetGone("display (no id recorded)")
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                throw TargetResolutionError.targetGone("display \(displayID)")
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let size = filter.pixelDimensions
            return ResolvedTarget(
                filter: filter,
                descriptor: CaptureTargetDescriptor(
                    id: display.displayID,
                    kind: CaptureTargetDescriptor.Kind.display.rawValue,
                    title: "Display \(display.displayID)",
                    applicationName: nil,
                    width: size.width,
                    height: size.height
                ),
                reference: reference,
                provenance: .cache
            )

        case .window:
            let candidates = content.windows.map {
                WindowCandidate(windowID: $0.windowID,
                                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                                title: $0.title,
                                width: Int($0.frame.width),
                                height: Int($0.frame.height))
            }
            guard let match = Self.bestMatch(for: reference, among: candidates),
                  let window = content.windows.first(where: { $0.windowID == match.windowID })
            else {
                throw TargetResolutionError.targetGone(
                    reference.bundleIdentifier ?? "unknown application"
                )
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = filter.pixelDimensions
            return ResolvedTarget(
                filter: filter,
                descriptor: CaptureTargetDescriptor(
                    id: window.windowID,
                    kind: CaptureTargetDescriptor.Kind.window.rawValue,
                    title: window.title,
                    applicationName: window.owningApplication?.applicationName,
                    width: size.width,
                    height: size.height
                ),
                reference: reference,
                provenance: .cache
            )
        }
    }
}
