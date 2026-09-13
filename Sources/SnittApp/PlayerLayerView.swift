// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import AppKit
import SnittExport
import SwiftUI

/// The video surface. An `AVPlayerLayer` is required regardless of UI
/// framework (§4.7), so it is reached through AppKit rather than approximated
/// in SwiftUI.
public struct PlayerLayerView: NSViewRepresentable {
    public let player: AVPlayer
    /// Click positions as FRACTIONS of the picture, empty when clicks are off
    /// or the recording has none.
    public var clickMarks: [ClickMark]
    public var cues: [SubtitleCue]
    public var banners: [MarkerBanner]

    public init(player: AVPlayer, clickMarks: [ClickMark] = [],
                cues: [SubtitleCue] = [], banners: [MarkerBanner] = []) {
        self.player = player
        self.clickMarks = clickMarks
        self.cues = cues
        self.banners = banners
    }

    public func makeNSView(context: Context) -> PlayerLayerBackedView {
        let view = PlayerLayerBackedView()
        view.playerLayer.player = player
        view.clickMarks = clickMarks
        view.cues = cues
        view.banners = banners
        return view
    }

    public func updateNSView(_ nsView: PlayerLayerBackedView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
        nsView.clickMarks = clickMarks
        nsView.cues = cues
        nsView.banners = banners
    }
}

public final class PlayerLayerBackedView: NSView {
    let playerLayer = AVPlayerLayer()
    private let clickOverlay = ClickRingOverlayView()
    private let textOverlay = OverlayTextView()
    private var timeObserver: Any?

    var cues: [SubtitleCue] = [] {
        didSet { textOverlay.cues = cues; refreshOverlayVisibility() }
    }
    var banners: [MarkerBanner] = [] {
        didSet { textOverlay.banners = banners; refreshOverlayVisibility() }
    }

    /// Marks to draw, and whether a time observer is needed at all.
    ///
    /// Observing is attached only while there is something to draw: an empty
    /// list means clicks are off or the recording has none, and a periodic
    /// observer firing 30 times a second to redraw nothing is a cost paid by
    /// every document for a feature most of them are not using.
    var clickMarks: [ClickMark] = [] {
        didSet {
            clickOverlay.marks = clickMarks
            clickOverlay.isHidden = clickMarks.isEmpty
            refreshOverlayVisibility()
        }
    }

    /// One observer for all three overlays, attached only while at least one
    /// has something to draw. Three observers would fire three redraws per
    /// tick for a document using all three, and none of them cheap.
    private func refreshOverlayVisibility() {
        textOverlay.isHidden = cues.isEmpty && banners.isEmpty
        let anything = !clickMarks.isEmpty || !cues.isEmpty || !banners.isEmpty
        anything ? startObservingTime() : stopObservingTime()
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyWellColour()
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer

        clickOverlay.videoRect = { [weak self] in self?.playerLayer.videoRect ?? .zero }
        clickOverlay.autoresizingMask = [.width, .height]
        clickOverlay.frame = bounds
        clickOverlay.isHidden = true
        addSubview(clickOverlay)

        textOverlay.videoRect = { [weak self] in self?.playerLayer.videoRect ?? .zero }
        textOverlay.autoresizingMask = [.width, .height]
        textOverlay.frame = bounds
        textOverlay.isHidden = true
        addSubview(textOverlay)
    }

    /// `AVPlayer` keeps its observers alive, so one left attached goes on
    /// firing against a player whose view is gone. Torn down when the view
    /// leaves the window rather than in `deinit`, which cannot touch main-actor
    /// state — and re-attached below if the view comes back, so a re-hosted
    /// editor does not silently stop drawing.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopObservingTime() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refreshOverlayVisibility() }
    }

    private func startObservingTime() {
        guard timeObserver == nil, let player = playerLayer.player else { return }
        // 1/30s: a ring lives for 0.6s, so this is ~18 steps through its
        // expansion — smooth enough to read as motion without asking for a
        // callback per display refresh.
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            self?.clickOverlay.currentTime = time.seconds
            self?.textOverlay.currentTime = time.seconds
        }
    }

    private func stopObservingTime() {
        guard let observer = timeObserver else { return }
        playerLayer.player?.removeTimeObserver(observer)
        timeObserver = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A `CGColor` is a resolved value, not a dynamic one, so a layer
    /// background does NOT follow the appearance the way a view's would. This
    /// is the hook that re-resolves it — without it the well keeps whichever
    /// theme was active when the window opened, and switching appearance
    /// leaves a black surround on a light desktop.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWellColour()
    }

    private func applyWellColour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = EditorChromePalette.mediaWell.cgColor
        }
    }
}
