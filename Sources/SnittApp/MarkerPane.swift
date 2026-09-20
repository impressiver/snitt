// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittBrand
import SwiftUI
import SnittDocument

/// One marker, as the chapter index presents it.
///
/// A view model rather than a `LoggedEvent`: the pane needs the marker's
/// position in OUTPUT time (where it lands in the edited recording, which is
/// what a click should seek to), and it needs a label to show even when the
/// marker has none. Neither belongs on the stored event.
struct MarkerChapter: Identifiable, Equatable {
    let id: UUID
    /// Position in the edited recording. For a marker inside a cut this is the
    /// FOLD the cut collapsed to — a real place the playhead can reach, which
    /// is why seeking to one works rather than being inert.
    let outputTime: Double
    /// Whether that position is a fold rather than a moment the viewer sees.
    let isInsideCut: Bool
    /// What to show. Falls back to "Marker N" so an unnamed marker is still
    /// addressable.
    let label: String
    /// Whether `label` came from the user or is the generated fallback —
    /// the fallback should not be pre-filled into a rename field, or renaming
    /// turns into editing the placeholder.
    let hasCustomLabel: Bool
    let transcript: String?
}

/// The chapter index: every marker in the recording, in order, as a
/// navigable list.
///
/// Markers already have a timeline lane, which shows WHERE they fall relative
/// to the audio and the cuts. That is what a lane is good at and what a list
/// cannot do. What a lane cannot do is show a marker's name and narration at
/// a glance, or let you scan a recording's structure without scrubbing — so
/// this pane exists alongside it rather than replacing it.
struct MarkerPane: View {
    @ObservedObject var state: EditorTimelineState
    /// OUTPUT time, polled by the editor shell — the same value the timeline
    /// draws its playhead at, so the two cannot disagree.
    let playhead: Double
    /// Opens the full marker editor (label + transcript). Inline renaming
    /// handles the common case; the sheet remains for narration text.
    let onEditMarker: (UUID) -> Void

    @State private var hoveredID: UUID?
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var editingTime = ""
    @FocusState private var editingFocused: Bool

    var body: some View {
        let chapters = state.chapters
        let currentID = state.currentChapterID(atOutputSeconds: playhead)
        VStack(alignment: .leading, spacing: 0) {
            if chapters.isEmpty {
                empty
            } else {
                list(chapters, currentID: currentID)
            }
        }
    }

