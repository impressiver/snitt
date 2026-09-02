// THROWAWAY SPIKE CODE — spec section 14, S1. Do not build on this.
// Question: does global keystroke capture need Input Monitoring?
import AppKit

print("S1 probe. Type in ANOTHER app for 15 seconds.")
print("Input Monitoring currently granted: \(CGPreflightListenEventAccess())")

nonisolated(unsafe) var nsEventKeyCount = 0
nonisolated(unsafe) var nsEventMouseCount = 0
nonisolated(unsafe) var tapKeyCount = 0

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
    print("CGEventTap creation FAILED (likely needs Input Monitoring).")
}

Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
    print("--- RESULTS ---")
    print("NSEvent global keyDown events:  \(nsEventKeyCount)")
    print("NSEvent global mouseDown events: \(nsEventMouseCount)")
    print("CGEventTap keyDown events:       \(tapKeyCount)")
    print("Input Monitoring granted:        \(CGPreflightListenEventAccess())")
    exit(0)
}

RunLoop.main.run()
