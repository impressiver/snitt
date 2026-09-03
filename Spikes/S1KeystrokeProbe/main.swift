// THROWAWAY SPIKE CODE — spec section 14, S1. Do not build on this.
// Question: does global keystroke capture need Input Monitoring?
//
// Revision 2. The first version produced all-zero counts including
// mouseDown, which was a probe defect rather than a measurement:
//   1. It called CGPreflightListenEventAccess() (a CHECK) but never
//      CGRequestListenEventAccess() (the call that raises the prompt), so
//      the grant dialog never appeared.
//   2. It ran a bare RunLoop with no NSApplication. AppKit global event
//      monitors are delivered through the application event machinery, so
//      without a running NSApp they never fire — which is why even
//      mouseDown, which historically does not require Input Monitoring,
//      counted zero.
import AppKit

nonisolated(unsafe) var nsEventKeyCount = 0
nonisolated(unsafe) var nsEventMouseCount = 0
nonisolated(unsafe) var tapKeyCount = 0

let grantedAtStart = CGPreflightListenEventAccess()
print("S1 probe (rev 2).")
print("Input Monitoring granted at start: \(grantedAtStart)")

if !grantedAtStart {
    // THIS is the call that raises the system prompt. Preflight only reads
    // the current state. Note macOS shows this at most once per responsible
    // process; after a denial it must be enabled by hand in System Settings.
    print("Requesting Input Monitoring access (a prompt may appear)...")
    let requested = CGRequestListenEventAccess()
    print("CGRequestListenEventAccess() returned: \(requested)")
}

// Run as a real (accessory) application. Global monitors require this.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { _ in
    nsEventKeyCount += 1
}
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
    nsEventMouseCount += 1
}

let mask = (1 << CGEventType.keyDown.rawValue)
if let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(mask),
    callback: { _, _, event, _ in
        tapKeyCount += 1
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) {
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("CGEventTap created successfully.")
} else {
    print("CGEventTap creation FAILED (needs Input Monitoring).")
}

print("")
print(">>> NOW: switch to another app, then TYPE and CLICK for 15 seconds. <<<")

Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
    print("--- RESULTS ---")
    print("NSEvent global keyDown events:   \(nsEventKeyCount)")
    print("NSEvent global mouseDown events: \(nsEventMouseCount)")
    print("CGEventTap keyDown events:       \(tapKeyCount)")
    print("Input Monitoring granted at end: \(CGPreflightListenEventAccess())")
    exit(0)
}

app.run()
