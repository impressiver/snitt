import Foundation

public enum SnittBundleError: Error, Equatable {
    case notADirectory
    case missingCapture
    case alreadyExists
}

/// A `.snitt` recording package.
///
/// The bundle is a directory. `capture.mov` is written once during recording
/// and never mutated afterwards; `edit.json` is the only file editing touches.
/// See spec section 7.
public struct SnittBundle: Sendable {
    public static let fileExtension = "snitt"

    public let url: URL

    public var captureURL: URL { url.appendingPathComponent("capture.mov") }
    public var eventsURL: URL { url.appendingPathComponent("events.json") }
    public var editURL: URL { url.appendingPathComponent("edit.json") }
    public var metaURL: URL { url.appendingPathComponent("meta.json") }
    public var posterURL: URL { url.appendingPathComponent("poster.png") }

    /// Creates a new bundle directory. Throws if anything already exists there.
    public init(creatingAt url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SnittBundleError.alreadyExists
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false
        )
        self.url = url
    }

    /// Opens an existing bundle directory.
    public init(opening url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw SnittBundleError.notADirectory
        }
        self.url = url
    }
}
