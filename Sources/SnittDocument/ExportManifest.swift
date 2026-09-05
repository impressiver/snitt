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
    /// The byte target the caller asked for, or nil if none was requested.
    public var maxSizeBytes: Int?
    /// Whether that target was met. Three states, deliberately: nil means no
    /// target was requested, true means it was met, false means the exporter
    /// tried every setting in its ladder and the file is still over budget.
    /// `byteSize` says how far over.
    public var maxSizeMet: Bool?
    /// The frame rate the written file actually plays at. Nil for mp4 (frame
    /// rate is not an axis the size ladder touches there); for gif, the rate
    /// the size ladder settled on — which may be below the 15fps the export
    /// started from. Without this, a GIF silently degraded from 15fps to
    /// 5fps reports `scale: 1.0` and is indistinguishable from an untouched
    /// export: frame rate is an axis `SizeLadder` walks before scale, and
    /// this is the only place that choice becomes visible to a caller.
    public var effectiveFPS: Double?
    public var chaptersPath: String?
    public var chapters: [Chapter]

    public init(outputPath: String,
                format: String,
                byteSize: Int,
                durationSeconds: Double,
                width: Int,
                height: Int,
                scale: Double,
                maxSizeBytes: Int? = nil,
                maxSizeMet: Bool? = nil,
                effectiveFPS: Double? = nil,
                chaptersPath: String? = nil,
                chapters: [Chapter] = []) {
        self.outputPath = outputPath
        self.format = format
        self.byteSize = byteSize
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.scale = scale
        self.maxSizeBytes = maxSizeBytes
        self.maxSizeMet = maxSizeMet
        self.effectiveFPS = effectiveFPS
        self.chaptersPath = chaptersPath
        self.chapters = chapters
    }
}
