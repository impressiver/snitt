// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import ScreenCaptureKit

/// A window observed on screen right now, reduced to the fields matching needs.
///
/// Separated from `SCWindow` so the matching logic is pure and testable without
/// a real screen.
public struct WindowCandidate: Sendable, Equatable {
    public var windowID: UInt32
    public var bundleIdentifier: String?
    public var applicationName: String?
    public var title: String?
    public var width: Int
    public var height: Int
    /// The owning application's pid. Carried here rather than re-read from the
    /// `SCWindow` at descriptor time so that the descriptor a recording is
    /// started with can be built — and checked — without a live display.
    public var processID: pid_t?

    /// `applicationName` and `processID` deliberately have NO defaults: the
    /// whole reason auto-focus was dead code is that a descriptor was built
    /// without a pid and nothing failed.
    public init(windowID: UInt32, bundleIdentifier: String?,
                applicationName: String?, title: String?,
                width: Int, height: Int, processID: pid_t?) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.width = width
        self.height = height
        self.processID = processID
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
    public static let minimumWindowEdge = 100

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
    /// What matching a reference against what is on screen produced.
    ///
    /// `ambiguous` is the case this type used to hide. Before it existed the
    /// largest window won, on the reasoning that "recording the right app beats
    /// recording nothing" — true when a person pressed a hotkey with a
    /// remembered target, and exactly backwards on the agent path, where nobody
    /// is watching. With ten Chrome windows open that rule silently recorded a
    /// private pull request instead of the intended demo.
    enum WindowMatch: Equatable {
        case one(WindowCandidate)
        case none
        /// More than one window fits and nothing chose between them.
        case ambiguous([WindowCandidate])
    }

    /// Matches a reference against what is on screen, reporting ambiguity
    /// rather than guessing past it.
    ///
    /// Precedence: an explicit `windowID` names exactly one window; a
    /// `titleHint` disambiguates among an app's windows; a single eligible
    /// window needs neither. Anything else is ambiguous and the CALLER decides
    /// — the agent path refuses, the hotkey path may still prefer the largest.
    static func match(for reference: TargetReference,
                      among candidates: [WindowCandidate]) -> WindowMatch {
        guard let bundleID = reference.bundleIdentifier else { return .none }
        let sameApp = candidates.filter {
            $0.bundleIdentifier == bundleID
                && $0.width >= minimumWindowEdge
                && $0.height >= minimumWindowEdge
        }
        guard !sameApp.isEmpty else { return .none }

        // An id from this session's listing names one window and settles it.
        // Checked before the size floor's survivors are counted, but still
        // WITHIN them: an id naming a 60x200 palette is refused for the same
        // reason a bundle id resolving to one is.
        if let windowID = reference.windowID {
            guard let exact = sameApp.first(where: { $0.windowID == windowID }) else {
                return .none
            }
            return .one(exact)
        }
        if let hint = reference.titleHint,
           let exact = sameApp.first(where: { $0.title == hint }) {
            return .one(exact)
        }
        if sameApp.count == 1 { return .one(sameApp[0]) }
        return .ambiguous(sameApp)
    }

    /// The largest eligible window, ignoring ambiguity.
    ///
    /// Kept for callers that must record SOMETHING rather than refuse — a
    /// person pressing a hotkey with a remembered target. Ties keep the
    /// earliest candidate, so the order is stable rather than dependent on how
    /// `max(by:)` breaks ties.
    static func bestMatch(for reference: TargetReference,
                          among candidates: [WindowCandidate]) -> WindowCandidate? {
        switch match(for: reference, among: candidates) {
        case .one(let candidate): return candidate
        case .none: return nil
        case .ambiguous(let candidates):
            guard let first = candidates.first else { return nil }
            return candidates.dropFirst().reduce(first) { best, candidate in
                candidate.width * candidate.height > best.width * best.height
                    ? candidate : best
            }
        }
    }

    /// Why `bestMatch` found nothing — the reasons need opposite advice.
    ///
    /// THREE reasons, not two. This asked only "does this app have any window
    /// on screen?", so a named window id that matches nothing fell into
    /// `targetTooSmall` whenever the app was running: "Chrome has no window
    /// larger than 100×100 to record", said about an application with thirteen
    /// windows, with a hint telling you to resize one. Both halves false, and
    /// the remedy fixes nothing. A caller measured it and had nothing true to
    /// act on.
    ///
    /// Order matters: the id is checked FIRST. A caller who named one is asking
    /// about that window, and anything said about the application as a whole
    /// answers a question they did not ask.
    ///
    /// Pure, so the distinction is testable without a screen.
    static func failure(for reference: TargetReference,
                        among candidates: [WindowCandidate]) -> TargetResolutionError {
        let name = reference.bundleIdentifier ?? "unknown application"
        if let windowID = reference.windowID,
           !candidates.contains(where: { $0.windowID == windowID }) {
            return .windowNotFound(id: windowID, app: name)
        }
        guard let bundleID = reference.bundleIdentifier else { return .targetGone(name) }
        let appIsOnScreen = candidates.contains { $0.bundleIdentifier == bundleID }
        return appIsOnScreen ? .targetTooSmall(name) : .targetGone(name)
    }

    /// Builds the descriptor for a matched window.
    ///
    /// Pure, and separate from `resolve()`, because one of its fields has no
    /// other evidence of correctness: `processID` is the ONLY thing
    /// `WindowFocuser.focus(descriptor:)` acts on, and it was omitted at both
    /// sites that feed `RecordingCoordinator.startRecording` — so auto-focus
    /// (§4.13) never fired anywhere in production while every focuser test
    /// passed against hand-built descriptors carrying a pid.
    static func descriptor(for candidate: WindowCandidate,
                           pixelSize: (width: Int, height: Int)) -> CaptureTargetDescriptor {
        CaptureTargetDescriptor(
            id: candidate.windowID,
            kind: CaptureTargetDescriptor.Kind.window.rawValue,
            title: candidate.title,
            applicationName: candidate.applicationName,
            width: pixelSize.width,
            height: pixelSize.height,
            processID: candidate.processID
        )
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
                    height: size.height,
                    processID: nil
                ),
                reference: reference,
                provenance: .cache
            )

        case .window:
            let candidates = content.windows.map {
                WindowCandidate(windowID: $0.windowID,
                                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                                applicationName: $0.owningApplication?.applicationName,
                                title: $0.title,
                                width: Int($0.frame.width),
                                height: Int($0.frame.height),
                                processID: $0.owningApplication?.processID)
            }
            // `match`, not `bestMatch`: this resolver serves the AGENT path
            // only (the hotkey path goes through the picker, D42), and an agent
            // that cannot tell which window it got is worse off than one told
            // to choose. Guessing here recorded a private pull request.
            let matched: WindowCandidate
            switch Self.match(for: reference, among: candidates) {
            case .one(let candidate):
                matched = candidate
            case .ambiguous(let all):
                throw TargetResolutionError.ambiguousWindows(
                    application: reference.bundleIdentifier ?? "that application",
                    candidates: all.map { .init(id: $0.windowID, title: $0.title) })
            case .none:
                throw Self.failure(for: reference, among: candidates)
            }
            guard let window = content.windows.first(where: { $0.windowID == matched.windowID })
            else {
                throw Self.failure(for: reference, among: candidates)
            }
            let match = matched

            let filter = SCContentFilter(desktopIndependentWindow: window)
            return ResolvedTarget(
                filter: filter,
                descriptor: Self.descriptor(for: match,
                                            pixelSize: filter.pixelDimensions),
                reference: reference,
                provenance: .cache
            )
        }
    }
}
