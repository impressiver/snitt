import Foundation
import SnittAutomation
import SnittCapture
import SnittDocument
import SnittExport

/// Bridges automation requests to the same recording machinery the hotkey uses.
///
/// Requests arrive off the main actor; anything touching the coordinator or the
/// status item hops to it. Agent recordings go through the SAME coordinator as
/// hotkey presses, so M2a's transition guard and kill switch apply to them
/// without a second implementation (§5.3).
///
/// The menu-bar INDICATOR is not free that way: it is driven by whoever calls
/// the coordinator, and the hotkey handler in `AppDelegate` is the only such
/// caller that updates it. So this host pushes recording state through
/// `onRecordingState` on every agent start and stop, which `AppDelegate` wires
/// to the same `StatusItemController.update(_:)` the hotkey uses. Without it an
/// agent recording runs with the menu bar showing idle, and §5.3's kill switch
/// is a control nobody has a reason to click.
final class AutomationHost: AutomationHandling, @unchecked Sendable {
    /// Pushes recording state at the menu bar. `@MainActor` because that is
    /// where `StatusItemController` lives; deliberately not `@Sendable`, so it
    /// can capture the main-actor-isolated app delegate directly.
    typealias RecordingStateSink = @MainActor (RecordingState) -> Void

    /// Resolves git context for a client's working directory.
    ///
    /// Injectable because the production call — `GitContextResolver.resolve` —
    /// was reachable by no test at all: deleting the line outright left the
    /// whole suite green, while it is the line the milestone's headline claim
    /// ("a demo arrives as feature-branch-a1b2c3d.snitt") depends on.
    typealias GitResolving = @Sendable (URL) -> GitContext?

    private let coordinator: any AgentRecordingControlling
    private let settings: @Sendable () -> AgentSettings
    private let resolveGit: GitResolving
    private let onRecordingState: RecordingStateSink
    private let registry = SessionRegistry()
    private var server: AutomationServer?

    /// Guards `watchdog` only. Requests can arrive on several connections at
    /// once, so the task handle needs a lock even though everything else this
    /// class touches is an actor.
    private let lock = NSLock()
    private var watchdog: Task<Void, Never>?

    init(coordinator: any AgentRecordingControlling,
         settings: @escaping @Sendable () -> AgentSettings,
         onRecordingState: @escaping RecordingStateSink = { _ in },
         resolveGit: @escaping GitResolving = { GitContextResolver.resolve(in: $0) }) {
        self.coordinator = coordinator
        self.settings = settings
        self.onRecordingState = onRecordingState
        self.resolveGit = resolveGit
    }

    private func pushState(_ state: RecordingState) async {
        let sink = onRecordingState
        await MainActor.run { sink(state) }
    }

    /// Forgets any agent session, without touching the coordinator.
    ///
    /// Called by `AppDelegate` whenever a HUMAN starts or stops a recording. The
    /// coordinator already invalidates the agent's session id on any stop; this
    /// is the registry's half, so `snitt status` stops claiming a recording that
    /// a person ended from the menu bar.
    func clearAgentSession() async {
        cancelWatchdog()
        await registry.closeAny()
    }

    private func cancelWatchdog() {
        lock.lock()
        let task = watchdog
        watchdog = nil
        lock.unlock()
        task?.cancel()
    }

    private func setWatchdog(_ task: Task<Void, Never>) {
        lock.lock()
        let previous = watchdog
        watchdog = task
        lock.unlock()
        previous?.cancel()
    }

    func start() {
        let server = AutomationServer(socketURL: SocketPath.url(), handler: self)
        try? server.start()
        self.server = server
    }

