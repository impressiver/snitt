import Foundation

/// Tracks the one active agent session.
///
/// Deliberately single-session: a second `open` is refused rather than replacing
/// the first. Two concurrent recordings would mean two `AVAssetWriter`s on one
/// screen — the same defect the app's own transition guard prevents for hotkey
/// presses, reachable here through two agents instead.
public actor SessionRegistry {
    private struct Session {
        let id: String
        let startedAt: Date
        let maxDuration: Double
    }

    private var session: Session?

    public init() {}

    public var isRecording: Bool { session != nil }

    public func open(maxDuration: Double, now: Date) throws -> String {
        if session != nil {
            throw AutomationError(
                code: .alreadyRecording,
                message: "A recording is already in progress.",
                hint: "Stop it first with `snitt record stop`, or check `snitt status`.")
        }
        let id = UUID().uuidString
        session = Session(id: id, startedAt: now, maxDuration: maxDuration)
        return id
    }

    public func close(_ id: String) throws {
        guard let current = session, current.id == id else {
            throw AutomationError(
                code: .noSuchSession,
                message: "No recording with that session id.",
                hint: "Check `snitt status` for the current session.")
        }
        session = nil
    }

    public func current(now: Date) -> StatusInfo {
        guard let session else {
            return StatusInfo(recording: false, sessionID: nil, elapsedSeconds: nil)
        }
        return StatusInfo(recording: true,
                          sessionID: session.id,
                          elapsedSeconds: now.timeIntervalSince(session.startedAt))
    }

    /// The id of a session that has outlived its cap, if any.
    ///
    /// Reporting rather than acting: the registry does not own the `Recorder`, so
    /// the host decides what stopping means. §5.3 requires only that something
    /// notices.
    public func expiredSession(now: Date) -> String? {
        guard let session else { return nil }
        return now.timeIntervalSince(session.startedAt) > session.maxDuration
            ? session.id : nil
    }
}