    /// The "add a marker" button, for the accordion header to place.
    ///
    /// It moved OUT of this view when the rail became an accordion: the
    /// section header is the only header now, and a pane drawing a second one
    /// underneath it was two titles for one list. Still built here, because it
    /// needs `state` and the playhead and nothing else does.
    ///
    /// Marked `static`-ish in spirit but not in fact — it closes over the
    /// pane's own bindings, which is the whole reason it did not simply move
    /// to the call site.
    var addButton: some View {
        Button {
            state.addMarker(atOutput: playhead)
        } label: {
            Image(systemName: "plus")
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(KeyboardShortcutRegistry.tooltip(
            "Add a marker at the playhead",
            key: KeyboardShortcutRegistry.addMarkerTitle))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No markers yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Press + to mark the playhead, or press the marker key while recording.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(_ chapters: [MarkerChapter], currentID: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chapters) { chapter in
                        row(chapter, isCurrent: chapter.id == currentID)
                            .id(chapter.id)
                        Divider()
                    }
                }
            }
            // Follows only while PLAYING, matching `TranscriptPane`: scrolling
            // the index while someone is renaming a row would pull it out from
            // under them, and scrubbing already moves the playhead on purpose.
            .onChange(of: currentID) { _, id in
                guard let id, state.isPlaying else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// The current marker's amber wash outranks a hover: "this is where
    /// playback is" is a fact about the recording, and "the pointer is here"
    /// is a fact about the pointer.
    private func rowBackground(_ chapter: MarkerChapter, isCurrent: Bool) -> Color {
        if isCurrent {
            return EditorChromePalette.currentHighlight
                .opacity(EditorChromePalette.currentHighlightOpacity)
        }
        return hoveredID == chapter.id ? Color.primary.opacity(0.06) : .clear
    }

    @ViewBuilder
    private func row(_ chapter: MarkerChapter, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Amber, because a timecode is time (rev 5, W7). It was
                // `.secondary` — correct as chrome, and wrong as meaning: the
                // one thing in this row that says WHEN looked exactly like
                // the things that say what. A marker inside a cut keeps its
                // quieter treatment, since that is a different fact again.
                // Only while NOT editing. The edit row puts an editable time
                // field in the same place, so both were drawn: the amber
                // timestamp and a box containing the same number, side by
                // side, reading as two different times.
                if editingID != chapter.id {
                    Text(Self.timestamp(chapter.outputTime))
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(chapter.isInsideCut
                                         ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(SnittPalette.Swatch.amberText))
                }
                if editingID == chapter.id {
                    // The time is editable alongside the name: a chapter in the
                    // wrong place is as wrong as one with the wrong name, and
                    // dragging it on a zoomed-out timeline is a pixel-accurate
                    // gesture for a value the person already knows.
                    TextField("0:00", text: $editingTime)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 62)
                        .onSubmit { commit(chapter) }
                    TextField("Marker name", text: $editingText)
                        .textFieldStyle(.roundedBorder)
                        .focused($editingFocused)
                        .onSubmit { commit(chapter) }
                        // Clicking away keeps the edit rather than discarding
                        // it — the same choice the transcript's word editor
                        // makes, so the two do not behave differently.
                        .onChange(of: editingFocused) { _, focused in
                            if !focused, editingID == chapter.id { commit(chapter) }
                        }
                } else {
                    // Wraps rather than truncating: real marker labels are
                    // whole descriptive sentences, and a one-line clamp turns
                    // every one of them into the same opening few words.
                    Text(chapter.label)
                        .font(.callout)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(chapter.hasCustomLabel ? AnyShapeStyle(.primary)
                                                                : AnyShapeStyle(.secondary))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            if let transcript = chapter.transcript, !transcript.isEmpty, editingID != chapter.id {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if chapter.isInsideCut {
                Text("Inside a cut — shown at the fold")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(chapter, isCurrent: isCurrent))
        .contentShape(Rectangle())
        // A row has been clickable since M5f and has never looked it. The
        // hover wash and the pointing cursor are the whole of the fix.
        .onHover { hovering in
            hoveredID = hovering ? chapter.id : (hoveredID == chapter.id ? nil : hoveredID)
            // Guarded the same way `ResizableDivider` is: `push()`/`pop()` is
            // a stack, and a row that scrolls away or is deleted under the
            // pointer never reports the exit that would balance its push.
            // `hoveredID` is the flag, so the pair cannot go out of step.
            if hovering, hoveredID == chapter.id {
                NSCursor.pointingHand.push()
            } else if !hovering {
                NSCursor.pop()
            }
        }
        .onTapGesture(count: 2) { beginRename(chapter) }
        // `simultaneousGesture`, not a second `onTapGesture`. Two tap gestures
        // of different counts on one view make the single-tap one WAIT for the
        // double-tap one to fail before it can fire — the reported "half a
        // second before the playhead moves" is that timeout, not the seek,
        // which only pauses and hands an async seek to the player.
        //
        // Recognising simultaneously removes the wait. A double click then
        // both seeks and renames, in that order, which is what it should
        // already have done: renaming a marker without going to it is how you
        // rename the wrong one.
        .simultaneousGesture(TapGesture().onEnded {
            state.seekToMarker(atOutput: chapter.outputTime)
        })
        .contextMenu {
            Button("Rename") { beginRename(chapter) }
            Button("Edit Details…") { onEditMarker(chapter.id) }
            Divider()
            Button("Delete", role: .destructive) { state.deleteMarker(id: chapter.id) }
        }
    }

    private func beginRename(_ chapter: MarkerChapter) {
        // Empty rather than the generated "Marker 3": pre-filling the
        // placeholder makes renaming start by deleting text the user never
        // typed. The TIME is pre-filled, because there is no placeholder
        // problem there — every chapter has one, and editing usually means
        // nudging it.
        editingText = chapter.hasCustomLabel ? chapter.label : ""
        editingTime = Self.timestamp(chapter.outputTime)
        editingID = chapter.id
        editingFocused = true
    }

    /// Apply both fields as one edit, then close the row.
    private func commit(_ chapter: MarkerChapter) {
        state.applyChapterEdit(id: chapter.id, timeText: editingTime, label: editingText)
        editingID = nil
    }

    /// Read a timestamp back, in any form somebody would type it.
    ///
    /// `1:23`, `0:05`, `1:02:03`, or a bare `83` — because the field shows
    /// `m:ss` and a person editing it will either adjust what is there or type
    /// the seconds they have in mind, and refusing one of those is refusing
    /// half of them.
    ///
    /// Returns nil for anything it cannot read, so the caller keeps the old
    /// time rather than moving a chapter to zero.
    /// Delegates to `Timecode.parse`, which is the same job done once.
    ///
    /// This carried its own implementation until the transport's time field
    /// needed one and a SECOND parser was written rather than this one found.
    /// Two readings of "1:30" that could disagree is exactly the duplication
    /// this project keeps removing elsewhere; `Timecode` is the stricter of
    /// the two (it refuses a fraction on a non-final component, which this
    /// accepted as a time) and the one with tests.
    static func parseTimestamp(_ text: String) -> Double? { Timecode.parse(text) }

    /// `m:ss`, or `h:mm:ss` once a recording is long enough to need it.
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
