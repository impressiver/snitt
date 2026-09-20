// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittBrand
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
                    track: track,
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
    /// The track this ladder controls, which decides its colour. Separate from
    /// `title`, which is what a HUMAN calls the track — a display string is
    /// the wrong key for a palette lookup, and translating one would put the
    /// colour at the mercy of the wording.
    let track: String
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
                        // Unity is two-thirds up a −24…+12 scale, not in the
                        // middle, and nothing on the ladder said where it was:
                        // "is this track boosted or cut" was a question you had
                        // to count segments to answer.
                        .overlay(alignment: .top) {
                            if index == GainMeter.unitySegment {
                                SnittPalette.Swatch.playheadInk
                                    .frame(height: 1)
                                    .opacity(muted ? 0.28 : 0.9)
                            }
                        }
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
        // No em dashes. Every tooltip in the app reads `label (how)`, so a
        // lane's reads that way too even though its "how" is a gesture rather
        // than a key.
        .help(muted
              ? "\(title) is muted (double-click to unmute)"
              : "\(title): \(GainMeter.label(forGain: gain)) "
                + "(drag to adjust, double-click to mute)")
    }

    /// Brand ink, the TRACK's own colour, brand red (rev 5, W13).
    ///
    /// The ladder used `Color.accentColor` for a lit segment — the user's
    /// selection colour, which on a blue-accented Mac put a blue meter beside
    /// an amber waveform measuring the same track. The arithmetic underneath
    /// (`GainMeter`) is untouched: this function only colours what
    /// `litSegments` and `isHot` decide.
    func colourForTesting(_ index: Int) -> Color { colour(for: index) }

    private func colour(for index: Int) -> Color {
        guard index < lit else { return SnittPalette.Swatch.ink3.opacity(muted ? 0.28 : 1) }
        // Hot at and above unity, because that is where amplification — and so
        // clipping — begins, which is the one thing a meter exists to warn
        // about. Red REGARDLESS of track: clipping is damage rather than
        // identity, and a teal "hot" would be a warning that only some tracks
        // get to give.
        //
        // No muted variant here, deliberately: `lit` is 0 while muted, so a
        // muted ladder never reaches this branch at all. A `muted ? …` here
        // looked symmetrical and was unreachable — the mutation gate found it
        // by removing it and nothing failing.
        if GainMeter.isHot(segment: index) { return SnittPalette.Swatch.recordRed }
        // Below unity, the ladder is the SAME colour as the waveform beside
        // it, because it is measuring that waveform. Amber for a recorded
        // source, teal for narration — one lookup, shared with the lane and
        // with the transcript's words.
        return SnittPalette.Swatch.track(track)
    }
}

#if DEBUG
// The VU ladders, previewed against the lane heights they have to line up
// with. "The vu meters should line up with the audio tracks they control,
// same height as the audio track" is a geometric claim, and this is where it
// is checkable without a recording open.
#Preview("Gutter — two tracks") {
    TimelineGutter(
        plan: TimelineLaneBudget.plan(availableHeight: 180,
                                      audioTracks: PreviewFixtures.audioTracks,
                                      hasTranscript: true),
        trackStates: PreviewFixtures.trackStates,
        onGain: { _, _ in }, onMute: { _, _ in })
        .frame(width: 30, height: 180)
        .background(EditorChromePalette.timelineSurface)
}

#Preview("Gutter — squeezed to the floor") {
    // The height at which the plan starts collapsing lanes. A gutter that
    // looks right at a comfortable size and overflows here is the bug this
    // preview exists to show.
    TimelineGutter(
        plan: TimelineLaneBudget.plan(availableHeight: TimelineLaneBudget.minimumTimelineHeight,
                                      audioTracks: PreviewFixtures.audioTracks,
                                      hasTranscript: true),
        trackStates: PreviewFixtures.trackStates,
        onGain: { _, _ in }, onMute: { _, _ in })
        .frame(width: 30, height: TimelineLaneBudget.minimumTimelineHeight)
        .background(EditorChromePalette.timelineSurface)
}

#Preview("Gain meter — boosted, unity, cut, muted, narration") {
    // Five ladders side by side, because the segment count is the whole
    // control and one ladder alone gives nothing to read it against. The last
    // is the synthesised voice, the only one that should not be amber.
    HStack(spacing: 8) {
        GainMeterView(title: "Mic", track: "microphone", gain: 2.0, muted: false,
                      onGain: { _ in }, onToggleMute: {})
        GainMeterView(title: "Mic", track: "microphone", gain: 1.0, muted: false,
                      onGain: { _ in }, onToggleMute: {})
        GainMeterView(title: "Sys", track: "systemAudio", gain: 0.35, muted: false,
                      onGain: { _ in }, onToggleMute: {})
        GainMeterView(title: "Sys", track: "systemAudio", gain: 1.0, muted: true,
                      onGain: { _ in }, onToggleMute: {})
        GainMeterView(title: "Synthesised", track: "voiceover", gain: 1.4, muted: false,
                      onGain: { _ in }, onToggleMute: {})
    }
    .frame(height: 70)
    .padding(12)
    .background(EditorChromePalette.timelineSurface)
}
#endif
