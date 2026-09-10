// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SwiftUI
import SnittDocument

/// The lane labels down the left of the timeline, with a gain meter on each
/// audio track.
///
/// SwiftUI beside the timeline rather than drawn inside it, for the reason the
/// marker editor is a sheet: `TimelineView` is a raw `NSView` whose x-axis is
/// time, and carving a gutter out of it would shift every geometry calculation
/// that maps a second to a pixel. Laying the gutter out from the SAME
/// `TimelineLanePlan` the timeline spends keeps the rows aligned without the
/// two views having to agree about anything else.
struct TimelineGutter: View {
    let plan: TimelineLanePlan
    let trackStates: [TrackState]
    let onGain: (String, Double) -> Void
    let onMute: (String, Bool) -> Void

    static let width: Double = 78

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.lanes.enumerated()), id: \.offset) { _, lane in
                row(for: lane)
                    .frame(height: lane.height)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .background(EditorChromePalette.timelineSurface)
    }

    @ViewBuilder
    private func row(for lane: TimelineLanePlan.Lane) -> some View {
        switch lane.lane {
        case .marks: label("Marks")
        case .video: label("Video")
        case .transcript: label("Words")
        case .audioComposite:
            // A composite band is two sources in one lane, so there is no
            // single gain to offer — adjusting it would silently move only one
            // of them. The label says what happened instead.
            label("Audio ×\(trackStates.count)")
        case .audio(let track):
            if let state = trackStates.first(where: { $0.track == track }) {
                GainMeterView(
                    title: TransportBar.name(of: track),
                    gain: state.gain,
                    muted: state.muted,
                    onGain: { onGain(track, $0) },
                    onToggleMute: { onMute(track, !state.muted) })
            } else {
                label(TransportBar.name(of: track))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
    }
}

/// A digital VU ladder that also sets the gain.
///
/// Read AND write in one control, because they are one thing: the level you
/// are looking at is the level you are adjusting, and a separate slider
/// somewhere else makes you check two places to answer one question. This
/// replaces a popover that had lost the gain slider entirely and offered only
/// mute — a regression rather than a relocation.
struct GainMeterView: View {
    let title: String
    let gain: Double
    let muted: Bool
    let onGain: (Double) -> Void
    let onToggleMute: () -> Void

    private var lit: Int { muted ? 0 : GainMeter.litSegments(forGain: gain) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button(action: onToggleMute) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help(muted ? "Unmute \(title)" : "Mute \(title)")
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            ladder
            Text(muted ? "Muted" : GainMeter.label(forGain: gain))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(muted ? .tertiary : .secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .help("Drag the ladder to set \(title)'s gain")
    }

    /// Segments, not a continuous bar: the point of a digital VU is that you
    /// can count where you are and return to it, which a smooth fill cannot
    /// give you.
    private var ladder: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(0..<GainMeter.segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(colour(for: index))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard geometry.size.width > 0 else { return }
                    onGain(GainMeter.gain(
                        forFraction: value.location.x / geometry.size.width))
                })
        }
        .frame(height: 8)
    }

    private func colour(for index: Int) -> Color {
        guard index < lit else { return Color.secondary.opacity(0.18) }
        // Hot above unity, because that is where amplification — and therefore
        // clipping — begins, which is the one thing a meter exists to warn
        // about. Below it the ladder is quiet on purpose.
        return GainMeter.isHot(segment: index)
            ? EditorChromePalette.currentHighlight
            : Color.accentColor.opacity(0.85)
    }
}
