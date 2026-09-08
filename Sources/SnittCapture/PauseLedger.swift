import CoreMedia

/// Tracks paused spans and the timestamp shift they imply.
///
/// An `AVAssetWriter` session cannot be paused. The supported shape is to drop
/// buffers while paused and shift every later buffer's presentation timestamp
/// back by the total paused time, so the written file is continuous — a viewer
/// sees the recording jump from the moment of pause to the moment of resume,
/// with no frozen gap and no stall.
///
/// Pure and separated from `CaptureSession` because this is the part that can
/// be wrong in a way nothing visible catches: a shift that is off by one pause
/// produces a file that plays perfectly and whose every marker, event and cut
/// lands at the wrong instant. §4.12's markers and the EDL are both on this
/// clock.
public struct PauseLedger: Equatable, Sendable {
    /// Total time spent paused, across every pause so far.
    public private(set) var totalPaused: CMTime = .zero
    /// When the current pause began, `nil` when running.
    public private(set) var pausedSince: CMTime?

    public init() {}

    public var isPaused: Bool { pausedSince != nil }

    /// Idempotent: pausing an already-paused session keeps the ORIGINAL start.
    /// Taking the later one would silently shorten the pause and shift every
    /// subsequent timestamp forward by the difference.
    public mutating func pause(at time: CMTime) {
        guard pausedSince == nil else { return }
        pausedSince = time
    }

    /// Idempotent, and refuses to run time backwards: a resume timestamp before
    /// the pause began would make `totalPaused` shrink, shifting later buffers
    /// the wrong way. Clamped at zero rather than trusted.
    public mutating func resume(at time: CMTime) {
        guard let since = pausedSince else { return }
        let span = CMTimeSubtract(time, since)
        if span > .zero { totalPaused = CMTimeAdd(totalPaused, span) }
        pausedSince = nil
    }

    /// A source timestamp mapped onto the written timeline.
    public func adjusted(_ time: CMTime) -> CMTime {
        CMTimeSubtract(time, totalPaused)
    }

    /// How long this session has been alive in RECORDED terms — source elapsed
    /// minus paused. Distinct from `maxDuration`'s clock; see
    /// `elapsedAgainstLimit`.
    public func recordedElapsed(since start: CMTime, now: CMTime) -> CMTime {
        CMTimeSubtract(CMTimeSubtract(now, start), totalPausedIncludingOpenPause(now: now))
    }

    /// What `maxDuration` measures: WALL time since the session started,
    /// **including** time spent paused.
    ///
    /// Deliberately includes it (D53 asked the question and left it open).
    /// `maxDuration` exists as the backstop for an unattended agent run, where
    /// nobody presses stop — and D53 names "an agent forgets to resume" as the
    /// case where a human at the machine is the only fallback. If paused time
    /// did not count, a forgotten pause would run forever, which is precisely
    /// the runaway the limit exists to prevent. So the limit bounds the
    /// session's life, not its footage.
    public func elapsedAgainstLimit(since start: CMTime, now: CMTime) -> CMTime {
        CMTimeSubtract(now, start)
    }

    private func totalPausedIncludingOpenPause(now: CMTime) -> CMTime {
        guard let since = pausedSince else { return totalPaused }
        let open = CMTimeSubtract(now, since)
        return open > .zero ? CMTimeAdd(totalPaused, open) : totalPaused
    }
}
