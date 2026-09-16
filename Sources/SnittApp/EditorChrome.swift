// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittBrand
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
                    .help("Crop the picture to the box you drew")
            } else if hasCrop {
                Button("Reset Crop", action: onResetCrop)
                    .help("Show the whole picture again")
            }

            Button(action: onExport) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: .command)
            .help("Write a video file — ⌘E")

            if hasTranscript {
                // A PANEL TOGGLE, not an action (rev 5, W3).
                //
                // It sat among Auto-Trim, Crop and Export wearing the same
                // clothes — three things that change the recording and one
                // that changes what you can see, all dressed identically.
                // Icon-only at the trailing edge, past a divider, is where
                // every Mac app puts its inspector toggle, and being there is
                // most of what tells you what it does.
                Divider().frame(height: 16)
                // Governs the whole side panel now — markers AND transcript,
                // as an accordion — rather than the transcript alone. The icon
                // never changed: `sidebar.trailing` is what it always was, and
                // the panel moving to the trailing edge is what finally makes
                // it true.
                Toggle(isOn: $showTranscript) {
                    Label("Panel", systemImage: "sidebar.trailing")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(showTranscript ? "Hide the markers and transcript panel"
                                     : "Show the markers and transcript panel")
                .accessibilityLabel("Markers and transcript panel")
                .accessibilityAddTraits(showTranscript ? [.isSelected] : [])
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        // 78pt clears the traffic lights, which now float over this row
        // rather than sitting in a strip above it (rev 5, W3).
        .padding(.leading, Self.trafficLightInset)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(minHeight: Self.height, alignment: .center)
        // This row is the titlebar now, and a titlebar you cannot drag the
        // window by is what would make `.fullSizeContentView` feel broken.
        // Nothing here has to arrange that: AppKit turns a press into a window
        // drag based on the hit view's `mouseDownCanMoveWindow`, and
        // `NSHostingView` already answers true — measured, not assumed, and
        // pinned by `TitlebarChromeTests` so a future wrapper view that
        // answers false is caught rather than discovered by dragging.
        .background(.bar)
    }

    /// Leading inset that clears the close/minimise/zoom buttons.
    static let trafficLightInset: Double = 78
    /// The chrome row's height — one deck, where there used to be two.
    static let height: Double = 38
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
    /// D93. The transport becomes a stop button while a take is running, and
    /// a recording indicator sits beside the clock.
    var isRecordingVoiceover: Bool = false
    var onStopVoiceover: () -> Void = {}
    let onTogglePlay: () -> Void
    let onNextMark: () -> Void
    let onSeekToTime: (String) -> Void
    let onCut: () -> Void

    @State private var timeText = ""
    @FocusState private var timeFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // LEFT-ALIGNED, and everything that can yield yields from the
            // right. On a narrow window the row used to squeeze whatever sat
            // in the middle, which is how a wrapped duration ended up looking
            // like a gap between the transport and the mark label.
            cluster
                .layoutPriority(2)
            timeField
            if let currentMark {
                // The agent-authored label, on screen, costing no vertical
                // space — the thing competitors do not have, and previously
                // reachable only by opening the chapters list.
                Label {
                    Text(currentMark)
                        .foregroundStyle(SnittPalette.Swatch.slateText)
                } icon: {
                    // The flag is amber because a mark is a moment in time,
                    // and the lane it came from draws it in the same colour.
                    Image(systemName: "flag.fill")
                        .foregroundStyle(SnittPalette.Swatch.signal)
                }
                .font(.caption)
                .lineLimit(1).truncationMode(.tail)
                // `minWidth: 0` so it is the FIRST thing to give up room: a
                // truncated mark label still says which mark you are in, and
                // it is the only item here that degrades gracefully.
                .frame(minWidth: 0, maxWidth: 240, alignment: .leading)
                .layoutPriority(-1)
                .help(currentMark)
            }
            Spacer(minLength: 8)
            scrollBar
            Button("Cut", systemImage: "scissors", action: onCut)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                // Red once it can actually remove something, slate while it
                // cannot — the one control here that destroys, saying so only
                // when it would.
                .foregroundStyle(canCut
                                 ? SnittPalette.Swatch.redBright
                                 : SnittPalette.Swatch.slateText.opacity(0.35))
                .disabled(!canCut)
                .help("Cut the selected range — Delete")
            zoomSlider
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The transport belongs to the INSTRUMENT, not to the chrome (rev 5,
        // W2). It was `.bar`, which follows the system appearance — so under
        // a light theme a pale strip appeared between light chrome above and
        // the permanently dark lanes below, which is the "two apps stapled
        // together" seam rev 4 named and did not close. The transport drives
        // the playhead that lives in those lanes; it is part of them.
        //
        // The ink3 hairline is drawn on the instrument's own side of the
        // join, under the chrome's `mediaEdge` separator, so the seam reads
        // as a machined edge rather than as two surfaces that happen to meet.
        .background(alignment: .top) {
            SnittPalette.Swatch.ink0
                .overlay(alignment: .top) {
                    SnittPalette.Swatch.ink3.frame(height: 1)
                }
        }
    }

    /// A tooltip that names its key by ASKING the registry, rather than
    /// repeating it (rev 5, W9).
    ///
    /// These read "Previous mark — ⌥←" and the arrow was typed here, a second
    /// copy of a binding `KeyboardShortcutRegistry` already owns and already
    /// renders into Help ▸ Keyboard Shortcuts. D84's whole point is that one
    /// list is the only place a binding is written down; a tooltip that
    /// hardcodes one is the drift that list exists to prevent, and it drifts
    /// silently — the button keeps working, it just starts lying about which
    /// key does it.
    ///
    /// `shortcutDisplay(titled:)` returns empty for a title nothing claims, so
    /// a renamed shortcut leaves the tooltip short rather than stale.
    static func help(_ label: String, _ registryTitle: String) -> String {
        let key = KeyboardShortcutRegistry.shortcutDisplay(titled: registryTitle)
        return key.isEmpty ? label : "\(label) — \(key)"
    }

    /// One rounded container, in the order the playhead moves. Grouping is the
    /// point: four loose buttons among nine others read as nine others.
    private var cluster: some View {
        HStack(spacing: 2) {
            transportButton("backward.end.fill",
                            Self.help("Back to start", "Back to Start"),
                            action: onRewind)
            transportButton("backward.frame.fill",
                            Self.help("Previous mark", "Previous Mark"),
                            enabled: hasMarks, action: onPreviousMark)
            // WHILE OVER-DUBBING THIS IS A STOP BUTTON, and it says so in red.
            //
            // The transport is the only control anyone looks at during a take,
            // and it previously showed an ordinary pause — identical to
            // playing the recording without recording anything, which is
            // exactly how "Record Voiceover just plays the video, nothing gets
            // recorded" gets reported about a feature that was working.
            //
            // Red rather than the brand's signal colour, because this is the
            // one state in the app where the machine is capturing you.
            Button(action: isRecordingVoiceover ? onStopVoiceover : onTogglePlay) {
                Image(systemName: isRecordingVoiceover
                      ? "stop.fill"
                      : (isPlaying ? "pause.fill" : "play.fill"))
                    .frame(width: 30, height: 22)
                    .foregroundStyle(isRecordingVoiceover ? Color.white
                                                          : SnittPalette.Swatch.ink0)
                    .background(isRecordingVoiceover ? Color.red
                                                     : SnittPalette.Swatch.signalBright,
                                in: RoundedRectangle(cornerRadius: 5))
            }
            .help(isRecordingVoiceover ? "Stop over-dubbing"
                                       : Self.help("Play or pause", "Play / Pause"))
            .accessibilityLabel(isRecordingVoiceover ? "Stop over-dubbing" : "Play or pause")
            // Not `.borderedProminent`: that draws in the system accent, which
            // is whatever colour the user picked for selection — so the one
            // filled control on the instrument would change meaning from Mac
            // to Mac, and sit next to amber marks in an unrelated hue.
            .buttonStyle(.plain)
            transportButton("forward.frame.fill",
                            Self.help("Next mark", "Next Mark"),
                            enabled: hasMarks, action: onNextMark)
        }
        .padding(3)
        .background(SnittPalette.Swatch.ink2, in: RoundedRectangle(cornerRadius: 8))
    }

    private func transportButton(_ symbol: String, _ help: String,
                                 enabled: Bool = true,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .foregroundStyle(enabled
                                 ? SnittPalette.Swatch.slateText
                                 : SnittPalette.Swatch.slateText.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// A field, not a label: typing a timecode gets you there without
    /// scrubbing for it.
    private var timeField: some View {
        HStack(spacing: 4) {
            TextField("", text: $timeText)
                // Still a real field — typing a timecode goes there — but
                // dressed as the tape counter it behaves like rather than as
                // a form control borrowed from a settings window.
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(SnittPalette.Swatch.clockAmber)
                .multilineTextAlignment(.center)
                .frame(width: 66)
                .padding(.vertical, 3)
                .background(SnittPalette.Swatch.ink1,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SnittPalette.Swatch.ink3, lineWidth: 1))
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
                .monospacedDigit()
                .foregroundStyle(SnittPalette.Swatch.slateText)
                // WITHOUT THESE IT WRAPS, one character per line. Reported
                // from a narrow window: "/ 0:32" came out as a four-row column
                // reading "/", "0", "3", "2", and the space it took pushed
                // everything after it sideways — read as a gap in the row
                // rather than as text breaking.
                //
                // A duration is one token. `lineLimit(1)` alone would truncate
                // it instead, which is the same information loss with a
                // tidier shape; `fixedSize` says it does not compress, so the
                // controls that CAN give up room are the ones that do.
                .lineLimit(1)
                .fixedSize()
        }
        // The counter is the one thing here that must never be squeezed: it
        // is the only readout of where the playhead is.
        .layoutPriority(1)
    }

    static func name(of track: String) -> String {
        switch track {
        case "microphone": return "Microphone"
        case "systemAudio": return "System audio"
        // The synthesised voice (D101), which is the only thing this track
        // carries now — a recorded take lands on the microphone (D102).
        case "voiceover": return "Synthesised"
        // The fallback returns the RAW name, so a track this does not know
        // labels its lane in lower case rather than not at all.
        // That is why the omission was invisible: the lane appeared, the meter
        // worked, and only the capitalisation said nobody had thought about it.
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
                    Capsule().fill(SnittPalette.Swatch.ink2)
                    Capsule()
                        .fill(SnittPalette.Swatch.slateText)
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
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(SnittPalette.Swatch.slateText)
            Slider(value: $zoomFraction, in: 0...1)
                .frame(width: 90)
                .controlSize(.mini)
                .tint(SnittPalette.Swatch.signal)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(SnittPalette.Swatch.slateText)
        }
        .help("Zoom the timeline")
    }
}

#if DEBUG
// The two bars the product owner rejected in their first form — "the timeline
// controls are in the wrong place and are unstyled", "transcript, crop, etc
// buttons in the wrong place and unstyled". Previewed at a fixed width,
// because both are horizontal layouts whose failure mode is crowding.
#Preview("Toolbar") {
    @Previewable @State var cropping = false
    @Previewable @State var transcript = true
    VStack(spacing: 0) {
        EditorToolbar(title: "Standup 2026-09-10", subtitle: "42s · 1512 × 982",
                      croppingActive: $cropping, showTranscript: $transcript,
                      hasTranscript: true, canApplyCrop: false, hasCrop: false,
                      trimCaption: "Auto-trim removed 5.9s",
                      onAutoTrim: { _ in }, onApplyCrop: {}, onResetCrop: {},
                      onExport: {})
        Divider()
    }
    .frame(width: 900)
}