    func stop() {
        cancelWatchdog()
        server?.stop()
        server = nil
    }

    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse {
        switch body {
        case .handshake:
            return .handshake(HandshakeInfo(protocolVersion: AutomationProtocol.version,
                                            appVersion: "0.1.0"))

        case .status:
            return .status(await registry.current(now: Date()))

        case .listTargets:
            return await listTargets()

        case .startRecording(let options):
            return await start(options)

        case .stopRecording(let sessionID):
            return await stop(sessionID)

        case .mark(let sessionID, let label):
            return await mark(sessionID: sessionID, label: label)

        case .inspect(let path):
            return inspect(bundlePath: path)

        case .trim(let bundlePath, let start, let end, let auto):
            return await trim(bundlePath: bundlePath, start: start, end: end, auto: auto)

        case .export(let bundlePath, let format, let outputPath, let scale, let chapters, let maxSizeBytes):
            return await export(bundlePath: bundlePath, format: format, outputPath: outputPath,
                                scale: scale, chapters: chapters, maxSizeBytes: maxSizeBytes)
        }
    }

    /// Mutates only `edit.json` — `capture.mov` is immutable (§7).
    ///
    /// Runs IN THE APP, not the client, for the same reason `inspect` does:
    /// the CLI cannot read the bundle's `meta.json`/`events.json` to compute
    /// cuts, because the default output directory is TCC-gated (§4.9).
    ///
    /// Duration comes from `CompositionBuilder.mediaDuration(of:)` — the
    /// SAME clock `MovieExporter`/`CompositionBuilder` build the exported
    /// file on — never from `RecordingMetadata.durationSeconds`, which is
    /// WALL time (stamped around the capture, always the longer of the two;
    /// see that property's doc comment) and was never equal to the media
    /// clock on a real recording. Reporting `keptSeconds`/`cutSeconds` on
    /// the wall clock while the export lands on the media clock told an
    /// agent a number the exported file did not have — exactly the
    /// confidently-wrong result §8 forbids. If `capture.mov` cannot be read
    /// to answer that question, the trim is refused rather than falling
    /// back to the wall clock: a refusal an agent can act on beats a number
    /// that quietly does not describe the file it will get.
    private func trim(bundlePath: String, start: Double?, end: Double?,
                      auto: Bool) async -> AutomationResponse {
        let bundle: SnittBundle
        do {
            bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Use the path `snitt record stop` printed."))
        }

        let duration: Double
        do {
            duration = try await CompositionBuilder.mediaDuration(of: bundle)
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not determine the recording's duration from capture.mov.",
                hint: "The bundle's capture.mov may be missing or unreadable, so trim "
                    + "cannot compute a duration that will match an export: "
                    + String(describing: error)))
        }

        do {
            let existing = (try? EditDecisionList.read(from: bundle)) ?? .fullRange()

            let cuts: [TimeRange]
            if auto {
                let events = (try? EventLog.read(from: bundle))?.events ?? []
                cuts = try EditDecisionList.autoTrimCuts(events: events, duration: duration)
            } else {
                let keep = TimeRange(start: start ?? 0, end: end ?? duration)
                cuts = existing.trimmed(keeping: keep, duration: duration).cuts
            }

            var updated = existing
            updated.cuts = cuts
            try updated.write(to: bundle)

            let kept = KeptRanges.compute(duration: duration, cuts: cuts)
            let keptSeconds = kept.reduce(0) { $0 + ($1.end - $1.start) }
            return .trimmed(TrimSummary(keptSeconds: keptSeconds,
                                        cutSeconds: duration - keptSeconds,
                                        cuts: cuts))
        } catch AutoTrimError.noInputEvents {
            return .failure(AutomationError(
                code: .internalError,
                message: "This recording logged no input events, so there is nothing "
                       + "to auto-trim against.",
                hint: "Auto-trim clips dead air around clicks and keystrokes. An "
                    + "agent-driven recording produces none. Use `snitt trim --start "
                    + "<seconds> --end <seconds>` instead, or `snitt inspect` to see "
                    + "the markers you can trim around."))
        } catch {
            // Was `code: .targetNotFound, "Could not read a recording at that
            // path."` for EVERY error here, including a failed
            // `updated.write(to: bundle)` (full disk, read-only bundle) —
            // which has nothing to do with the path and sent an agent to fix
            // the wrong thing. Mirrors `export`'s catch-all below, which
            // already preserves the real error in the hint.
            return .failure(AutomationError(
                code: .internalError,
                message: "The trim could not be completed.",
                hint: String(describing: error)))
        }
    }

    /// Reads `capture.mov` and writes the trimmed mp4 (plus, optionally, its
    /// chapters sidecar) IN THE APP, not the client, for the same reason
    /// `trim` does (§4.9): the CLI cannot read `capture.mov` out of the
    /// bundle directory — the default output directory is gated by the
    /// Files-and-Folders TCC service — so it cannot build the composition
    /// itself, only ask the app to.
    private func export(bundlePath: String, format: String, outputPath: String,
                        scale: Double, chapters: Bool, maxSizeBytes: Int?) async -> AutomationResponse {
        // Opening the gif seam must not open it to everything else. The CLI
        // and MCP frontends refuse anything else with matching wording
        // (§8) — this must match too, or a client could send a format the
        // frontends already accepted only to have the app refuse it here.
        guard format == "mp4" || format == "gif" else {
            return .failure(AutomationError(
                code: .internalError,
                message: "Unsupported export format \"\(format)\".",
                hint: "Snitt exports mp4 or gif. Omit --format or pass \"mp4\" or \"gif\"."))
        }

        let bundle: SnittBundle
        do {
            bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Use the path `snitt record stop` printed."))
        }

        let edl = (try? EditDecisionList.read(from: bundle)) ?? .fullRange()
        let outputURL = URL(fileURLWithPath: outputPath)
        // Beside the output, not beside the bundle: an agent that asked for
        // `~/exports/demo.mp4` expects `~/exports/demo.vtt`, not a sidecar
        // buried back in the bundle it trimmed from.
        let chaptersURL = chapters
            ? outputURL.deletingPathExtension().appendingPathExtension("vtt")
            : nil

        do {
            let manifest = try await MovieExporter.export(
                bundle: bundle, edl: edl, scale: scale, to: outputURL, chaptersURL: chaptersURL,
                format: format, maxSizeBytes: maxSizeBytes)
            return .exported(manifest)
        } catch CompositionError.everythingCut {
            return .failure(AutomationError(
                code: .internalError,
                message: "The current trim removes the entire recording.",
                hint: "Widen the kept range with a `trim` request before exporting — "
                    + "there is nothing left of this recording to write."))
        } catch CompositionError.noVideoTrack {
            return .failure(AutomationError(
                code: .internalError,
                message: "The recording has no video track to export.",
                hint: "This bundle's capture.mov may be corrupt or incomplete."))
        } catch let error as ExportError {
            return .failure(AutomationError(
                code: .internalError,
                message: "The export failed.",
                hint: String(describing: error)))
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "The export failed.",
                hint: String(describing: error)))
        }
    }

    /// Reads the bundle IN THE APP, not the client.
    ///
    /// The CLI cannot read `~/Desktop` — it is gated by the Files-and-Folders
    /// TCC service, which is exactly how M3a's health block silently reported
    /// nothing on every real machine. The app wrote the file and can read it.
    ///
    /// Deliberately NOT gated by `ConsentPolicy`: reading a bundle the agent
    /// was handed the path to discloses nothing it did not already have, and
    /// gating it would make an agent unable to describe its own recording.
    private func inspect(bundlePath: String) -> AutomationResponse {
        do {
            let bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
            return .inspected(try InspectReport.report(for: bundle))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Check the path from `snitt record stop`. It must be a "
                    + ".snitt bundle written by this app."))
        }
    }

    private func policy() -> ConsentPolicy {
        let current = settings()
        return ConsentPolicy(agentRecordingEnabled: current.agentRecordingEnabled,
                             fullDisplayAllowed: current.fullDisplayAllowed)
    }

    /// Shown when Screen Recording is not (yet) granted to an agent request.
    ///
    /// `CGRequestScreenCaptureAccess()` returns `false` even when the user grants
    /// permission in the dialog it just raised — the grant only takes effect on
    /// the NEXT launch of Snitt (verified on macOS 26.5.2, spike S5). Saying
    /// "permission denied" here would be actively wrong for the person who just
    /// did the right thing: it must read as "grant it and relaunch", not as a
    /// refusal.
    private static let permissionDeniedError = AutomationError(
        code: .permissionDenied,
        message: "Snitt does not have permission to record the screen yet.",
        hint: "Open Snitt, grant Screen Recording permission in System Settings "
            + "when prompted (or manually under Privacy & Security), then relaunch "
            + "Snitt. The grant does not take effect until Snitt is relaunched.")

    private func listTargets() async -> AutomationResponse {
        // Enumeration is gated too: an agent that may not record has no business
        // learning what windows are open.
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }

        // Enumerating `SCShareableContent` returns nothing useful, and never
        // raises the system prompt, unless access has been explicitly ensured
        // first — this project has shipped that exact defect three times.
        // `CachedTargetResolver`/`RecordingCoordinator` do this on the hotkey
        // path; this is the equivalent guarantee for the agent path.
        let granted = await MainActor.run { ScreenRecordingAccess.ensureGranted() }
        guard granted else {
            return .failure(Self.permissionDeniedError)
        }

        do {
            let targets = try await CaptureTarget.headlessAvailable()
            return .targets(targets.map { target in
                let d = target.descriptor
                // The bundle identifier comes from the SCWindow rather than the
                // descriptor, which does not carry one. It has to be here: the
                // CLI's own `--app` flag takes a bundle id, so a listing without
                // one would advertise targets an agent cannot then record.
                var bundleID: String?
                if case .window(let window) = target {
                    bundleID = window.owningApplication?.bundleIdentifier
                }
                return TargetSummary(id: d.id, kind: d.kind, title: d.title,
                                     applicationName: d.applicationName,
                                     bundleIdentifier: bundleID)
            })
        } catch {
            return .failure(AutomationError(
                code: .permissionDenied,
                message: "Snitt could not list what is on screen.",
                hint: "This usually means Screen Recording permission is missing. "
                    + "Open Snitt and grant it, then relaunch Snitt."))
        }
    }

    private func start(_ options: StartOptions) async -> AutomationResponse {
        if let refusal = policy().evaluate(options) { return .failure(refusal) }

        let maxDuration = policy().effectiveMaxDuration(options.maxDurationSeconds)
        let sessionID: String
        do {
            sessionID = try await registry.open(maxDuration: maxDuration, now: Date())
        } catch let error as AutomationError {
            return .failure(error)
        } catch {
            return .failure(AutomationError(code: .internalError,
                                            message: "Could not open a session."))
        }

        let reference: TargetReference
        if let bundleID = options.bundleIdentifier {
            reference = .window(bundleIdentifier: bundleID, titleHint: nil)
        } else if let displayID = options.displayID {
            reference = .display(id: displayID)
        } else {
            try? await registry.close(sessionID)
            return .failure(AutomationError(code: .targetNotFound,
                                            message: "No target was specified."))
        }

        // Resolved here, not in the coordinator: only the CLIENT knows which
        // repository a recording is about (§7). Snitt.app's own cwd is "/".
        let git = options.workingDirectory
            .map { URL(fileURLWithPath: $0) }
            .flatMap { resolveGit($0) }

        // The agent's audio choices, which used to stop at the wire: nothing
        // read `options.microphone`, so `--mic` was a no-op end to end and
        // `health.micRMS` could only ever be nil.
        // Read at record time rather than cached at launch, so toggling the
        // menu item takes effect on the next recording without a relaunch.
        let captureOptions = CaptureOptions(captureMicrophone: options.microphone,
                                            captureSystemAudio: options.systemAudio,
                                            logInputEvents: EventLoggingSettings.load().enabled)

        let outcome = await coordinator.startForAgent(sessionID: sessionID,
                                                      reference: reference,
                                                      git: git,
                                                      options: captureOptions)
        switch outcome {
        case .started(let name, _):
            await pushState(.recording(startedAt: Date()))
            armWatchdog(sessionID: sessionID, after: maxDuration)
            return .started(sessionID: sessionID, target: name)
        default:
            try? await registry.close(sessionID)
            return .failure(Self.error(for: outcome))
        }
    }

    private func mark(sessionID: String, label: String?) async -> AutomationResponse {
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }
        switch await coordinator.markForAgent(sessionID: sessionID, label: label) {
        case .marked(let offset):
            return .marked(timeSeconds: offset)
        case .notCurrentSession, .notRecording:
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No recording with that session id.",
                hint: "Markers can only be added to a recording you started. "
                    + "Check `snitt status` for the current session."))
        }
    }

    /// Maps a coordinator outcome to the agent-facing contract (§10).
    ///
    /// Every non-started outcome used to become `target_not_found`/14 with the
    /// hint "the application may not be running". Two of them were actively
    /// misleading: a missing Screen Recording grant — the ordinary first-run
    /// state — sent an agent chasing a process that was running fine, and a
    /// human's hotkey recording in progress read as a missing window instead of
    /// `already_recording`.
    static func error(for outcome: CoordinatorOutcome) -> AutomationError {
        switch outcome {
        case .failed(_, .permissionDenied):
            return permissionDeniedError
        case .ignored, .failed(_, .alreadyRecording):
            // `.ignored` means a start or stop was already in flight — from the
            // agent's side that is indistinguishable from, and remediated the
            // same way as, a recording already running.
            return AutomationError(
                code: .alreadyRecording,
                message: "A recording is already in progress.",
                hint: "Stop it first with `snitt record stop`, or check `snitt status`. "
                    + "It may have been started by a person from the menu bar.")
        case .failed(let message, .targetTooSmall):
            // Its own arm because the generic hint — "the application may not be
            // running" — is exactly the wrong advice here: the app IS running.
            return AutomationError(
                code: .targetNotFound,
                message: message,
                hint: "Snitt will not record a window smaller than 100×100 on either "
                    + "axis, because a palette or tooltip is never what was meant. "
                    + "Resize the window, or record a display if a person has "
                    + "allowed full-display agent recording.")
        case .failed(_, .targetUnavailable), .cancelled:
            return AutomationError(
                code: .targetNotFound,
                message: "Could not start recording that target.",
                hint: "Check `snitt targets list` — the application may not be running.")
        case .failed(let message, .internalError):
            return AutomationError(code: .internalError,
                                   message: "Could not start recording that target.",
                                   hint: message)
        case .started, .stopped:
            return AutomationError(code: .internalError,
                                   message: "Could not start recording that target.")
        }
    }

    /// §5.3's session cap, enforced rather than merely reported.
    ///
    /// The cap was computed, stored and queryable, and nothing ever acted on it:
    /// `expiredSession(now:)` had no production caller. Snitt is a resident
    /// menu-bar app that never quits on its own, so an agent that crashes after
    /// `record start` left `AVAssetWriter` writing until the disk filled.
    ///
    /// Two independent guards stop this from ever ending someone ELSE's
    /// recording. The task is cancelled on a normal stop, and even if a stale
    /// one runs, `stopForAgent(sessionID:)` refuses unless the coordinator's
    /// active recording is still that exact session.
    private func armWatchdog(sessionID: String, after seconds: Double) {
        setWatchdog(Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.expire(sessionID)
        })
    }

    private func expire(_ sessionID: String) async {
        guard await registry.expiredSession(now: Date()) == sessionID else { return }
        switch await coordinator.stopForAgent(sessionID: sessionID) {
        case .stopped, .failed:
            // `.failed` still means the recording is OVER: `stopRecording()`
            // clears `active` before `recorder.stop()` can throw, so only
            // finalization failed. Leaving the indicator lit would be worse
            // than the defect this watchdog exists to fix — a person clicks the
            // menu bar to stop what looks like a live recording, `toggle()`
            // sees `active == nil`, and STARTS a new one through the picker.
            try? await registry.close(sessionID)
            await pushState(.idle)

        case .notCurrentSession:
            // Someone else's recording, or nothing at all. The registry entry
            // is stale; the indicator is not ours to clear.
            try? await registry.close(sessionID)

        case .busy:
            // Nothing stopped, so nothing may be forgotten — the cap must
            // survive a transition that was merely in flight. Matches `stop()`,
            // which preserves the session for the same reason.
            break
        }
    }

    /// Stops the agent's OWN session.
    ///
    /// Order matters: the registry entry is closed only after the coordinator
    /// confirms it stopped that session. The previous order closed the registry
    /// first and then stopped "whatever is recording", which meant this
    /// interleaving handed an agent a path to someone else's recording: agent
    /// starts S, a person stops S with the kill switch, the person starts their
    /// own recording R, the agent calls `record stop S` — and got R's bundle.
    private func stop(_ sessionID: String) async -> AutomationResponse {
        let result = await coordinator.stopForAgent(sessionID: sessionID)
        switch result {
        case .stopped(let url, _, let health):
            cancelWatchdog()
            try? await registry.close(sessionID)
            await pushState(.idle)
            return .stopped(bundlePath: url.path, health: health)

        case .notCurrentSession:
            // Either the id was never valid, or a person already ended it. Drop
            // the registry entry if it names this session so `snitt status` and
            // the next `record start` agree with reality — but stop nothing.
            cancelWatchdog()
            try? await registry.close(sessionID)
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No recording with that session id.",
                hint: "It may have been stopped from Snitt's menu bar. "
                    + "Check `snitt status` for the current session."))

        case .busy:
            return .failure(AutomationError(
                code: .internalError,
                message: "Snitt is busy starting or stopping a recording.",
                hint: "Try `snitt record stop` again in a moment."))

        case .failed(let message):
            cancelWatchdog()
            try? await registry.close(sessionID)
            await pushState(.idle)
            return .failure(AutomationError(code: .internalError,
                                            message: "The recording did not finalize.",
                                            hint: message))
        }
    }
}

