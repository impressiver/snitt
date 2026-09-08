import Foundation

/// A durable description of something Snitt can record.
///
/// Deliberately does NOT store a window id. `SCWindow.windowID` is a
/// per-session integer, so a relaunched application produces new windows with
/// new ids and a stored id silently stops matching (spec §5.4, V10). The
/// durable identity is the owning application's bundle identifier; the title is
/// kept only to disambiguate when one app has several windows.
public struct TargetReference: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case window
        case display
    }

    public var kind: Kind
    public var bundleIdentifier: String?
    public var titleHint: String?
    public var displayID: UInt32?
    /// A window id from THIS session's `snitt_list_targets`, naming exactly one
    /// window. Transient by contract: never stored, never cached, valid only
    /// for the call that carries it.
    ///
    /// This does not reverse the rule above. That rule is about DURABLE
    /// references — a stored id stops matching after a relaunch (V10), which is
    /// why `TargetStore` must never see one. An agent that just listed targets
    /// and is naming one from that list has no such problem, and needs the
    /// precision: with ten Chrome windows open, a bundle identifier alone
    /// selected the largest one and silently recorded a private pull request
    /// instead of the demo.
    public var windowID: UInt32?

    public static func window(bundleIdentifier: String,
                              titleHint: String?,
                              windowID: UInt32? = nil) -> TargetReference {
        TargetReference(kind: .window,
                        bundleIdentifier: bundleIdentifier,
                        titleHint: titleHint,
                        displayID: nil,
                        windowID: windowID)
    }

    public static func display(id: UInt32) -> TargetReference {
        TargetReference(kind: .display,
                        bundleIdentifier: nil,
                        titleHint: nil,
                        displayID: id,
                        windowID: nil)
    }
}
