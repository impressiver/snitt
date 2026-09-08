import AppKit
import SwiftUI
import SnittDocument

/// The transcript as an editing surface (D62).
///
/// Reading is the interface: click a word to jump the preview there, select a
/// phrase and delete it to cut those seconds — a far better answer to §1's
/// speed budget than dragging pixels, which is the sentence in D62 this pane
/// exists to make true.
struct TranscriptPane: View {
    @ObservedObject var state: EditorTimelineState
    @State private var selection: Set<UUID> = []
    /// Anchor for shift-click range extension.
    @State private var anchorID: UUID?
    /// The word being corrected inline, if any (D62 second slice). UI-only,
    /// like `editingMarkerID`: what is asserted elsewhere is that
    /// `correctWord` persists and undoes; which word has a text field open is
    /// presentation state.
    @State private var editingWordID: UUID?
    @State private var editingText = ""
    @FocusState private var editingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state.transcriptionStatus {
            case .needsPermission:
                // The §4.10 rung: the dialog appears when THIS is clicked, so
                // it has a visible cause.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcribe this recording?")
                        .font(.headline)
                    Text("Runs on this Mac. Audio never leaves your computer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Transcribe") { state.requestTranscriptionPermission() }
                }
                .padding(8)
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            case .failed(let message):
                Text("Transcription failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            case .none:
                EmptyView()
            case .ready:
                if let transcript = state.transcript {
                    transcriptBody(transcript)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptBody(_ transcript: Transcript) -> some View {
        let cutIDs = state.cutWordIDs
        ScrollView {
            WrappingLayout(spacing: 3) {
                ForEach(transcript.words) { word in
                    wordView(word, isCut: cutIDs.contains(word.id))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        HStack {
            Button("Delete Words") {
                state.deleteWords(ids: selection)
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
            Spacer()
            Text("\(transcript.words.count) words")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func wordView(_ word: TranscriptWord, isCut: Bool) -> some View {
        if editingWordID == word.id {
            // Inline, not a sheet: correction is frequent (every proper noun
            // the recognizer fumbles) and the field replaces the word exactly
            // where the eye already is — the marker sheet's own rationale
            // (occasional use, no room) does not apply here.
            TextField("", text: $editingText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .frame(minWidth: 60, maxWidth: 140)
                .focused($editingFocused)
                .onSubmit { commitEdit(word) }
                .onExitCommand { editingWordID = nil }   // Esc cancels
                .onAppear { editingFocused = true }
        } else {
        Text(word.text)
            .font(.callout)
            // Struck through when the EDL cuts it — undoing the cut un-strikes
            // it with no bookkeeping, because cutWordIDs is derived.
            .strikethrough(isCut, color: .red)
            // The recognizer's own doubt, rendered: D68 read "loom is" at 0.34
            // for what was probably "Loom is". A transcript that hides how
            // sure it is invites trusting the wrong words.
            .opacity(word.confidence < 0.5 ? 0.55 : (isCut ? 0.6 : 1.0))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(selection.contains(word.id)
                        ? Color.accentColor.opacity(0.3) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 3))
            // count: 2 registered FIRST — SwiftUI resolves simultaneous tap
            // gestures in declaration order, and the reverse order makes the
            // double-tap unreachable behind two single-taps.
            .onTapGesture(count: 2) { beginEdit(word) }
            .onTapGesture { handleTap(word) }
            .contextMenu {
                Button("Edit Word…") { beginEdit(word) }
            }
        }
    }

    private func beginEdit(_ word: TranscriptWord) {
        editingText = word.text
        editingWordID = word.id
    }

    private func commitEdit(_ word: TranscriptWord) {
        // Empty commits are a cancel, not a removal — `correctWord` refuses
        // them too, so this is presentation matching the model rather than a
        // second rule.
        state.correctWord(id: word.id, text: editingText)
        editingWordID = nil
    }

    private func handleTap(_ word: TranscriptWord) {
        // Shift extends from the anchor, like text selection everywhere else
        // on the platform. Read from NSEvent because a SwiftUI TapGesture
        // carries no modifiers on macOS 15.
        if NSEvent.modifierFlags.contains(.shift), let anchorID,
           let transcript = state.transcript,
           let anchorIndex = transcript.words.firstIndex(where: { $0.id == anchorID }),
           let tappedIndex = transcript.words.firstIndex(where: { $0.id == word.id }) {
            let range = min(anchorIndex, tappedIndex)...max(anchorIndex, tappedIndex)
            selection = Set(transcript.words[range].map(\.id))
        } else {
            selection = [word.id]
            anchorID = word.id
            // A plain click also auditions the word — the fastest way to find
            // a moment is to read to it, then hear it.
            state.seek(toWord: word)
        }
    }
}

/// Minimal left-to-right wrapping layout — words flow like text.
struct WrappingLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
