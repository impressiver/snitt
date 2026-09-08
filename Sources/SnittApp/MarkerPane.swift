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

    @State private var editingID: UUID?
    @State private var editingText = ""
    @FocusState private var editingFocused: Bool

    var body: some View {
        let chapters = state.chapters
        let currentID = state.currentChapterID(atOutputSeconds: playhead)
        VStack(alignment: .leading, spacing: 0) {
            header(count: chapters.count)
            Divider()
            if chapters.isEmpty {
                empty
            } else {
                list(chapters, currentID: currentID)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("Chapters").font(.headline)
            Spacer()
            Button {
                state.addMarker(atOutput: playhead)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a chapter at the playhead")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No chapters yet")
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

    @ViewBuilder
    private func row(_ chapter: MarkerChapter, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.timestamp(chapter.outputTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(chapter.isInsideCut ? AnyShapeStyle(.tertiary)
                                                         : AnyShapeStyle(.secondary))
                if editingID == chapter.id {
                    TextField("Chapter name", text: $editingText)
                        .textFieldStyle(.roundedBorder)
                        .focused($editingFocused)
                        .onSubmit { commitRename(chapter) }
                        // Clicking away keeps the edit rather than discarding
                        // it — the same choice the transcript's word editor
                        // makes, so the two do not behave differently.
                        .onChange(of: editingFocused) { _, focused in
                            if !focused, editingID == chapter.id { commitRename(chapter) }
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
        .background(isCurrent ? Color.yellow.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(chapter) }
        .onTapGesture { state.seek(toOutput: chapter.outputTime) }
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
        // typed.
        editingText = chapter.hasCustomLabel ? chapter.label : ""
        editingID = chapter.id
        editingFocused = true
    }

    private func commitRename(_ chapter: MarkerChapter) {
        state.renameMarker(id: chapter.id, to: editingText)
        editingID = nil
    }

    /// `m:ss`, or `h:mm:ss` once a recording is long enough to need it.
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
