import AppKit
import Carbon.HIToolbox

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
    private let combination: HotkeyCombination
    private let onFire: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    public private(set) var isRegistered = false

    public init(combination: HotkeyCombination, onFire: @escaping () -> Void) {
        self.combination = combination
        self.onFire = onFire
    }

    public func start() throws {
        guard !isRegistered else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>
                .fromOpaque(userData).takeUnretainedValue()
            monitor.onFire()
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else { throw HotkeyError.registrationFailed(status) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_5454), id: 1) // 'SNTT'
        let registerStatus = RegisterEventHotKey(
            combination.keyCode, combination.modifiers, hotKeyID,
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
