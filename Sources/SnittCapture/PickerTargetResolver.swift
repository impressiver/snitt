import Foundation
import ScreenCaptureKit

/// Guards continuation resumption.
///
/// `SCContentSharingPicker` can signal more than once — a cancel following an
/// update, for instance. Resuming a Swift continuation twice is a runtime trap,
/// so every outcome funnels through here and only the first is accepted.
actor PickerOutcomeBox {
    private(set) var hasCompleted = false

    /// Returns true if this outcome was accepted, false if one already arrived.
    @discardableResult
    func deliver(_ outcome: Result<ResolvedTarget, TargetResolutionError>) -> Bool {
        guard !hasCompleted else { return false }
        hasCompleted = true
        stored = outcome
        return true
    }

    private(set) var stored: Result<ResolvedTarget, TargetResolutionError>?
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
    private var continuation: CheckedContinuation<ResolvedTarget, Error>?

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
            self.continuation = continuation
            picker.present()
        }
    }

    private func finish(_ outcome: Result<ResolvedTarget, TargetResolutionError>) {
        Task {
            guard await box.deliver(outcome) else { return }
            guard let continuation else { return }
            self.continuation = nil
            switch outcome {
            case .success(let target): continuation.resume(returning: target)
            case .failure(let error):  continuation.resume(throwing: error)
            }
        }
    }
}

extension PickerTargetResolver: SCContentSharingPickerObserver {
    public func contentSharingPicker(_ picker: SCContentSharingPicker,
                                     didUpdateWith filter: SCContentFilter,
                                     for stream: SCStream?) {
        // The picker hands back a finished filter but no descriptor, so the
        // dimensions come from the filter's own content rect.
        let rect = filter.contentRect
        let scale = filter.pointPixelScale
        let descriptor = CaptureTargetDescriptor(
            id: 0,
            kind: CaptureTargetDescriptor.Kind.window.rawValue,
            title: nil,
            applicationName: nil,
            width: Int(rect.width * CGFloat(scale)),
            height: Int(rect.height * CGFloat(scale))
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
