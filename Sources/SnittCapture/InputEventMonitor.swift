import CoreGraphics
import Foundation
import SnittDocument
import os

/// Logs THAT input happened, never what (§4.2, and this milestone's ruling).
///
/// Uses `CGEventTap` in listen-only mode. Spike S1 established this is the API
/// gated by Input Monitoring; `NSEvent.addGlobalMonitorForEvents` needs
/// Accessibility and measured zero keyDown events even when Input Monitoring
/// was granted.
///
/// Runs its run loop on a dedicated thread rather than the main one: attaching
/// to the main run loop would stall event capture whenever the app shows a
/// modal sheet, which the permission-onboarding flow legitimately does.
///
/// While the tap is installed it holds a strong (`Unmanaged.passRetained`)
/// reference to `self` — see `retained` below. One consequence: `deinit` will
/// not fire while the tap is running, so a caller that calls `start()` and
/// never `stop()` leaks a thread and a mach port rather than crashing.
/// `stop()` is therefore mandatory, not merely tidy — Task 4 wires this into
/// `Recorder`, whose `stop()` always runs.
///
/// `@unchecked Sendable`: the tap's callback runs concurrently with whatever
/// thread calls `start()`/`stop()`. `tap` is the only state the callback
/// reads, and it is guarded by `tapLock` (`OSAllocatedUnfairLock`, matching
/// `HotkeyMonitor`'s pattern) so a `stop()` racing an in-flight callback
/// cannot observe a torn value. `retained`, `thread`, and `runLoop` are
/// written only from `start()`/`stop()`, which callers are expected to
/// serialize (start then stop, not concurrently) — same as before. `onEvent`
/// is itself `@Sendable`.
public final class InputEventMonitor: @unchecked Sendable {
    /// The types worth waking the callback for. Kept in lockstep with
    /// `kind(for:)` — a mask wider than the mapping wakes us for nothing on
    /// every keypress, and a mask narrower than it silently drops events.
    public static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.leftMouseDown.rawValue)
      | (1 << CGEventType.rightMouseDown.rawValue)

    /// Nil for anything that must not become a log entry.
    ///
    /// Key UP is excluded so one keystroke is one event — M3c's `--auto-trim`
    /// reasons about event density. The tap-disabled notifications arrive
    /// through this same callback and are control messages, not input.
    public static func kind(for type: CGEventType) -> EventKind? {
        switch type {
        case .keyDown: return .keystroke
        case .leftMouseDown, .rightMouseDown: return .click
        default: return nil
        }
    }

    private let onEvent: @Sendable (EventKind) -> Void
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    /// Signalled once the tap thread's body has returned.
    ///
    /// `CFMachPortInvalidate` stops NEW callbacks being dispatched but does not
    /// wait for one already running — and the click that stops a recording is
    /// itself a logged event, so that window is entered on nearly every stop.
    /// Once `CFRunLoopRun()` has returned, no callback can be in flight,
    /// because that run loop is what dispatches them.
    ///
    /// Optional and recreated per `start()` rather than a single `let`, so the
    /// wait in `stop()` can never block when there is nothing to wait for: it
    /// is non-nil only between a `start()` that launched a thread and the
    /// `stop()` that joins it. A stop before start, or a second stop, finds
    /// nil and skips the wait entirely. A single shared semaphore would also
    /// accumulate a stale count across a start/stop/start cycle, letting a
    /// later wait return without the thread having finished.
    private var finished: DispatchSemaphore?

    /// `CFMachPort` isn't `Sendable`; this box is `@unchecked` because access
    /// only ever happens through `tapLock`, which is the actual synchronization.
    private struct TapBox: @unchecked Sendable {
        var value: CFMachPort?
    }

    /// Guards `tap` against the tap-thread callback reading it while
    /// `start()`/`stop()` write it from the caller's thread.
    private let tapLock = OSAllocatedUnfairLock<TapBox>(initialState: TapBox(value: nil))
    private var tap: CFMachPort? {
        // The closure passed to `withLock` must capture and return only
        // `Sendable` values — `TapBox` (not the raw `CFMachPort` inside it)
        // is what crosses that boundary.
        get { tapLock.withLock { $0 }.value }
        set {
            let box = TapBox(value: newValue)
            tapLock.withLock { $0 = box }
        }
    }

    /// The +1 the tap's `userInfo` holds on us.
    ///
    /// `passUnretained` would let the caller's last reference drop while an
    /// event is in flight, and the callback would then resurrect a
    /// deallocated object — a use-after-free, not a data race. The tap keeps
    /// us alive for exactly as long as it is installed; `stop()` invalidates
    /// the port and then JOINS the tap thread, so no callback can still be
    /// running, and only then releases. Invalidation alone is not enough —
    /// see `finished`.
    private var retained: Unmanaged<InputEventMonitor>?

    public init(onEvent: @escaping @Sendable (EventKind) -> Void) {
        self.onEvent = onEvent
    }

    /// Returns false if the tap could not be created — which is what a missing
    /// Input Monitoring grant looks like from here — or if the tap's run loop
    /// never came up within the timeout, in which case whatever was created is
    /// torn down before returning so a caller never has to guess whether
    /// `start()` left something dangling.
    public func start() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputEventMonitor>
                .fromOpaque(userInfo).takeUnretainedValue()

            // macOS disables a tap whose callback runs long, and says so only
            // through this callback. Without re-enabling, the tap goes quiet
            // for the rest of the recording and nothing reports it.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            if let kind = InputEventMonitor.kind(for: type) {
                monitor.onEvent(kind)
            }
            // Listen-only: the event is always passed through untouched.
            return Unmanaged.passUnretained(event)
        }

        // Hand the tap a +1 on us instead of an unretained pointer — see
        // `retained`'s doc comment. Released below if tapCreate fails, and in
        // `stop()` once the port is invalidated.
        let retained = Unmanaged.passRetained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()   // a failed start must not leak the +1
            return false   // no Input Monitoring grant
        }
        self.retained = retained
        self.tap = tap

        // Captured strongly (not through `self`) so EVERY exit from the thread
        // body signals, including the early `guard let self` return. A path
        // that skipped the signal would make `stop()` burn its whole timeout.
        let finished = DispatchSemaphore(value: 0)
        self.finished = finished

        let thread = Thread { [weak self] in
            defer { finished.signal() }
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.impressiver.snitt.input-events"
        thread.start()
        self.thread = thread

        // Wait for the run loop to exist so a stop() immediately after start()
        // has something to stop. If it never shows up, don't hand back `true`
        // with a dangling thread/tap/retain — tear down and report failure.
        guard ready.wait(timeout: .now() + .seconds(2)) == .success else {
            stop()
            return false
        }
        return true
    }

    /// Uninstalls the tap and joins its thread.
    ///
    /// BLOCKS ITS CALLER briefly — normally microseconds, at most one second.
    /// That is deliberate. Invalidating the mach port stops new callbacks from
    /// being dispatched but does NOT synchronise with one already executing, so
    /// releasing the tap's `+1` without joining the thread can free this object
    /// out from under a running callback. That is not a rare interleaving: the
    /// menu-bar click that stops a recording is itself a logged event, so the
    /// callback is typically mid-flight at exactly this moment.
    ///
    /// The caller is `Recorder.stop()`, running on the recorder actor's
    /// executor. A few milliseconds of blocked executor at the end of a
    /// recording is the right trade against a use-after-free.
    ///
    /// Joining the run loop also removes the old `runLoop` write race: the
    /// thread has finished by the time this returns, so nothing can still be
    /// assigning `self.runLoop`.
    public func stop() {
        // Order matters: invalidate the port FIRST so no further callback can
        // begin, stop the run loop, WAIT for the thread to leave it, and only
        // then release the +1 the tap held. Releasing before the join is the
        // use-after-free this fixes.
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil

        if let runLoop { CFRunLoopStop(runLoop) }

        // Bounded: a wedged tap thread must not hang the recorder's stop. On
        // timeout we proceed, which is no worse than the old unconditional
        // behaviour. Nil whenever no thread was ever launched (stop before
        // start, or a second stop), so this can never block on nothing.
        if let finished {
            _ = finished.wait(timeout: .now() + .seconds(1))
        }
        finished = nil
        runLoop = nil
        thread = nil

        retained?.release()
        retained = nil
    }

    deinit { stop() }
}
