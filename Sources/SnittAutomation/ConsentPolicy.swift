// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// §5.3's rules for agent-initiated recording, as pure logic.
///
/// The visible indicator and the kill switch already exist in the app; this
/// decides whether a request is permitted at all. Kept free of sockets, AppKit and
/// ScreenCaptureKit so every rule can be tested exhaustively.
public struct ConsentPolicy: Sendable {
    public static let defaultMaximumSessionSeconds: Double = 600

    private let agentRecordingEnabled: Bool
    private let fullDisplayAllowed: Bool
    private let maximumSessionSeconds: Double

    public init(agentRecordingEnabled: Bool,
                fullDisplayAllowed: Bool = false,
                maximumSessionSeconds: Double = ConsentPolicy.defaultMaximumSessionSeconds) {
        self.agentRecordingEnabled = agentRecordingEnabled
        self.fullDisplayAllowed = fullDisplayAllowed
        self.maximumSessionSeconds = maximumSessionSeconds
    }

    /// Whether an agent may reach Snitt's data at all.
    ///
    /// Separate from `evaluate`, which answers "may this RECORDING proceed" and
    /// needs `StartOptions`. Reading an existing bundle has no options to
    /// evaluate but is still an agent touching the user's recordings, so it
    /// asks this instead of constructing a fake request to get an answer.
    public var allowsAgentAccess: Bool { agentRecordingEnabled }

    /// Returns nil when the request may proceed, or the error to send back.
    public func evaluate(_ options: StartOptions) -> AutomationError? {
        guard agentRecordingEnabled else {
            return AutomationError(
                code: .consentRequired,
                message: "Agent recording is turned off.",
                hint: "A person must enable it in Snitt's settings. Ask them to open "
                    + "Snitt and turn on agent recording, then try again.")
        }

        if options.displayID != nil {
            guard fullDisplayAllowed else {
                return AutomationError(
                    code: .consentRequired,
                    message: "Recording a whole display is not permitted for agents.",
                    hint: "Record a window instead by passing an application bundle "
                        + "identifier, or ask a person to allow full-display agent "
                        + "recording in Snitt's settings.")
            }
            return nil
        }

        guard options.bundleIdentifier != nil else {
            return AutomationError(
                code: .targetNotFound,
                message: "No target was specified.",
                hint: "Pass --app with an application bundle identifier. "
                    + "Use `snitt targets list` to see what is available.")
        }
        return nil
    }

    /// The cap is a CEILING, not a default an agent can raise — §5.3 exists so a
    /// hung or abandoned agent cannot fill the disk.
    public func effectiveMaxDuration(_ requested: Double?) -> Double {
        guard let requested, requested > 0 else { return maximumSessionSeconds }
        return min(requested, maximumSessionSeconds)
    }
}
