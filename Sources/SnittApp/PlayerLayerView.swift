// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import AppKit
import SwiftUI

/// The video surface. An `AVPlayerLayer` is required regardless of UI
/// framework (§4.7), so it is reached through AppKit rather than approximated
/// in SwiftUI.
public struct PlayerLayerView: NSViewRepresentable {
    public let player: AVPlayer

    public init(player: AVPlayer) { self.player = player }

    public func makeNSView(context: Context) -> PlayerLayerBackedView {
        let view = PlayerLayerBackedView()
        view.playerLayer.player = player
        return view
    }

    public func updateNSView(_ nsView: PlayerLayerBackedView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

public final class PlayerLayerBackedView: NSView {
    let playerLayer = AVPlayerLayer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