extension AutomationHost {
    /// A host wired for tests that exercise `.trim`/`.export` only.
    ///
    /// Neither touches `coordinator` — they read and write a bundle already
    /// on disk, not the live recording machinery — so this factory hands
    /// them a coordinator that does nothing rather than forcing every such
    /// test to build a `FakeCoordinator` it will never call. A test that
    /// mixes trim/export with `.startRecording`/`.stopRecording`/`.mark`
    /// must construct `AutomationHost` directly with a real fake, the way
    /// `AutomationHostTests.swift` already does — `NullCoordinator` refuses
    /// every one of those on purpose, so such a test fails loudly instead of
    /// silently observing a no-op.
    static func forTesting() -> AutomationHost {
        AutomationHost(coordinator: NullCoordinator(),
                      settings: { AgentSettings(agentRecordingEnabled: true,
                                                fullDisplayAllowed: false) })
    }
}

/// Refuses every call. See `AutomationHost.forTesting()`.
private actor NullCoordinator: AgentRecordingControlling {
    func startForAgent(sessionID: String, reference: TargetReference,
                       git: GitContext?, options: CaptureOptions) async -> CoordinatorOutcome {
        .failed("NullCoordinator does not record — use a real fake for this test.",
               reason: .internalError)
    }

    func stopForAgent(sessionID: String) async -> AgentStopResult {
        .notCurrentSession
    }

    func markForAgent(sessionID: String, label: String?) async -> AgentMarkResult {
        .notRecording
    }
}
