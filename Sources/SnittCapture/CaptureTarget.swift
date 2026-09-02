import Foundation
import ScreenCaptureKit

/// A serializable description of something Snitt can record.
///
/// `SCDisplay` and `SCWindow` are not Codable and cannot cross an IPC
/// boundary, so the CLI contract (M2) is expressed in these instead.
public struct CaptureTargetDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case display
        case window
    }

    public var id: UInt32
    public var kind: String
    public var title: String?
    public var applicationName: String?
    public var width: Int
    public var height: Int

    public init(id: UInt32, kind: String, title: String?,
                applicationName: String?, width: Int, height: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.width = width
        self.height = height
    }
}

/// Something Snitt can record.
///
/// `@unchecked Sendable` is a deliberate, narrow assertion: `SCDisplay` and `SCWindow`
/// are not marked `Sendable` by ScreenCaptureKit, but they are immutable snapshots
/// returned once by `SCShareableContent` and Snitt never mutates them — it only reads
/// their identifiers and dimensions. Scoping the claim here, rather than using a
/// file-wide `@preconcurrency import`, keeps strict-concurrency checking active for
/// every other ScreenCaptureKit type used in this file.
public enum CaptureTarget: @unchecked Sendable {
    case display(SCDisplay)
    case window(SCWindow)

    public var descriptor: CaptureTargetDescriptor {
        switch self {
        case .display(let display):
            return CaptureTargetDescriptor(
                id: display.displayID,
                kind: CaptureTargetDescriptor.Kind.display.rawValue,
                title: "Display \(display.displayID)",
                applicationName: nil,
                width: display.width,
                height: display.height
            )
        case .window(let window):
            return CaptureTargetDescriptor(
                id: window.windowID,
                kind: CaptureTargetDescriptor.Kind.window.rawValue,
                title: window.title,
                applicationName: window.owningApplication?.applicationName,
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            )
        }
    }

    public func contentFilter() -> SCContentFilter {
        switch self {
        case .display(let display):
            return SCContentFilter(display: display, excludingWindows: [])
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Enumerates what can be recorded.
    ///
    /// This call triggers the Screen Recording permission prompt, which is
    /// why it happens at first record rather than at launch (spec 4.10).
    ///
    /// - Important: This is the **bypass path**, and M2 must replace it.
    ///   Enumerating targets ourselves and drawing our own picker is what
    ///   macOS 15 calls "bypassing the system private window picker", and such
    ///   apps get a **recurring monthly re-consent prompt** — which breaks the
    ///   one-time-grant promise in spec 5.2 no matter how few permissions we
    ///   request. `SCContentSharingPicker` is the replacement: it avoids the
    ///   monthly nag and yields window-scoped selection by default (spec 5.1).
    ///   Keep this method only for headless target listing where no human is
    ///   present to drive a picker; do not build the interactive flow on it.
    @available(*, deprecated,
               message: "Use PickerTargetResolver or CachedTargetResolver. This enumerates directly, which is the bypass path (§5.2).")
    public static func available() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return content.displays.map { .display($0) }
             + content.windows.map { .window($0) }
    }
}
