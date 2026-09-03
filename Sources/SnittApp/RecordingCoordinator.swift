import Foundation
import AppKit
import SnittCapture
import SnittDocument
import SnittExport

public enum ResolverChoice: Equatable, Sendable {
    case picker
    case cache
}

public enum CoordinatorOutcome: Equatable, Sendable {
    case started(String, usedCache: Bool)
    case stopped(URL, copied: Bool)
    case cancelled
    case failed(String)
    /// A press arrived while a start or stop was already in flight; ignored.
    case ignored
}

/// Drives one recording from hotkey press to clipboard.
public actor RecordingCoordinator {
    private let pickerResolver: TargetResolver
    private let cachedResolverFactory: @Sendable (TargetReference) -> TargetResolver
    private let store: TargetStore
    private let outputDirectory: URL

    private var active: Recorder?

    /// Guards the whole transition, claimed before any suspension point.
    ///
    /// Actors are reentrant: without this, a second `toggle()` arriving while the
    /// first is suspended inside `resolve()` — which lasts seconds on the picker
    /// path — would also observe `active == nil` and start a second recording.
    /// Checking `active` alone is not enough, because it is not assigned until
    /// after the awaits complete.
    private var isTransitioning = false

    public init(pickerResolver: TargetResolver,
                cachedResolverFactory: @escaping @Sendable (TargetReference) -> TargetResolver,
                store: TargetStore,
                outputDirectory: URL) {
        self.pickerResolver = pickerResolver
        self.cachedResolverFactory = cachedResolverFactory
        self.store = store
        self.outputDirectory = outputDirectory
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
    /// Deliberately shares `startRecording()` and the same `isTransitioning`
    /// guard as the hotkey path: an agent request arriving mid-hotkey-press must
    /// not start a second recording, and the visible indicator and kill switch
    /// then apply to agent sessions for free (§5.3).
    public func startForAgent(reference: TargetReference) async -> CoordinatorOutcome {
        guard !isTransitioning else { return .ignored }
        isTransitioning = true
        defer { isTransitioning = false }
        guard active == nil else {
            return .failed("A recording is already in progress.")
        }
        return await startRecording(forcedResolver: cachedResolverFactory(reference))
    }

    public func toggle() async -> CoordinatorOutcome {
        guard !isTransitioning else { return .ignored }
        isTransitioning = true
        defer { isTransitioning = false }

        if active != nil { return await stopRecording() }
        return await startRecording()
    }

    private func startRecording(
        forcedResolver: TargetResolver? = nil
    ) async -> CoordinatorOutcome {
        // Screen Recording must be granted before ANY capture API returns real
        // content. Preflight only READS the current state; Request is what raises
        // the prompt and registers the app in System Settings' list.
        //
        // Spike S1 established this distinction the hard way: a probe that only
        // preflighted never prompted at all, and two runs were wasted before the
        // defect was found. The app had the same bug — it called SCShareableContent
        // and hoped, which is why it never appeared in System Settings.
        let granted = await MainActor.run {
            ScreenRecordingAccess.ensureGranted()
        }
        guard granted else { return .failed(Self.screenRecordingDeniedMessage) }

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
        let choice: ResolverChoice
        if let forcedResolver {
            resolver = forcedResolver
            choice = .cache // only affects `usedCache:` in the returned outcome
        } else {
            let stored = store.load()
            choice = Self.resolverChoice(hasCachedTarget: stored != nil)
            switch choice {
            case .cache:
                guard let stored, let reference = Self.reference(from: stored) else {
                    return .failed("The cached target could not be read.")
                }
                resolver = cachedResolverFactory(reference)
            case .picker:
                resolver = pickerResolver
            }
        }

        let target: ResolvedTarget
        do {
            target = try await resolver.resolve()
        } catch TargetResolutionError.cancelled {
            return .cancelled
        } catch TargetResolutionError.targetGone(let app) {
            // The cached app is gone. Clear the stale cache so the next press
            // offers the picker rather than failing again.
            try? store.clear()
            return .failed("\(app) is no longer available. Press again to pick a new target.")
        } catch {
            return .failed(Self.explain(error))
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

        let url = outputDirectory.appendingPathComponent(
            "Snitt-\(Int(Date().timeIntervalSince1970)).snitt"
        )
        do {
            let recorder = try Recorder(target: target, bundleURL: url)
            try await recorder.start()
            active = recorder
            return .started(target.descriptor.title ?? "screen",
                            usedCache: choice == .cache)
        } catch {
            return .failed("Could not start recording: \(error)")
        }
    }

    private func stopRecording() async -> CoordinatorOutcome {
        guard let recorder = active else { return .failed("Not recording.") }
        active = nil
        do {
            let bundle = try await recorder.stop()
            let copied = ClipboardDestination.copy(fileURL: bundle.captureURL,
                                                   to: .general)
            return .stopped(bundle.url, copied: copied)
        } catch {
            return .failed("Recording failed to finalize: \(error)")
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
}
