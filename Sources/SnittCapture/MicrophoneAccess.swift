// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation

/// The one place Snitt asks for Microphone permission (§4.10 rung 2).
///
/// Mirrors `ScreenRecordingAccess`/`InputMonitoringAccess` deliberately:
/// preflight READS the grant, request RAISES the dialog. Code that only
/// preflights silently measures nothing — a mistake made three times in this
/// project before each service was given a single home and a conformance
/// test.
///
/// `AVCaptureDevice.requestAccess` differs from the other two services' C
/// APIs in one respect that matters here. `CGRequestScreenCaptureAccess()`
/// and `CGRequestListenEventAccess()` return `false` SYNCHRONOUSLY, even
/// while the user is still looking at the dialog they just raised (spike
/// S5's finding, documented on `ScreenRecordingAccess`). AVFoundation's
/// completion handler, by contrast, only fires once the user has actually
/// answered, on a queue Apple does not document as the main queue — bridging
/// that into a synchronous return by blocking on a semaphore would risk
/// deadlocking the very dialog it is waiting on if that completion happens
/// to land back on this thread. So `ensureGranted` keeps the SAME external
/// contract the other two services already have — fire the request, return
/// `false` immediately — rather than actually waiting for the answer.
///
/// This does not strand the ladder: the grant, once the user responds, shows
/// up in `isGranted()` on the very next call. No relaunch is needed here,
/// unlike Screen Recording and Input Monitoring — AVFoundation reports
/// Microphone authorization live, not only at the next process launch — so a
/// second toggle after the user answers reads the real state.
public enum MicrophoneAccess {
    /// Reads the current grant without raising any dialog.
    public static func isGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @discardableResult
    public static func ensureGranted() -> Bool {
        if isGranted() { return true }
        // Only the first ask actually raises the system dialog — macOS
        // shows it once per app. Calling `requestAccess` again after
        // `.denied`/`.restricted` is harmless (it calls back immediately
        // with `false` and shows nothing), but gating it here keeps this
        // branch honest as the ONLY one that ever raises UI.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        return false
    }
}
