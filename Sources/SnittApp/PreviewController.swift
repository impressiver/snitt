import AVFoundation
import Foundation
import SnittDocument
import SnittExport

/// Owns playback for the editor's preview.
///
/// `@MainActor` by necessity, not preference: `AVPlayerItem.init(asset:)` is
/// main-actor isolated under Swift 6 and `AVAudioMix` is non-Sendable
/// (spike S6).
///
/// This type ATTACHES a `BuiltComposition`. It never builds one. §9 makes the
/// shared builder load-bearing — "the most common serious bug class in video
/// editors is an export that does not match the preview" — and a preview that
/// constructs its own composition, video composition or audio mix is how that
/// guarantee is lost, one small tweak at a time.
/// Not `final`: a test subclass overrides `apply(edl:events:)` to make it
/// take a chosen amount of time, which is the only way to force a
/// DETERMINISTIC completion-order inversion between two autosaves
/// (`EditorPersistenceTests.laterTrimIsNotOverwrittenByAnEarlierSave`,
/// whole-branch review F2). Two real builds of two real EDLs finish in
/// whatever order the machine happens to pick, so a test written against
/// real timing would pass against the unserialized code most of the time —
/// the shape of non-test this project has already paid for.
@MainActor
public class PreviewController {
    public private(set) var jumpPoints: [JumpPoint]
    public private(set) var durationSeconds: Double
    /// The SOURCE recording's media duration (`BuiltComposition.sourceDuration`)
    /// — never `durationSeconds` above, which is the TRIMMED (output)
    /// duration. The editor timeline draws on this clock (M4b whole-branch
    /// review, Critical finding #1): `edl.cuts` are source-time ranges, and
    /// only a source-time axis gives a cut a coherent position at all — by
    /// definition a cut has no position in the output.
    public private(set) var sourceDurationSeconds: Double
    /// The kept ranges the CURRENT composition was built from — the same set
    /// `CompositionBuilder.build` inserted into it. Lets a caller (the
    /// editor timeline) map the player's trimmed-time playhead, and this
    /// controller's own `jumpPoints`, back onto the source clock via
    /// `TimeRangeMapping.sourceTime(ofTrimmedTime:keptRanges:)`.
    public private(set) var keptRanges: [TimeRange]
    private var item: AVPlayerItem
    public let player: AVPlayer

    /// Test seam (Ruling R3): a production `AVPlayerItemVideoOutput` exists
    /// so tests can read the frame `AVFoundation` actually decoded, rather
    /// than `AVPlayer.currentTime()`'s report of the seek *target*. Spike S7
    /// measured that `currentTime()` still returns the requested time after
    /// a completed seek regardless of tolerance or keyframe density — it
    /// cannot see whether a seek landed on the right frame, only whether it
    /// was accepted. `copyPixelBuffer(forItemTime:)` returns the
    /// actually-decoded buffer for a composition-backed item, works on a
    /// paused seeked item with zero retries, and gives distinguishable
    /// output across seek targets (S7).
    ///
    /// This output MUST be attached at construction time — an
    /// `AVPlayerItemVideoOutput` added after an item has already started
    /// producing frames misses them, per S7's measurement. That is why
    /// `init` and `apply(edl:events:)` (which replaces `item` with a fresh
    /// one) both attach a fresh output rather than reusing one across items.
    private var videoOutput: AVPlayerItemVideoOutput

