import Foundation

/// What an export produced, for a caller that cannot watch it (§8).
///
/// Lives in `SnittDocument`, not `SnittExport`: `SnittAutomation` must carry
/// this type in its protocol responses, and `SnittExport` links AVFoundation.
/// Putting the manifest there would make `SnittAutomation` depend on it,
/// which would pull AVFoundation into `snitt-cli` and `snitt-mcp` —
/// exactly the transitive-linking defect the thin-client guard was built
/// for. `SnittDocument` imports only Foundation, and `SnittAutomation`
/// already depends on it.
public struct ExportManifest: Codable, Sendable, Equatable {
    public struct Chapter: Codable, Sendable, Equatable {
        public var timeSeconds: Double
        public var title: String

        public init(timeSeconds: Double, title: String) {
            self.timeSeconds = timeSeconds
            self.title = title
        }
    }

    public var outputPath: String
    public var format: String
    public var byteSize: Int
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var scale: Double
    public var chaptersPath: String?
    public var chapters: [Chapter]

    public init(outputPath: String,
                format: String,
                byteSize: Int,
                durationSeconds: Double,
                width: Int,
                height: Int,
                scale: Double,
                chaptersPath: String? = nil,
                chapters: [Chapter] = []) {
        self.outputPath = outputPath
        self.format = format
        self.byteSize = byteSize
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.scale = scale
        self.chaptersPath = chaptersPath
        self.chapters = chapters
    }
}
