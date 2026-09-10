// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SwiftUI
import SnittDocument

/// The editor's chrome: a document toolbar above the picture, and a transport
/// bar at the head of the timeline.
///
/// These exist because the previous arrangement put every control the editor
/// had — transport, destructive edits, crop mode, view controls — into one
/// undifferentiated `HStack` of default-styled buttons at the bottom of the
/// window. Adding the transport cluster to that row made it worse rather than
/// better: a control's meaning comes from what it sits next to, and everything
/// sitting next to everything says nothing.
///
/// The split is by WHAT A CONTROL ACTS ON. The toolbar acts on the document —
/// trim it, crop it, export it. The transport bar acts on the playhead, and
/// sits at the head of the timeline where the playhead lives.

// MARK: - Toolbar

/// Document-level actions. One accent-coloured control, and it is Export,
/// because that is the only thing here that ends the session.
struct EditorToolbar: View {
    let title: String
    let subtitle: String
    @Binding var croppingActive: Bool
    @Binding var showTranscript: Bool
    let hasTranscript: Bool
    let canApplyCrop: Bool
    let hasCrop: Bool
    let trimCaption: String?
    let onAutoTrim: (DeepTrimPreset) -> Void
    let onApplyCrop: () -> Void
    let onResetCrop: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.headline).lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let trimCaption {
                // Said next to the control that caused it, not stranded at the
                // far end of a button row where it reads as unrelated status.
                Text(trimCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 12)

            Menu {
                Button("Conservative") { onAutoTrim(.conservative) }
                Button("Default") { onAutoTrim(.default) }
                Button("Aggressive") { onAutoTrim(.aggressive) }
            } label: {
                Label("Auto-Trim", systemImage: "wand.and.stars")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Cut the spans where nothing happens")

            // Crop is a MODE, so it is a toggle, and its commit lives beside
            // it only while the mode is on — rather than three permanent
            // buttons, two of which do nothing most of the time.
            Toggle(isOn: $croppingActive) {
                Label("Crop", systemImage: "crop")
            }
            .toggleStyle(.button)
            .help("Draw a crop box on the picture")

            if croppingActive {
                Button("Apply", action: onApplyCrop)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApplyCrop)
            } else if hasCrop {
                Button("Reset Crop", action: onResetCrop)
            }

            if hasTranscript {
                Toggle(isOn: $showTranscript) {
                    Label("Transcript", systemImage: "text.alignleft")
                }
                .toggleStyle(.button)
                .help("Read the transcript beside the picture")
            }

            Button(action: onExport) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: .command)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Transport bar

/// Everything that moves the playhead, in one instrument, at the head of the
/// timeline the playhead lives in.
struct TransportBar: View {
    let isPlaying: Bool
    let hasMarks: Bool
    let currentTime: String
    let totalTime: String
    let currentMark: String?
    @Binding var zoomFraction: Double
    let isScrollable: Bool
    let visibleFraction: Double
    let scrollFraction: Double
    let onScroll: (Double) -> Void
    let canCut: Bool
    let onRewind: () -> Void
    let onPreviousMark: () -> Void
    let onTogglePlay: () -> Void
    let onNextMark: () -> Void
    let onSeekToTime: (String) -> Void
    let onCut: () -> Void

    @State private var timeText = ""
    @FocusState private var timeFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            cluster
            timeField
            if let currentMark {
                // The agent-authored label, on screen, costing no vertical
                // space — the thing competitors do not have, and previously
                // reachable only by opening the chapters list.
                Label(currentMark, systemImage: "flag.fill")
                    .font(.caption)
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 240, alignment: .leading)
                    .help(currentMark)
            }
            Spacer(minLength: 8)
            scrollBar
            Button("Cut", systemImage: "scissors", action: onCut)
                .labelStyle(.iconOnly)
                .disabled(!canCut)
                .help("Cut the selected range — Delete")
            zoomSlider
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// One rounded container, in the order the playhead moves. Grouping is the
    /// point: four loose buttons among nine others read as nine others.
    private var cluster: some View {
        HStack(spacing: 2) {
            transportButton("backward.end.fill", "Back to start — Home", action: onRewind)
            transportButton("backward.frame.fill", "Previous mark — ⌥←",
                            enabled: hasMarks, action: onPreviousMark)
            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .help("Play or pause — Space")
            transportButton("forward.frame.fill", "Next mark — ⌥→",
                            enabled: hasMarks, action: onNextMark)
        }
        .padding(3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func transportButton(_ symbol: String, _ help: String,
                                 enabled: Bool = true,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .disabled(!enabled)
        .help(help)
    }

    /// A field, not a label: typing a timecode gets you there without
    /// scrubbing for it.
    private var timeField: some View {
        HStack(spacing: 4) {
            TextField("", text: $timeText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 66)
                .focused($timeFocused)
                .onSubmit {
                    onSeekToTime(timeText)
                    timeFocused = false
                }
                .onChange(of: currentTime, initial: true) { _, new in
                    // Only while it is NOT being edited — otherwise the 20Hz
                    // playhead poll overwrites what is being typed, character
                    // by character.
                    if !timeFocused { timeText = new }
                }
            Text("/ \(totalTime)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    static func name(of track: String) -> String {
        switch track {
        case "microphone": return "Microphone"
        case "systemAudio": return "System audio"
        default: return track
        }
    }

    /// A scrollbar, shown only when there is something off screen.
    ///
    /// A thumb that always filled its track would say "there is nothing to
    /// scroll to" in the same shape as "you are at the start of something
    /// long", so the control is absent at 1x rather than inert.
    @ViewBuilder
    private var scrollBar: some View {
        if isScrollable {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.secondary)
                        .frame(width: max(24, geometry.size.width * visibleFraction))
                        .offset(x: (geometry.size.width
                                    - max(24, geometry.size.width * visibleFraction))
                                   * scrollFraction)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        guard geometry.size.width > 0 else { return }
                        onScroll(value.location.x / geometry.size.width)
                    })
            }
            .frame(width: 120, height: 6)
            .help("Drag to scroll the timeline")
        }
    }

    /// The affordance zoom never had. The ± buttons double per press, so
    /// crossing the range takes six clicks each way; the slider is logarithmic
    /// because zoom is multiplicative and a linear one would spend most of its
    /// travel at the far end.
    private var zoomSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoomFraction, in: 0...1)
                .frame(width: 90)
                .controlSize(.mini)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .help("Zoom the timeline")
    }
}