    private static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
    }

    /// The bundle and scale this controller was built with. `apply` needs
    /// both to call `CompositionBuilder.build` again — the controller has no
    /// other source for them, since `BuiltComposition` itself doesn't carry
    /// them back out.
    private let bundle: SnittBundle
    private let scale: Double

    public init(built: BuiltComposition, jumpPoints: [JumpPoint],
                bundle: SnittBundle, scale: Double) {
        self.jumpPoints = jumpPoints
        self.durationSeconds = built.duration
        self.sourceDurationSeconds = built.sourceDuration
        self.keptRanges = built.keptRanges
        self.bundle = bundle
        self.scale = scale
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        let output = Self.makeVideoOutput()
        item.add(output)
        self.videoOutput = output
        self.item = item
        self.player = AVPlayer(playerItem: item)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// Writes `edl` to the bundle this controller was built with (Task 7,
    /// D46). This is the only writer for a GUI trim — before this method
    /// existed, `EditorWindowController.onTrim` rebuilt the preview through
    /// `apply(edl:events:)` and never wrote anything, so a trim shown on
    /// screen was silently discarded when the window closed.
    ///
    /// Lives here, not on `EditDecisionList` or `EditorTimelineState`,
    /// because `bundle` is `private` to this type (R1: the write belongs
    /// with the owner, not behind a widened-to-internal field).
    public func persist(_ edl: EditDecisionList) throws {
        try edl.write(to: bundle)
    }

    /// Rebuilds the composition through `CompositionBuilder.build` — never
    /// by mutating the existing `AVMutableComposition` in place — and
    /// re-attaches it, keeping `jumpPoints` in step with the new
    /// `keptRanges`. §9: preview and export must stay the same code path.
    ///
    /// R2 (binding): `events` is REQUIRED, not defaulted to `[]` (M4b
    /// whole-branch review, Important finding #3). "No markers to place" and
    /// "the caller forgot to pass events" must not be the same call with no
    /// compiler signal — a default here made the empty-marker case free to
    /// reach by accident. The empty-list SEMANTICS this replaces are still
    /// right and unchanged: recomputing against `[]` clears `jumpPoints` to
    /// `[]` rather than keeping stale positions from before the edit,
    /// because stale positions are the exact preview/export divergence §9
    /// exists to prevent — a caller that passes `[]` on purpose gets an
    /// empty scrub bar (visibly wrong, immediately noticed) rather than
    /// markers silently pointing at the wrong instant (wrong in a way
    /// nothing surfaces). What changes is that a caller must now WRITE `[]`
    /// to get that behaviour, rather than getting it for free by omission.
    public func apply(edl: EditDecisionList, events: [LoggedEvent]) async throws {
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
        let newItem = AVPlayerItem(asset: built.composition)
        newItem.videoComposition = built.videoComposition
        newItem.audioMix = built.audioMix
        let output = Self.makeVideoOutput()
        newItem.add(output)
        self.videoOutput = output

        player.replaceCurrentItem(with: newItem)
        self.item = newItem
        self.durationSeconds = built.duration
        self.sourceDurationSeconds = built.sourceDuration
        self.keptRanges = built.keptRanges
        self.jumpPoints = MarkerJumpPoints.compute(events: events, keptRanges: built.keptRanges)
    }

    /// Exact seeking. `seek(to:)` without tolerances snaps to the nearest
    /// keyframe, which puts a marker jump seconds from the marker.
    ///
    /// Waits (bounded, polling — never blocking a thread) for the item to
    /// leave `.unknown` first. `AVPlayerItemVideoOutput.copyPixelBuffer`
    /// measurably returns nil for a seek issued before the item reports
    /// ready, even though `AVPlayer.seek` itself completes either way; a
    /// caller that seeks immediately after construction (every test here
    /// does) would otherwise race the item's own loading.
    ///
    /// It does NOT wait for `videoOutput`'s pipeline to catch up. That wait
    /// belongs to the observable, not to seeking: `AVPlayerLayer` renders
    /// from the player's own presentation pipeline, not from the
    /// `AVPlayerItemVideoOutput` tap, so the frame a user sees is correct as
    /// soon as this returns. Making every real scrub wait for a tap only the
    /// tests read would add up to two seconds of latency to the one
    /// interaction this milestone exists to make fast. See
    /// `currentFrameFingerprint()`, which does that waiting itself.
    public func seek(toSeconds seconds: Double) async {
        var waited = 0.0
        while item.status == .unknown && waited < 8.0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 0.02
        }
        let clamped = max(0, min(seconds, durationSeconds))
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func jump(to point: JumpPoint) async {
        await seek(toSeconds: point.timeSeconds)
    }

    /// A cheap fingerprint of the frame `AVFoundation` actually decoded at
    /// the item's current time — not the seek target `currentTime()`
    /// reports, but the pixel buffer `AVPlayerItemVideoOutput` hands back
    /// (S7). Reduces the buffer to a single `Int` by averaging a sparse
    /// stride of samples: S7 measured that this is enough to distinguish
    /// frames from `.ramp` fixture content without pixel-exact comparison.
    ///
    /// Returns `nil` if no buffer is available for the current time (e.g.
    /// the item isn't ready yet).
    ///
    /// Waits, with bounded polling and never a thread block, for the output
    /// to actually serve the current time. Measured: `AVPlayer.seek`'s
    /// completion firing — and even `hasNewPixelBuffer` reporting true — do
    /// not mean the video output has advanced, and a second seek issued
    /// right after the first still hands back the PREVIOUS target's buffer,
    /// with `itemTimeForDisplay` naming the earlier time. The wait lives
    /// here because only this observable needs it.
    public func currentFrameFingerprint() async -> Int? {
        let time = item.currentTime()
        var waited = 0.0
        while waited < 2.0 {
            var display = CMTime.invalid
            _ = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display)
            if display.isValid, CMTimeCompare(display, time) == 0 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 0.02
        }
        // Called directly, not gated on `hasNewPixelBuffer`: S7 measured
        // `copyPixelBuffer` delivering a buffer on the first attempt (0
        // retries) at every seek target on a paused item, and
        // `hasNewPixelBuffer` tracks "changed since last poll" rather than
        // "available", which would spuriously return false the second time
        // this is called for the same seeked time (as `seekingIsRepeatable`
        // does).
        guard let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let byteCount = bytesPerRow * height
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        let stride = 97 // sparse, coprime-ish with common row widths (S7)
        var sum = 0
        var count = 0
        var offset = 0
        while offset < byteCount {
            sum += Int(pointer[offset])
            count += 1
            offset += stride
        }
        guard count > 0 else { return nil }
        return sum / count
    }
}
