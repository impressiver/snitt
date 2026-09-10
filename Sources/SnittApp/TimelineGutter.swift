// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SwiftUI
import SnittDocument

/// A narrow strip down the left of the timeline carrying one gain meter per
/// audio lane.
///
/// 30pt, and no lane labels. An earlier version was 78pt wide with a caption
/// on every row, which spent a tenth of the timeline's width on words that
/// repeat what the lanes already look like — a waveform does not need to be
/// captioned "Mic".
///
/// Laid out from the SAME `TimelineLanePlan` the timeline spends, so a meter
/// is exactly as tall as the band it controls and sits exactly beside it. It
/// lives outside `TimelineView` because that view's x-axis IS time: carving a
/// strip out of it would shift every second-to-pixel calculation there.
struct TimelineGutter: View {
    let plan: TimelineLanePlan
    let trackStates: [TrackState]
    let onGain: (String, Double) -> Void
    let onMute: (String, Bool) -> Void

    static let width: Double = 30

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.lanes.enumerated()), id: \.offset) { _, lane in
                row(for: lane).frame(height: lane.height)
            }
        }
        .frame(width: Self.width)
        .background(EditorChromePalette.timelineSurface)
    }

    @ViewBuilder
    private func row(for lane: TimelineLanePlan.Lane) -> some View {
        switch lane.lane {
        case .audio(let track):
            if let state = trackStates.first(where: { $0.track == track }) {
                GainMeterView(
                    title: TransportBar.name(of: track),
                    gain: state.gain,
                    muted: state.muted,
                    onGain: { onGain(track, $0) },
                    onToggleMute: { onMute(track, !state.muted) })
            } else {
                Color.clear
            }
        // A composite band is two sources in one lane, so there is no single
        // gain to offer — a meter there would silently move only one of them.
        case .marks, .video, .transcript, .audioComposite:
            Color.clear
        }
    }
}

/// A vertical digital VU ladder that also sets the gain.
///
/// Vertical because the lane is: it stands beside the waveform it controls, at
/// the same height, and reads the way every mixer meter does — quiet at the
/// bottom, hot at the top. The first version was horizontal, which made it a
/// bar that happened to sit near a track rather than a meter belonging to one.
///
/// Read AND write in one control, because they are one thing: the level you
/// are looking at is the level you are adjusting.
struct GainMeterView: View {
    let title: String
    let gain: Double
    let muted: Bool
    let onGain: (Double) -> Void
    let onToggleMute: () -> Void

    private var lit: Int { muted ? 0 : GainMeter.litSegments(forGain: gain) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 1) {
                // Top segment is the loudest, so the ladder is built in
                // reverse — `VStack` lays out downward and a meter reads
                // upward.
                ForEach((0..<GainMeter.segmentCount).reversed(), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(colour(for: index))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard geometry.size.height > 0 else { return }
                    // Inverted: dragging UP raises the gain, which is the only
                    // direction a vertical meter can mean.
                    let fraction = 1 - (value.location.y / geometry.size.height)
                    onGain(GainMeter.gain(forFraction: fraction))
                })
            .onTapGesture(count: 2) { onToggleMute() }
        }
        .help(muted
              ? "\(title) is muted — double-click to unmute"
              : "\(title): \(GainMeter.label(forGain: gain)) — drag to adjust, double-click to mute")
    }

    private func colour(for index: Int) -> Color {
        guard index < lit else { return Color.secondary.opacity(0.16) }
        // Hot at and above unity, because that is where amplification — and so
        // clipping — begins, which is the one thing a meter exists to warn
        // about.
        return GainMeter.isHot(segment: index)
            ? EditorChromePalette.currentHighlight
            : Color.accentColor.opacity(0.85)
    }
}
