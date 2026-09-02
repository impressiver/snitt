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

    public static func window(bundleIdentifier: String,
                              titleHint: String?) -> TargetReference {
        TargetReference(kind: .window,
                        bundleIdentifier: bundleIdentifier,
                        titleHint: titleHint,
                        displayID: nil)
    }

    public static func display(id: UInt32) -> TargetReference {
        TargetReference(kind: .display,
                        bundleIdentifier: nil,
                        titleHint: nil,
                        displayID: id)
    }
}
