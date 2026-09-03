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

    /// Which resolver a hotkey press should use.
    ///
    /// The picker appears only when nothing is cached. Presenting it on every
    /// press would put a system dialog between a keystroke and a recording,
    /// every time, forever — which costs far more than the monthly re-consent
    /// prompt the cache path incurs (§4.11, D36).
    public static func resolverChoice(hasCachedTarget: Bool) -> ResolverChoice {
        hasCachedTarget ? .cache : .picker
    }

    public func toggle() async -> CoordinatorOutcome {
        guard !isTransitioning else { return .ignored }
        isTransitioning = true
        defer { isTransitioning = false }

        if active != nil { return await stopRecording() }
        return await startRecording()
    }

    private func startRecording() async -> CoordinatorOutcome {
        let stored = store.load()
        let choice = Self.resolverChoice(hasCachedTarget: stored != nil)

        let resolver: TargetResolver
        switch choice {
        case .cache:
            guard let stored, let reference = Self.reference(from: stored) else {
                return .failed("The cached target could not be read.")
            }
            resolver = cachedResolverFactory(reference)
        case .picker:
            resolver = pickerResolver
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

        if let reference = target.reference, let stored = Self.stored(from: reference) {
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
