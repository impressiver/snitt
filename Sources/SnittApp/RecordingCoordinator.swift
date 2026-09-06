import Foundation
import AppKit
import os
import SnittCapture
import SnittDocument
import SnittExport

public enum ResolverChoice: Equatable, Sendable {
    case picker
    case cache
}

/// Why a coordinator operation failed, in a form a caller can branch on.
///
/// The `failed` message strings are UI text for the hotkey path — a person reads
/// them in an alert. An agent must never parse those; §10's contract is a code.
/// This carries the machine-readable half alongside the human-readable one, so
/// `AutomationHost` can map a failure to the right `AutomationError.Code`
/// instead of collapsing every outcome into `target_not_found`.
public enum FailureReason: Equatable, Sendable {
    /// Screen Recording is not granted (or was granted to a stale signature).
    case permissionDenied
    /// A recording is already running — including a human's hotkey recording.
    case alreadyRecording
    /// The named window/display could not be resolved on screen.
    case targetUnavailable
    /// The application is on screen, but every window of it is too small to be
    /// worth recording. Separate from `targetUnavailable` because the remedy is
    /// different: resize the window, or record a display.
    case targetTooSmall
    /// Anything else: writer setup, finalization, unexpected errors.
    case internalError
}

public enum CoordinatorOutcome: Equatable, Sendable {
    case started(String, usedCache: Bool)
    case stopped(URL, copied: Bool)
    case cancelled
    case failed(String, reason: FailureReason)
    /// A press arrived while a start or stop was already in flight; ignored.
    case ignored
}

/// The outcome of an agent's request to stop ITS OWN session.
public enum AgentStopResult: Equatable, Sendable {
    /// `health` is read from the `Recorder` actor itself, not from the bundle
    /// it just wrote: the CLI is a thin client (§4.9) and cannot read the
    /// app's output directory, which is `~/Desktop` by default and gated by
    /// the Files-and-Folders TCC service.
    case stopped(URL, copied: Bool, health: CaptureHealth?)
    /// Nothing is recording, or what IS recording is not that agent's session —
    /// typically because a person already stopped it with the kill switch and
    /// started their own. Never stop it: the bundle is not the agent's to take.
    case notCurrentSession
    /// A start or stop was already in flight; the caller may retry.
    case busy
    case failed(String)
}

/// The slice of `RecordingCoordinator` the automation surface actually uses.
///
/// Exists so `AutomationHost` can be tested without a live `SCContentFilter`,
/// which ScreenCaptureKit offers no way to construct off a real screen. Declared
/// here and adopted in `RecordingCoordinator`'s own declaration — not a
/// retroactive conformance.
/// The outcome of an agent's request to drop a marker into ITS OWN session.
public enum AgentMarkResult: Equatable, Sendable {
    case marked(Double)
    /// Nothing is recording, or the recording that is running was not started
    /// by an agent.
    case notRecording
    /// Something is recording, but not the session that asked.
    case notCurrentSession
}

public protocol AgentRecordingControlling: Sendable {
    func startForAgent(sessionID: String, reference: TargetReference,
                       git: GitContext?, options: CaptureOptions) async -> CoordinatorOutcome
    func stopForAgent(sessionID: String) async -> AgentStopResult
    func markForAgent(sessionID: String, label: String?) async -> AgentMarkResult
}

