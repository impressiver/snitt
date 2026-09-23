// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreServices
import Foundation

/// Tells an open editor that its bundle changed on disk.
///
/// W7 made the window the one writer for a recording, and routed agent edits
/// INTO it rather than letting them write the files underneath. That is still
/// right, and it is not the whole world: a person can edit `events.json` in a
/// text editor, a script can rewrite `edit.json`, a Snitt on another machine
/// can sync one in. Before this, the window never noticed — it had to be closed
/// and reopened to re-read, which is what "point it at another bundle and back"
/// was working around.
///
/// **FSEvents, not a `DispatchSource` on the directory.** The first version
/// watched the bundle directory's vnode, which fires when an ENTRY appears or
/// disappears — a file created, deleted, or renamed over. That covers an atomic
/// replace and misses a plain in-place rewrite entirely, which is what `>` from
/// a shell, most editors' save-in-place, and a script opening the file for
/// writing all do. It passed its own test (which created a file) and did
/// nothing at all against a real edit, so the editor stayed exactly as stale as
/// before. `kFSEventStreamCreateFlagFileEvents` reports the modification itself,
/// however the writer made it.
final class BundleWatcher {
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "com.impressiver.snitt.bundle-watch")
    private let sink: Sink
    private var stopped = false

    /// - Parameter onChange: called on the main actor, already coalesced.
    ///   Coalescing matters: saving a recording rewrites several sidecars in
    ///   quick succession, and reconciling once per file would read a bundle
    ///   halfway through being written.
    init?(directory: URL, debounce: TimeInterval = 0.25,
          onChange: @escaping @MainActor () -> Void) {
        let sink = Sink(onChange: onChange)
        self.sink = sink

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().fire()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            // FileEvents: report the file that changed, not just the directory,
            // which is what makes an in-place rewrite visible at all.
            // NoDefer: the FIRST event in a quiet period arrives immediately
            // and the latency then coalesces the rest, so a single edit is not
            // held for the full window.
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
    }

    /// Idempotent, and it has to be: `stop()` and `deinit` both run in the
    /// ordinary case (a caller stops the watcher, then drops it), and releasing
    /// an `FSEventStreamRef` twice over-releases it — which crashes the
    /// process rather than raising anything catchable. The first version had
    /// both paths release unconditionally and took `SnittAppTests` down with
    /// it; the gate's own count check caught that, because a crashed test
    /// process still exits 0.
    func stop() {
        guard !stopped else { return }
        stopped = true
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}

/// Holds the callback across the C boundary, where only a raw pointer fits.
private final class Sink {
    private let onChange: @MainActor () -> Void
    init(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func fire() {
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }
}
