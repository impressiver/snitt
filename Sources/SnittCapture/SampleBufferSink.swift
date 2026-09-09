// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import CoreMedia

public enum SinkError: Error, Equatable {
    case notStarted
    case alreadyFinished
    case writerFailed(String)
}

/// The seam between capture and writing.
///
/// `CaptureSession` depends only on this protocol, so tests can drive the
/// full pipeline with synthetic sample buffers and no real screen
/// (spec section 15).
public protocol SampleBufferSink: AnyObject, Sendable {
    /// Starts a writing session at the first buffer's presentation time.
    func begin(at startTime: CMTime) throws

    /// Appends one buffer to one track. Must tolerate being called
    /// concurrently from ScreenCaptureKit's delivery queues.
    func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws

    /// Finalizes and returns the written file's location.
    func finish() async throws -> URL

    /// §12.1's metrics, gathered while buffers pass through. On the protocol
    /// rather than the concrete sink because `CaptureSession` only ever sees
    /// the protocol.
    var health: HealthSampler { get }
}