#Preview("Toolbar — cropping, no transcript") {
    // The other half of the state space: a crop in progress, and a recording
    // that has never been transcribed, which is what disables the toggle.
    @Previewable @State var cropping = true
    @Previewable @State var transcript = false
    EditorToolbar(title: "Untitled recording", subtitle: "8s · 2560 × 1440",
                  croppingActive: $cropping, showTranscript: $transcript,
                  hasTranscript: false, canApplyCrop: true, hasCrop: true,
                  trimCaption: nil,
                  onAutoTrim: { _ in }, onApplyCrop: {}, onResetCrop: {},
                  onExport: {})
        .frame(width: 900)
}

#Preview("Transport — zoomed and scrollable") {
    // Zoomed in far enough that the scrollbar appears, which is the state the
    // scroll affordance was added for and the one a default preview hides.
    @Previewable @State var zoom = 0.62
    TransportBar(isPlaying: false, hasMarks: true,
                 currentTime: "00:19.50", totalTime: "00:36.10",
                 currentMark: "The bug", zoomFraction: $zoom,
                 isScrollable: true, visibleFraction: 0.35, scrollFraction: 0.4,
                 onScroll: { _ in }, canCut: true,
                 onRewind: {}, onPreviousMark: {}, onTogglePlay: {},
                 onNextMark: {}, onSeekToTime: { _ in }, onCut: {})
        .frame(width: 900)
}

#Preview("Transport — playing, whole timeline visible") {
    @Previewable @State var zoom = 0.0
    TransportBar(isPlaying: true, hasMarks: false,
                 currentTime: "00:04.00", totalTime: "00:36.10",
                 currentMark: nil, zoomFraction: $zoom,
                 isScrollable: false, visibleFraction: 1, scrollFraction: 0,
                 onScroll: { _ in }, canCut: false,
                 onRewind: {}, onPreviousMark: {}, onTogglePlay: {},
                 onNextMark: {}, onSeekToTime: { _ in }, onCut: {})
        .frame(width: 900)
}
#endif
