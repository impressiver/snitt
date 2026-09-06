import Foundation

/// §12's error categories, as a type rather than a string typed at each
/// call site.
///
/// "Error categories are distinguishable in logs: permission fault vs disk
/// fault vs compositor fault. 'It failed' is not a diagnosable report."
/// Spelled by hand at each site, these drift — `permission`, `permissions`,
/// `perm` — and a support engineer greps for the one spelling nobody used.
///
/// The raw values reach exported diagnostics that humans read and grep, so
/// they are a wire format: renaming one breaks every bundle already saved
/// and every runbook that mentions it.
public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable {
    case permission
    case disk
    case capture
    case compositor
    case automation
    /// M5b: Sparkle update checks and installs (§13). A failed network
    /// fetch, a misconfigured feed, or an EdDSA signature rejection all
    /// land here rather than under `automation`, since none of them have
    /// anything to do with the agent-control socket. `SUPublicEDKey` is
    /// configured, so signature rejection is a reachable outcome: Sparkle
    /// verifies `sparkle:edSignature` against that key before installing,
    /// on top of the Developer-ID code-signature match.
    case updates

    /// Whether the person in front of the machine can do something about
    /// it. A permission denial has a System Settings pane; a compositor
    /// fault has only a bug report. §11 already draws this line
    /// operationally — naming it keeps the two consistent.
    public var isUserActionable: Bool {
        switch self {
        case .permission, .disk: return true
        case .capture, .compositor, .automation, .updates: return false
        }
    }
}
