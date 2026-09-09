// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import ScreenCaptureKit

/// Owns both halves of the handoff: the continuation and the first outcome.
///
/// `SCContentSharingPicker` can signal more than once, and resuming a
/// `CheckedContinuation` twice is a runtime trap. Keeping the continuation
/// inside the actor — rather than beside it on the class — means one mechanism
/// guards both, and a late or duplicate callback cannot race a stale read.
/// It also handles an outcome that arrives BEFORE the continuation is armed, by
/// holding it until `arm` collects it.
actor PickerOutcomeBox {
    private var continuation: CheckedContinuation<ResolvedTarget, Error>?
    private var pending: Result<ResolvedTarget, TargetResolutionError>?
    private(set) var hasCompleted = false

    /// Stores the continuation, or resumes immediately if an outcome already arrived.
    func arm(_ continuation: CheckedContinuation<ResolvedTarget, Error>) {
        if let pending {
            resume(continuation, with: pending)
            self.pending = nil
            return
        }
        self.continuation = continuation
    }

    /// Accepts the FIRST outcome only. Returns false if one already arrived.
    @discardableResult
    func deliver(_ outcome: Result<ResolvedTarget, TargetResolutionError>) -> Bool {
        guard !hasCompleted else { return false }
        hasCompleted = true

        if let continuation {
            self.continuation = nil
            resume(continuation, with: outcome)
        } else {
            // Signalled before arming; arm() will collect this.
            pending = outcome
        }
        return true
    }

    /// Prepares the box for a new picker session.
    ///
    /// The resolver is long-lived — one instance serves the whole app — but the box
    /// is a one-shot latch. Without resetting it, the second `resolve()` would find
    /// `hasCompleted` already true, refuse to resume the continuation, and hang
    /// forever. Safe because the actor serialises this against `deliver`.
    func reset() {
        continuation = nil
        pending = nil
        hasCompleted = false
    }

    private func resume(_ continuation: CheckedContinuation<ResolvedTarget, Error>,
                        with outcome: Result<ResolvedTarget, TargetResolutionError>) {
        switch outcome {
        case .success(let target): continuation.resume(returning: target)
        case .failure(let error):  continuation.resume(throwing: error)
        }
    }
}

/// Presents the system window picker and returns what the human chose.
///
/// This is the only path that avoids the monthly re-consent prompt (§5.2) — and
/// it works only when a human is present to choose. There is no API to replay a
/// prior selection (V12); reuse goes through `CachedTargetResolver` instead, at
/// the cost of the prompt.
public final class PickerTargetResolver: NSObject, TargetResolver, @unchecked Sendable {
    private let allowedModes: SCContentSharingPickerMode
    private let box = PickerOutcomeBox()

    public init(allowedModes: SCContentSharingPickerMode = [.singleWindow,
                                                            .singleApplication]) {
        self.allowedModes = allowedModes
        super.init()
    }

    public func resolve() async throws -> ResolvedTarget {
        // FIRST, before anything else: the resolver is long-lived — one instance
        // serves the whole app — while the box is a one-shot latch. A stale latch
        // would make this call hang forever and wedge the coordinator.
        await box.reset()

        // Picker setup is system UI presentation and must happen on the main
        // actor; `resolve()` is called from inside an actor, so it otherwise runs
        // off-main.
        await MainActor.run {
            let picker = SCContentSharingPicker.shared
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = allowedModes
            picker.configuration = configuration
            picker.add(self)
            picker.isActive = true
        }
        defer {
            Task { @MainActor in
                let picker = SCContentSharingPicker.shared
                picker.remove(self)
                picker.isActive = false
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                // Arm before presenting, so an immediate callback has somewhere to go.
                await box.arm(continuation)
                // Re-fetch the singleton rather than capturing the outer `picker`,
                // which is not Sendable and would otherwise cross into this Task.
                SCContentSharingPicker.shared.present()
            }
        }
    }

    private func finish(_ outcome: Result<ResolvedTarget, TargetResolutionError>) {
        Task { await box.deliver(outcome) }
    }
}

extension PickerTargetResolver: SCContentSharingPickerObserver {
    public func contentSharingPicker(_ picker: SCContentSharingPicker,
                                     didUpdateWith filter: SCContentFilter,
                                     for stream: SCStream?) {
        var reference: TargetReference?
        var title: String?
        var applicationName: String?
        var processID: pid_t?

        // Derive a durable reference so the hotkey can reuse this target later.
        // Gated: these properties require macOS 15.2 and the floor is 15.0. Below
        // that the reference stays nil and every press shows the picker — degraded
        // but correct.
        //
        // The pid is read here for the same reason and with the same gate: it is
        // what `WindowFocuser` activates before capture starts (§4.13). Below
        // 15.2 there is no way to learn it from the filter, so the picker path
        // stays unfocusable there — the same degradation `reference` already
        // accepts.
        if #available(macOS 15.2, *) {
            if let window = filter.includedWindows.first {
                title = window.title
                applicationName = window.owningApplication?.applicationName
                if let bundleID = window.owningApplication?.bundleIdentifier {
                    reference = .window(bundleIdentifier: bundleID, titleHint: window.title)
                }
            } else if let app = filter.includedApplications.first {
                applicationName = app.applicationName
                reference = .window(bundleIdentifier: app.bundleIdentifier, titleHint: nil)
            }
            // One expression for both picker shapes — a single window, or a
            // whole application — so neither can be wired up without the other.
            processID = filter.includedWindows.first?.owningApplication?.processID
                ?? filter.includedApplications.first?.processID
        }

        // The picker hands back a finished filter but no descriptor, so the
        // dimensions come from the filter's own content rect.
        let size = filter.pixelDimensions
        let descriptor = CaptureTargetDescriptor(
            id: 0,
            kind: CaptureTargetDescriptor.Kind.window.rawValue,
            title: title,
            applicationName: applicationName,
            width: size.width,
            height: size.height,
            processID: processID
        )
        finish(.success(ResolvedTarget(filter: filter,
                                       descriptor: descriptor,
                                       reference: reference,
                                       provenance: .picker)))
    }

    public func contentSharingPicker(_ picker: SCContentSharingPicker,
                                     didCancelFor stream: SCStream?) {
        finish(.failure(.cancelled))
    }

    public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(.unavailable))
    }
}
