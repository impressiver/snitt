import Foundation

public enum Initiator: String, Codable, Sendable {
    case human
    case agent
}

/// Git provenance for a recording made inside a repository (spec section 7).
public struct GitContext: Codable, Sendable {
    public var branch: String?
    public var commit: String?

    public init(branch: String? = nil, commit: String? = nil) {
        self.branch = branch
        self.commit = commit
    }
}

/// Capture health metrics (spec section 12.1). Populated in M2; defined now
/// so the meta.json schema does not change when M2 lands.
public struct CaptureHealth: Codable, Sendable {
    public var meanFrameVariance: Double?
    public var micRMS: Double?
    public var systemAudioRMS: Double?

    public init(meanFrameVariance: Double? = nil,
                micRMS: Double? = nil,
                systemAudioRMS: Double? = nil) {
        self.meanFrameVariance = meanFrameVariance
        self.micRMS = micRMS
        self.systemAudioRMS = systemAudioRMS
    }
}

public struct RecordingMetadata: Codable, Sendable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var initiator: Initiator
    public var durationSeconds: Double?
    public var git: GitContext?
    public var health: CaptureHealth?

    public init(schemaVersion: Int = 1,
                createdAt: Date,
                initiator: Initiator,
                durationSeconds: Double? = nil,
                git: GitContext? = nil,
                health: CaptureHealth? = nil) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.initiator = initiator
        self.durationSeconds = durationSeconds
        self.git = git
        self.health = health
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.metaURL)
    }

    public static func read(from bundle: SnittBundle) throws -> RecordingMetadata {
        try JSONCoding.decoder.decode(
            RecordingMetadata.self, from: Data(contentsOf: bundle.metaURL)
        )
    }
}

/// Shared JSON configuration. ISO-8601 dates and sorted keys keep bundle
/// files diffable and stable across writes.
enum JSONCoding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
