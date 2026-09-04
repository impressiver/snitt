import CoreGraphics
import Foundation
import SnittDocument

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
/// `@unchecked Sendable`: `tap`, `runLoop`, and `thread` are written only from
/// `start()`/`stop()`, both of which callers are expected to serialize (start
/// then stop, not concurrently); the event-tap callback only reads `tap` (to
/// re-enable it) and calls the `onEvent` closure, which is itself `@Sendable`.
/// No mutable state is written from the tap's own thread.
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
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    public init(onEvent: @escaping @Sendable (EventKind) -> Void) {
        self.onEvent = onEvent
    }

    /// Returns false if the tap could not be created — which is what a missing
    /// Input Monitoring grant looks like from here.
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

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false   // no Input Monitoring grant
        }
        self.tap = tap

        let thread = Thread { [weak self] in
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
        // has something to stop.
        _ = ready.wait(timeout: .now() + .seconds(2))
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    deinit { stop() }
}
