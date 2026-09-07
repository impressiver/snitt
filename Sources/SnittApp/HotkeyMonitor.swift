import AppKit
import Carbon.HIToolbox
import os

public struct HotkeyCombination: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Option-Command-5. Deliberately near ⌘⇧5, the system recorder's shortcut,
    /// without colliding with it.
    public static let defaultCombination = HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_5),
        modifiers: UInt32(optionKey | cmdKey)
    )

    /// Option-Command-M — "mark". Distinct from the record combination so the
    /// two never collide (§4.12).
    public static let markerCombination = HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(optionKey | cmdKey)
    )
}

public enum HotkeyError: Error, Equatable {
    case registrationFailed(OSStatus)
}

/// A global hotkey that needs no permission.
///
/// Deliberately Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`. Spike S1 measured global `NSEvent`
/// keyDown at zero even with Input Monitoring granted, because AppKit global
/// key monitors are gated by **Accessibility** — a broader grant, and one more
/// users refuse. `RegisterEventHotKey` registers one combination with the
/// window server and requires no TCC grant at all, which is what lets the
/// hotkey work inside §4.10's one-dialog first-run budget.
public final class HotkeyMonitor {
    private static let idCounter = OSAllocatedUnfairLock(initialState: UInt32(0))

    /// Hands out a fresh hotkey id per registration.
    ///
    /// Previously every monitor used `id: 1`. Combined with a callback that
    /// never checked which hotkey fired, a second monitor made BOTH callbacks
    /// run on either keypress — so adding a marker hotkey would have started a
    /// recording too.
    public static func nextHotKeyID() -> UInt32 {
        idCounter.withLock { value in value += 1; return value }
    }

    /// Not `private`: `HotkeyRegistrar.combination(for:)` (D55) reads this
    /// back to report what is ACTUALLY registered, as distinct from what
    /// `HotkeySettings` merely has stored — the distinction M5b's R22 defect
    /// shows matters.
    public let combination: HotkeyCombination
    private let onFire: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    public let hotKeyID: UInt32 = HotkeyMonitor.nextHotKeyID()

    public private(set) var isRegistered = false

    public init(combination: HotkeyCombination, onFire: @escaping () -> Void) {
        self.combination = combination
        self.onFire = onFire
    }

    /// Invoked by the Carbon callback with the id that actually fired.
    func handle(hotKeyID firedID: UInt32) {
        guard firedID == hotKeyID else { return }
        onFire()
    }

    /// What Carbon should be told after inspecting a fired hotkey id.
    ///
    /// `noErr` means "handled" and STOPS propagation to other handlers on the
    /// same target. Two monitors share one application event target, so a
    /// monitor that ignored an id must return eventNotHandledErr or it eats
    /// the other monitor's hotkey — which is exactly how the marker hotkey
    /// silently broke ⌥⌘5 once both were installed: the marker's handler ran
    /// first, correctly did nothing for a foreign id, then returned noErr and
    /// swallowed the press before the record handler ever saw it.
    static func dispatchResult(firedID: UInt32, matching ownID: UInt32) -> OSStatus {
        firedID == ownID ? noErr : OSStatus(eventNotHandledErr)
    }

    /// The identifier this monitor registers with Carbon.
    ///
    /// Extracted so a test can assert the registration uses the INSTANCE id.
    /// The original defect was a hard-coded `id: 1` here, which the allocator
    /// being correct did nothing to prevent — two monitors then registered the
    /// same identifier and each fired on the other's keypress.
    var registrationID: EventHotKeyID {
        EventHotKeyID(signature: OSType(0x534E_5454), id: hotKeyID) // 'SNTT'
    }

    public func start() throws {
        guard !isRegistered else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            // Every early exit below returns eventNotHandledErr, never noErr.
            // noErr tells Carbon "handled" and STOPS the event propagating to
            // other handlers on the same application event target — where the
            // other monitor's handler lives. Returning noErr for an event this
            // handler didn't actually act on swallows it before the other
            // monitor gets a turn.
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var firedID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            // Without this, a failed read leaves firedID zero-initialised and the
            // routing below would depend on ids never being 0 — true today only
            // because nextHotKeyID() pre-increments. Depend on the check, not on
            // that coincidence.
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<HotkeyMonitor>
                .fromOpaque(userData).takeUnretainedValue()
            let result = HotkeyMonitor.dispatchResult(firedID: firedID.id, matching: monitor.hotKeyID)
            monitor.handle(hotKeyID: firedID.id)
            return result
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else { throw HotkeyError.registrationFailed(status) }

        let registerStatus = RegisterEventHotKey(
            combination.keyCode, combination.modifiers, registrationID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            // Undo the handler installed moments ago, so start() is all-or-nothing.
            // Without this, a caller retrying after a failed registration installs a
            // SECOND handler and orphans the first — which still holds a non-owning
            // pointer to self and would dereference freed memory once this object is
            // released, crashing inside a C callback with no Swift stack.
            if let handlerRef {
                RemoveEventHandler(handlerRef)
                self.handlerRef = nil
            }
            throw HotkeyError.registrationFailed(registerStatus)
        }

        isRegistered = true
    }

    public func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        isRegistered = false
    }

    deinit { stop() }
}