/// Drives one recording from hotkey press to clipboard.
public actor RecordingCoordinator: AgentRecordingControlling {
    private let pickerResolver: TargetResolver
    private let cachedResolverFactory: @Sendable (TargetReference) -> TargetResolver
    private let store: TargetStore
    private let outputDirectory: URL
    private let focuser: WindowFocuser
    /// Raises the Screen Recording grant, non-interactively.
    ///
    /// Injectable so the coordinator's own behaviour can be tested on a
    /// machine that has not granted it. Without this seam, two tests here
    /// asserted their property only when the grant happened to exist and
    /// passed vacuously otherwise — which is the same class of hole as the
    /// bugs they were written for.
    private let ensureAccess: @MainActor @Sendable () -> Bool

    private var active: Recorder?

    /// Guards the whole transition, claimed before any suspension point.
    ///
    /// Actors are reentrant: without this, a second `toggle()` arriving while the
    /// first is suspended inside `resolve()` — which lasts seconds on the picker
    /// path — would also observe `active == nil` and start a second recording.
    /// Checking `active` alone is not enough, because it is not assigned until
    /// after the awaits complete.
    private var isTransitioning = false

    /// The agent session that owns `active`, if an agent started it.
    ///
    /// Load-bearing for correctness, not bookkeeping. Without it, `record stop
    /// <id>` meant "stop whatever is recording": a person could stop the agent's
    /// recording with the kill switch, start their own, and the agent's stop
    /// would hand it their bundle path. Cleared by EVERY stop, so a
    /// human-initiated stop makes the id stale immediately.
    private var agentSessionID: String?

    /// Testing-only: makes the very NEXT `stopRecording()` overwrite the
    /// just-finalized `capture.mov` with garbage before the editor build is
    /// attempted. Simulates "the bundle is safe on disk, but unreadable"
    /// (Important 2 of Task 5) without ever exercising a REAL finalization
    /// failure — that is a different bug, covered by
    /// `RecorderTests.finalizationFailureSurfaces`.
    private var corruptCaptureAfterStopForTesting = false

    // `.compositor`, not `.capture`: the only site using this logs a failure
    // to BUILD THE PREVIEW after a recording finished successfully. Nothing
    // was being captured when it happened, and telling a support engineer
    // "capture fault" sends them to look at the recorder.
    private static let log = SnittLog.logger(.compositor, target: "SnittApp")

    public init(pickerResolver: TargetResolver,
                cachedResolverFactory: @escaping @Sendable (TargetReference) -> TargetResolver,
                store: TargetStore,
                outputDirectory: URL,
                focuser: WindowFocuser = .system,
                ensureAccess: @escaping @MainActor @Sendable () -> Bool
                    = { ScreenRecordingAccess.ensureGranted() }) {
        self.pickerResolver = pickerResolver
        self.cachedResolverFactory = cachedResolverFactory
        self.store = store
        self.outputDirectory = outputDirectory
        self.focuser = focuser
        self.ensureAccess = ensureAccess
    }

    /// The hotkey ALWAYS presents the system picker.
    ///
    /// This reverses the original design, which reused the last approved target so
    /// a press recorded immediately. Real use rejected it: silently re-selecting a
    /// previously chosen window is surprising, and choosing the target is exactly
    /// the moment a person decides what they are about to share with someone else.
    ///
    /// The trade is favourable in a way the original reasoning missed. Every
    /// recording now goes through `SCContentSharingPicker` rather than the
    /// `SCShareableContent` enumeration bypass, so macOS stops charging the app its
    /// recurring monthly re-consent prompt (§5.2). The cost is a picker between the
    /// keystroke and the recording; the gains are no recurring permission
    /// interruption and no chance of recording the wrong window.
    ///
    /// The cached-target machinery is retained, not deleted: the automation surface
    /// (M2b) has no human to drive a picker and still needs to re-resolve a stored
    /// reference.
    public static func resolverChoice(hasCachedTarget: Bool) -> ResolverChoice {
        .picker
    }

    /// Stops a recording if one is running; a no-op otherwise.
    ///
    /// Used on quit so a capture in progress is finished rather than abandoned.
    /// Respects the same transition guard as `toggle()`, so it cannot race a
    /// start that is still resolving.
    public func stopIfRecording() async -> CoordinatorOutcome? {
        guard !isTransitioning else { return nil }
        guard active != nil else { return nil }
        isTransitioning = true
        defer { isTransitioning = false }
        return await stopRecording()
    }

    /// Starts a recording on behalf of an agent, against an explicit target.
    ///
    /// Shares `startRecording()` and the same `isTransitioning` guard as the
    /// hotkey path: an agent request arriving mid-hotkey-press must not start a
    /// second recording, and one `Recorder` at a time is enforced in one place.
    ///
    /// What is shared: the transition guard, the coordinator, the permission
    /// preflight, the `Recorder`, and the kill switch (`toggle()` stops an agent
    /// recording exactly as it stops a human one).
    ///
    /// What is NOT shared, and what the caller must therefore still do: the
    /// menu-bar indicator. It is driven by the CALLER — `AppDelegate` updates
    /// `StatusItemController` from its own hotkey handler — so a caller that
    /// starts a recording here and does nothing else leaves the menu bar showing
    /// idle for the whole recording. §5.3 requires a visible indicator for the
    /// entire duration, so `AutomationHost` pushes state through its
    /// `onRecordingState` sink around every call to this method.
    /// - Parameter options: The agent's audio choices, straight from
    ///   `StartOptions`. These used to stop at the wire: `AutomationHost` never
    ///   read `--mic`, and `Recorder` was built with no `options:` at all, so
    ///   `CaptureOptions()`'s defaults applied, no microphone output was ever
    ///   added to the stream, and `health.micRMS` was necessarily nil.
    public func startForAgent(sessionID: String,
                              reference: TargetReference,
                              git: GitContext?,
                              options: CaptureOptions) async -> CoordinatorOutcome {
        guard !isTransitioning else { return .ignored }
        isTransitioning = true
        defer { isTransitioning = false }
        guard active == nil else {
            return .failed("A recording is already in progress.", reason: .alreadyRecording)
        }
        // An agent's demo is watched by a human too, so it auto-focuses just
        // like the hotkey path — there is no Shift key for an agent to hold.
        let outcome = await startRecording(forcedResolver: cachedResolverFactory(reference),
                                           suppressFocus: false, git: git,
                                           options: options)
        if case .started = outcome { agentSessionID = sessionID }
        return outcome
    }

    /// Stops a recording ONLY if it is the named agent session.
    ///
    /// The session check happens inside the actor, in the same critical section
    /// as the stop, so no interleaving can slip a human recording in between a
    /// caller's "is this still mine?" check and the stop itself.
    public func stopForAgent(sessionID: String) async -> AgentStopResult {
        guard !isTransitioning else { return .busy }
        guard agentSessionID == sessionID, let recorder = active else { return .notCurrentSession }
        isTransitioning = true
        defer { isTransitioning = false }
        switch await stopRecording() {
        case .stopped(let url, let copied):
            // `recorder` was captured above, before `stopRecording()` clears
            // `active` — this is the SAME actor instance that just finished
            // writing the bundle, so its in-memory metrics are still the
            // freshest source, and the only one the CLI can reach at all.
            let health = await recorder.capturedHealth()
            return .stopped(url, copied: copied, health: health)
        case .failed(let message, _):
            return .failed(message)
        default:
            return .failed("The recording did not finalize.")
        }
    }

    /// Drops a marker into the running agent recording (§4.12).
    ///
    /// Ownership is checked inside the actor, in the same critical section as
    /// the mark, for the same reason `stopForAgent` does: a marker landing in
    /// a human's recording because a stale session id was accepted is the same
    /// class of leak as returning them its bundle path.
    public func markForAgent(sessionID: String, label: String?) async -> AgentMarkResult {
        guard let recorder = active, agentSessionID != nil else { return .notRecording }
        guard agentSessionID == sessionID else { return .notCurrentSession }
        return .marked(await recorder.mark(label: label))
    }

    /// Marks whatever is recording, regardless of who started it (§4.12).
    ///
    /// The human counterpart to `markForAgent`: no session id to check, since a
    /// person pressing the marker hotkey means "mark this", full stop — there is
    /// no ownership ambiguity to resolve the way there is for an agent's request.
    @discardableResult
    public func markCurrentRecording(label: String?) async -> Double? {
        await active?.mark(label: label)
    }

    /// Whether a recording is running right now.
    ///
    /// Read by the hotkey caller so it only runs the human permission flow for
    /// a press that would START something — a press that stops a recording
    /// needs no grant and must never raise a sheet.
    public var isRecording: Bool { active != nil }

    public func toggle(suppressFocus: Bool = false) async -> CoordinatorOutcome {
        guard !isTransitioning else { return .ignored }
        isTransitioning = true
        defer { isTransitioning = false }

        if active != nil { return await stopRecording() }
        // The hotkey keeps today's capture defaults: system audio on,
        // microphone OFF. §4.10 rung 2 — the microphone prompt is paid only
        // when someone deliberately turns it on. Git context is nil because
        // Snitt.app's own working directory is "/"; only a client knows which
        // repository a recording is about (§7).
        var options = CaptureOptions()
        // Read at record time rather than cached at launch, so toggling the
        // menu item takes effect on the next recording without a relaunch.
        options.logInputEvents = EventLoggingSettings.load().enabled
        return await startRecording(forcedResolver: nil,
                                    suppressFocus: suppressFocus,
                                    git: nil,
                                    options: options)
    }

    /// No parameter has a default, deliberately, and for the reason
    /// `Recorder.init(initiator:)` gives: `git` defaulting to nil is how the
    /// whole git-provenance feature could have been silently omitted at a call
    /// site, and `options` defaulting is how `--mic` became a no-op. An
    /// omission must be a compile error, not a quietly wrong recording.
    private func startRecording(
        forcedResolver: TargetResolver?,
        suppressFocus: Bool,
        git: GitContext?,
        options: CaptureOptions
    ) async -> CoordinatorOutcome {
        // Screen Recording must be granted before ANY capture API returns real
        // content. Preflight only READS the current state; Request is what raises
        // the prompt and registers the app in System Settings' list.
        //
        // Spike S1 established this distinction the hard way: a probe that only
        // preflighted never prompted at all, and two runs were wasted before the
        // defect was found. The app had the same bug — it called SCShareableContent
        // and hoped, which is why it never appeared in System Settings.
        //
        // Deliberately NON-INTERACTIVE. The pre-explain and already-denied
        // sheets used to run here, inside the critical section both `toggle()`
        // and `startForAgent()` share and while `isTransitioning` is held. That
        // put an `NSAlert.runModal()` on someone's screen in response to an
        // agent's `snitt record start`, blocked the socket until a human
        // clicked it — with the kill switch disabled meanwhile — and made
        // `swift test` hang (or trap, with no `NSApplication`) on any machine
        // without the grant. The sheets now live in `AppDelegate`, the only
        // human-facing caller; an agent gets `permission_denied` over the
        // socket, which is a thing it can act on.
        let granted = await MainActor.run { ensureAccess() }
        guard granted else {
            return .failed(Self.screenRecordingDeniedMessage, reason: .permissionDenied)
        }

        // An agent names its target explicitly, so there is no picker to show and
        // no cache to consult — and consulting one is actively wrong: the store is
        // empty until the hotkey path has run at least once, which an agent has no
        // reason to have done. Bypassing the switch entirely (rather than applying
        // the forced resolver as an override AFTER it) is deliberate: the `.cache`
        // arm's `guard let stored` used to run unconditionally and return
        // `.failed("The cached target could not be read.")` before any override
        // could take effect, which broke every agent recording on a fresh
        // install — the store had never been written, so the guard always fired.
        // Everything downstream (permission preflight, resolution, the Recorder,
        // the indicator, the kill switch) still stays shared with the hotkey path.
        let resolver: TargetResolver
        let choice: ResolverChoice?
        if let forcedResolver {
            resolver = forcedResolver
            // An agent's target is named explicitly, so there is no
            // `ResolverChoice` to make at all — see `usedCache(choice:)`.
            choice = nil
        } else {
            choice = Self.resolverChoice(hasCachedTarget: store.load() != nil)
            // `resolverChoice` has returned `.picker` unconditionally since
            // M2a made the app always ask which window (every hotkey press
            // asks, even with a cached target), and `WindowFocuser` — the
            // only later consumer that could have needed the choice itself —
            // acts solely on the resolved target's descriptor, never on this
            // value. The `.cache` arm that used to sit here, reading the
            // store back with its own `guard let stored`, was therefore
            // unreachable and has been deleted along with that guard.
            resolver = pickerResolver
        }

        let target: ResolvedTarget
        do {
            target = try await resolver.resolve()
        } catch TargetResolutionError.cancelled {
            return .cancelled
        } catch TargetResolutionError.targetGone(let app) {
            // The cached app is gone. Clear the stale cache so the next press
            // offers the picker rather than failing again — but only on the
            // human's own path. The store is the human's cache of their last
            // hotkey-approved target, and the same reasoning that keeps an
            // agent from WRITING it (see below) keeps an agent's failed start
            // from ERASING it. An agent naming a window that is not open says
            // nothing about the human's last choice.
            if forcedResolver == nil { try? store.clear() }
            return .failed("\(app) is no longer available. Press again to pick a new target.",
                           reason: .targetUnavailable)
        } catch TargetResolutionError.targetTooSmall(let app) {
            // Deliberately does NOT clear the store: the target is not gone, it
            // is just unusably small, so the human's cached reference is still
            // the best guess for their next press.
            return .failed(
                "\(app) has no window larger than "
                    + "\(CachedTargetResolver.minimumWindowEdge)×"
                    + "\(CachedTargetResolver.minimumWindowEdge) to record.",
                reason: .targetTooSmall)
        } catch {
            return .failed(Self.explain(error), reason: Self.reason(for: error))
        }

        // Deliberately skipped for agent recordings: the store is the human's
        // cache of their own last hotkey-approved target, and an agent's
        // explicitly-named target is a separate track (§5.3). Writing it here
        // would let an agent silently overwrite what a human's next hotkey press
        // resolves against — surprising today, and load-bearing the moment
        // `resolverChoice` ever consults the cache again. An agent recording a
        // window does not imply a human wants that window recorded next time.
        if forcedResolver == nil,
           let reference = target.reference, let stored = Self.stored(from: reference) {
            try? store.save(stored)
        }

        // Before capture starts, never after: activating a window can dismiss a
        // menu or move a focus ring, and that transition must not be in the
        // recording (§4.13). Suppressed when the caller asked for it — recording
        // a window precisely because it is in the background is a real case.
        if !suppressFocus {
            _ = focuser.focus(descriptor: target.descriptor)
        }

        let url = outputDirectory.appendingPathComponent(
            BundleNaming.filename(git: git, timestamp: Int(Date().timeIntervalSince1970))
        )
        do {
            // Provenance is the one metadata field whose entire purpose is
            // telling agent recordings from human ones, and every recording was
            // stamped `.human` because `Recorder.init` defaults to it and
            // nothing ever passed otherwise. `forcedResolver != nil` IS the
            // agent path — an agent names its target explicitly, a human picks.
            let recorder = try Recorder(target: target, bundleURL: url,
                                        options: options,
                                        initiator: Self.initiator(isAgent: forcedResolver != nil),
                                        git: git)
            try await recorder.start()
            active = recorder
            return .started(target.descriptor.title ?? "screen",
                            usedCache: Self.usedCache(choice: choice))
        } catch {
            return .failed("Could not start recording: \(error)", reason: .internalError)
        }
    }

    private func stopRecording() async -> CoordinatorOutcome {
        // Cleared for EVERY stop, whatever initiated it. This is what makes a
        // kill-switch press invalidate the agent's session id rather than
        // leaving it pointing at whatever records next.
        agentSessionID = nil
        guard let recorder = active else {
            return .failed("Not recording.", reason: .internalError)
        }
        active = nil
        do {
            let bundle = try await recorder.stop()
            let copied = ClipboardDestination.copy(fileURL: bundle.captureURL,
                                                   to: .general)
            if corruptCaptureAfterStopForTesting {
                corruptCaptureAfterStopForTesting = false
                try? Data("not a movie".utf8).write(to: bundle.captureURL)
            }
            // Finding #5 of the M4a review: this `await` sits in front of
            // `.stopped` being returned, so a human hotkey stop now reports
            // completion only after the WHOLE composition build finishes —
            // `openEditorIfHuman` runs `CompositionBuilder.build`
            // end-to-end before `openEditor` even shows the window. At 1.0
            // scale on today's short clips that is unmeasurable, so it is
            // harmless now. It stops being harmless the moment M4b makes
            // builds heavier (scrubbing, overlays, longer recordings): the
            // hotkey's perceived "stop" latency grows with the build, not
            // with the actual stop. If that shows up, the fix is to let this
            // race the return rather than gate it — kick the build off and
            // resolve `.stopped` immediately — not to make the build itself
            // faster.
            await openEditorIfHuman(for: bundle)
            return .stopped(bundle.url, copied: copied)
        } catch {
            return .failed("Recording failed to finalize: \(error)", reason: .internalError)
        }
    }

    /// §9: "Stopping opens the editor with a default EDL spanning the full
    /// range." Never for an agent's recording — §4.8 scopes automation to
    /// record-only, and §5.3 exists because agent recordings happen with no
    /// human present. A window appearing on someone's screen because a
    /// background agent finished a capture is exactly the surprise the
    /// consent rules exist to prevent.
    ///
    /// The initiator is read FROM THE JUST-FINALIZED BUNDLE's metadata — the
    /// same stamp `Recorder` writes via `initiator(isAgent:)` — rather than
    /// from `agentSessionID`, which `stopRecording()` has already cleared by
    /// the time this runs.
    private func openEditorIfHuman(for bundle: SnittBundle) async {
        guard let metadata = try? RecordingMetadata.read(from: bundle),
              metadata.initiator == .human else { return }
        await openEditor(for: bundle)
    }

    /// Builds the preview and shows it. Best-effort: by this point the
    /// recording is finalized and safe on disk, and a build failure — an
    /// unreadable `capture.mov`, for instance — must surface as a log line,
    /// never take down a stop that has already succeeded. Losing a valuable,
    /// already-safe recording because a convenience (the preview) could not
    /// be built would be exactly backwards.
    private func openEditor(for bundle: SnittBundle) async {
        do {
            let edl = (try? EditDecisionList.read(from: bundle)) ?? .fullRange()
            let events = try EventLog.read(from: bundle).events
            let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
            let jumpPoints = MarkerJumpPoints.compute(events: events, keptRanges: built.keptRanges)
            await MainActor.run {
                let controller = PreviewController(built: built, jumpPoints: jumpPoints,
                                                    bundle: bundle, scale: 1.0)
                let editor = EditorWindowController(controller: controller,
                                                    title: bundle.url.lastPathComponent,
                                                    edl: edl, events: events)
                editor.show()
            }
        } catch {
            // The bundle's FILENAME is redacted deliberately: BundleNaming
            // derives it from the git branch and commit, so a branch called
            // `feat/acme-corp-integration` would name a customer or an
            // unreleased feature — and this line is collected verbatim into
            // `snitt diagnostics export`, which people attach to public
            // support threads (§5). The error itself is the diagnostic value;
            // the filename only correlates, and the operator can see it
            // unredacted in Console on their own machine.
            // NOT `String(describing: error)`: a Cocoa NSError renders its
            // userInfo, which carries NSFilePath and NSURL — the FULL
            // ABSOLUTE PATH, including the machine's username and the
            // branch-derived bundle name (BundleNaming, M3a). Measured:
            //   describing:    …UserInfo={NSFilePath=/Users/ian/…/feat-acme-corp-…}
            //   localized:     The file “edit.json” couldn’t be opened…
            // So the first route leaked exactly what redacting the filename
            // from this message was meant to stop, and this line is
            // collected verbatim into `snitt diagnostics export` (§5).
            //
            // domain+code is the precise identity a support engineer wants,
            // and localizedDescription names only fixed sidecar filenames.
            let ns = error as NSError
            Self.log.error("Could not open the editor: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shown when Screen Recording is not granted.
    ///
    /// macOS cannot grant this permission from the prompt itself — the dialog only
    /// offers to open System Settings — and the grant does not take effect until
    /// the app is RELAUNCHED. Saying so is the difference between a user who
    /// succeeds and one who toggles the switch, sees it still fail, and concludes
    /// the app is broken.
    static let screenRecordingDeniedMessage = """
        Snitt needs permission to record the screen.

        1. Open System Settings › Privacy & Security › Screen & System Audio Recording
        2. Switch Snitt on (if it is already listed and on, remove it with “−” and add it back — \
        macOS ties this permission to the app's signature, which changes when the app is rebuilt \
        with a different signing identity)
        3. Quit Snitt and open it again — macOS does not apply this permission until the app restarts
        """

    /// Turns an opaque capture failure into something a person can act on.
    ///
    /// ScreenCaptureKit reports a missing Screen Recording grant as -3801 with the
    /// text "The user declined TCCs for application, window, display capture" —
    /// alarming, and unactionable for someone who has already granted it.
    ///
    /// It also appears when the grant EXISTS but was issued to a different code
    /// identity. TCC keys permission to the app's signature, so any change of
    /// signing identity — ad-hoc to a certificate, or one certificate to another —
    /// silently invalidates the old grant while System Settings still shows the
    /// stale entry as enabled. That case looks identical to a denial and is the
    /// one most likely to confuse, so the message names it explicitly.
    /// The machine-readable twin of `explain(_:)`.
    ///
    /// Kept beside it so the two can never disagree: the -3801 case whose text
    /// says "does not have permission" must also report `.permissionDenied`.
    static func reason(for error: Error) -> FailureReason {
        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
           nsError.code == -3801 {
            return .permissionDenied
        }
        return .internalError
    }

    static func explain(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
           nsError.code == -3801 {
            return """
                Snitt does not have permission to record the screen.

                Open System Settings › Privacy & Security › Screen & System Audio \
                Recording and enable Snitt.

                If Snitt is already listed and switched on, remove it with the \
                “−” button and add it back. macOS ties this permission to the \
                app's signature, so a rebuild with a different signing identity \
                leaves the old entry looking enabled while the new build has no \
                access.
                """
        }
        return "Could not start recording: \(error.localizedDescription)"
    }

    /// Who a recording is attributed to in its metadata.
    ///
    /// An agent names its target explicitly and a human picks one, so a forced
    /// resolver IS the agent path — there is no other caller that supplies one.
    /// Extracted so the mapping itself is checkable: the call site cannot be,
    /// because reaching it needs a real `SCContentFilter`.
    static func initiator(isAgent: Bool) -> Initiator {
        isAgent ? .agent : .human
    }

    /// Whether the outcome's `usedCache` — the consent-explainer signal
    /// `main.swift`'s hotkey handler reads (§5) — should read true.
    ///
    /// `choice` is `nil` for an agent's forced resolver: an agent's target is
    /// always explicit, never the human's hotkey cache, so there is no
    /// `ResolverChoice` to make at all — not a `.picker` standing in for
    /// "not the cache." Only the human path's own choice can make this true,
    /// and today never does (`.cache` is unreachable — see `resolverChoice`'s
    /// doc comment). Extracted, like `initiator(isAgent:)` above, so the
    /// mapping itself is checkable: the call site cannot be, because reaching
    /// it needs a real `SCContentFilter`.
    static func usedCache(choice: ResolverChoice?) -> Bool {
        choice == .cache
    }

    static func reference(from stored: StoredTargetReference) -> TargetReference? {
        switch stored.kind {
        case .window:
            guard let bundleID = stored.bundleIdentifier else { return nil }
            return .window(bundleIdentifier: bundleID, titleHint: stored.titleHint)
        case .display:
            guard let id = stored.displayID else { return nil }
            return .display(id: id)
        }
    }

    static func stored(from reference: TargetReference) -> StoredTargetReference? {
        let kind: StoredTargetKind = reference.kind == .window ? .window : .display
        return StoredTargetReference(kind: kind,
                                     bundleIdentifier: reference.bundleIdentifier,
                                     titleHint: reference.titleHint,
                                     displayID: reference.displayID)
    }

    // MARK: - Testing seam

    /// Injects an already-configured `Recorder` as the active recording.
    ///
    /// `Recorder`'s own testing seam (`forTesting`/`startForTesting`/
    /// `feedForTesting`) is internal to `SnittCapture` and reachable only via
    /// `@testable import` from a test target — `SnittApp`'s production code,
    /// including this file, imports `SnittCapture` normally and cannot see
    /// it. So the CALLER (a test, via `@testable import SnittCapture`)
    /// builds and drives the `Recorder` up through a real, finalized bundle;
    /// this just wires the result in as `active`, exactly where
    /// `startRecording()` would have left it.
    func setActiveForTesting(_ recorder: Recorder) {
        active = recorder
    }

    /// Drives the exact production stop path — the same `stopRecording()`
    /// that `toggle()` and `stopForAgent()` call — against whatever was
    /// injected via `setActiveForTesting`. Exercises Task 5's actual
    /// decision points (branching on the bundle's stamped initiator, the
    /// best-effort build) rather than a stand-in for them.
    func stopForTesting() async throws -> SnittBundle {
        guard case .stopped(let stoppedURL, _) = await stopRecording() else {
            throw StopForTestingFailed()
        }
        return try SnittBundle(opening: stoppedURL)
    }

    /// Testing-only: makes the very next `stopRecording()` corrupt the
    /// finalized `capture.mov` before the editor build is attempted. See
    /// `corruptCaptureAfterStopForTesting`'s doc comment for why this
    /// simulates a DIFFERENT failure than a real finalization error.
    func corruptNextCaptureForTesting() {
        corruptCaptureAfterStopForTesting = true
    }

    private struct StopForTestingFailed: Error {}
}
