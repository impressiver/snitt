import Foundation
@preconcurrency import ScreenCaptureKit

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

public enum CaptureTarget: Sendable {
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
    public static func available() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return content.displays.map { .display($0) }
             + content.windows.map { .window($0) }
    }
}
