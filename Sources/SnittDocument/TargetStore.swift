import Foundation

/// The kind of target a stored record describes.
///
/// Deliberately a separate enum from `SnittCapture.TargetReference.Kind`: the storage
/// layer must not depend on ScreenCaptureKit. Using a local enum rather than a bare
/// String means an unrecognised value fails at DECODE, where `load()` already degrades
/// to "no cached target", instead of surviving as a garbage string that breaks later
/// during conversion.
public enum StoredTargetKind: String, Codable, Sendable {
    case window
    case display
}

/// The on-disk shape of a cached target. Kept as a plain string-keyed record in
/// `SnittDocument` so the storage layer does not depend on ScreenCaptureKit.
public struct StoredTargetReference: Codable, Sendable, Equatable {
    public var kind: StoredTargetKind
    public var bundleIdentifier: String?
    public var titleHint: String?
    public var displayID: UInt32?

    public init(kind: StoredTargetKind,
                bundleIdentifier: String?,
                titleHint: String?,
                displayID: UInt32?) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.titleHint = titleHint
        self.displayID = displayID
    }
}

/// Persists the last target a human approved, so the hotkey can reuse it.
///
/// Reads never throw: a missing or corrupt cache degrades to "no cached
/// target", which sends the user to the picker. A convenience cache must never
/// be able to break recording.
public final class TargetStore: @unchecked Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Snitt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        return base.appendingPathComponent("last-target.json")
    }

    public func load() -> StoredTargetReference? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredTargetReference.self, from: data)
    }

    public func save(_ reference: StoredTargetReference) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reference).write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
