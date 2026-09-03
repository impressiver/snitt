import CoreGraphics

/// The one place Snitt asks for Screen Recording permission.
///
/// Preflight READS the current grant; Request RAISES the system dialog and
/// registers the app in System Settings' list. Code that only preflights
/// silently measures nothing — a mistake made three times in this project
/// before it was given a single home and a conformance test.
///
/// Note that `CGRequestScreenCaptureAccess()` returns `false` even when the
/// user grants permission in the dialog it raised: the grant takes effect on
/// the NEXT launch. Callers must report that as "relaunch Snitt", not as a
/// denial (spec §4.10). Verified on macOS 26.5.2 during spike S5.
public enum ScreenRecordingAccess {
    @discardableResult
    public static func ensureGranted() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
