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
        let picker = SCContentSharingPicker.shared

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = allowedModes
        picker.configuration = configuration

        picker.add(self)
        picker.isActive = true
        defer {
            picker.remove(self)
            picker.isActive = false
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
        // The picker hands back a finished filter but no descriptor, so the
        // dimensions come from the filter's own content rect.
        let size = filter.pixelDimensions
        let descriptor = CaptureTargetDescriptor(
            id: 0,
            kind: CaptureTargetDescriptor.Kind.window.rawValue,
            title: nil,
            applicationName: nil,
            width: size.width,
            height: size.height
        )
        finish(.success(ResolvedTarget(filter: filter,
                                       descriptor: descriptor,
                                       reference: nil,
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
