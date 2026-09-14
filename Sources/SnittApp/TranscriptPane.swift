// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import SwiftUI
import SnittBrand
import SnittDocument

/// The transcript as an editing surface (D62).
///
/// Reading is the interface: click a word to jump the preview there, select a
/// phrase and delete it to cut those seconds — a far better answer to §1's
/// speed budget than dragging pixels, which is the sentence in D62 this pane
/// exists to make true.
struct TranscriptPane: View {
    @ObservedObject var state: EditorTimelineState
    /// OUTPUT time, polled by the editor shell — the same value the timeline's
    /// playhead draws at, so the two cannot disagree about where playback is.
    let playhead: Double
    @State private var selection: Set<UUID> = []
    /// Anchor for shift-click range extension.
    @State private var anchorID: UUID?
    /// The word being corrected inline, if any (D62 second slice). UI-only,
    /// like `editingMarkerID`: what is asserted elsewhere is that
    /// `correctWord` persists and undoes; which word has a text field open is
    /// presentation state.
    @State private var editingWordID: UUID?
    @State private var editingText = ""
    /// Whether the refine panel is open. UI-only, like `editingWordID`.
    @State private var refining = false
    @FocusState private var editingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch TranscriptPanePresentation.decide(
                status: state.transcriptionStatus,
                hasTranscript: state.transcript != nil,
                wordCount: state.transcript?.words.count ?? 0) {
            case .permissionPrompt:
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
            case .working:
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
            case .unavailable:
                EmptyView()
            case .noSpeechFound:
                noSpeechFound
            case .transcript:
                if let transcript = state.transcript {
                    transcriptBody(transcript)
                }
            }
        }
    }

    /// Transcription ran and heard nothing.
    ///
    /// The pane used to render an empty list here, under a header reading
    /// "0 words". That is indistinguishable from still working, from a broken
    /// transcriber, and from a recording whose audio went somewhere else — so
    /// the one state the user cannot act on was the one that said nothing.
    ///
    /// The second line is the part worth having. Transcription reads the
    /// MICROPHONE track only (`MicrophoneTrackExtractor` indexes `microphone`
    /// out of `AudioTrackOrder.canonical`), so a screen recording of a video
    /// call — where every voice arrived as system audio — transcribes to
    /// nothing at all, correctly, and looks broken. Saying which track is
    /// listened to is the difference between "this is broken" and "oh, I need
    /// the mic on".
    private var noSpeechFound: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No speech found")
                .font(.headline)
            Text("Snitt transcribes the microphone track. System audio — a call, "
                 + "a video, anything playing on your Mac — is recorded but not "
                 + "transcribed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }

    @ViewBuilder
    private func transcriptBody(_ transcript: Transcript) -> some View {
        let cutIDs = state.cutWordIDs
        let currentID = state.currentWordID(atOutputSeconds: playhead)
        // Broken into lines at the speaker's own pauses. The recognizer emits
        // one undifferentiated stream; a screencast narration is not one, and
        // reading is the interface this pane exists for.
        // `audibleWords`, not `transcript.words`: a muted track's speech is
        // not in the exported file, so showing it invites editing against
        // something that is not there.
        let paragraphs = TranscriptParagraphs.split(state.audibleWords)
        ScrollViewReader { proxy in
            ScrollView {
                // A list of rows, divided, with a time column — the marker
                // rail's shape, because the two now sit one above the other
                // and a reader moves between them. Two indexes of the same
                // recording that are laid out differently read as two
                // unrelated tools sharing a rail.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs) { paragraph in
                        phraseRow(paragraph, cutIDs: cutIDs, currentID: currentID)
                            .id(paragraph.id)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Follows only while PLAYING. Scrolling the text while someone is
            // reading and selecting would drag it out from under them, and
            // scrubbing already moves the playhead deliberately.
            .onChange(of: currentID) { _, id in
                guard let id, state.isPlaying else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        HStack {
            Button("Delete Words") {
                state.deleteWords(ids: selection)
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
            Spacer()
            Text("\(state.audibleWords.count) words")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)

        refinePanel
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
    }

    /// Running the recogniser again with better hints (D81).
    ///
    /// Behind a disclosure rather than always open: re-transcribing is a
    /// deliberate second attempt, not part of reading a transcript, and a text
    /// field permanently occupying the pane would say otherwise.
    @ViewBuilder
    private var refinePanel: some View {
        DisclosureGroup(isExpanded: $refining) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Words to expect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Symbol names, file names, product names — the things a
                // general speech model has never heard and will otherwise
                // guess at.
                TextField("KeptRanges, SCStream, edit.json",
                          text: $state.vocabularyText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.caption)
                Text("Comma separated. A word you never say costs nothing, so list "
                     + "them generously — up to \(Vocabulary.limit).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack {
                    Button("Re-transcribe") { state.retranscribe() }
                        .disabled(state.transcriptionStatus == .transcribing)
                    if state.transcriptionStatus == .transcribing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                // Said BEFORE the button is pressed, not after. A correction is
                // only marked by confidence 1.0, which a confident recognition
                // also produces, so there is no way to keep one and replace the
                // rest — undo is the whole answer and has to be advertised.
                Text("Replaces the transcript, including any corrections. Undo brings them back.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        } label: {
            Text("Refine transcription")
                .font(.caption)
        }
        .onAppear { state.loadVocabulary() }
    }

    /// One phrase: when it was said, and what was said.
    ///
    /// The time is on the LEFT in its own column so the column reads down the
    /// rail, the same way the marker list's does. It is a real control, not a
    /// label: clicking it goes there, which is the cheapest possible way to
    /// reach a moment you can see but have not selected.
    @ViewBuilder
    private func phraseRow(_ paragraph: TranscriptParagraph,
                           cutIDs: Set<UUID>, currentID: UUID?) -> some View {
        let start = TranscriptParagraphs.outputStart(of: paragraph,
                                                     keptRanges: state.controller.keptRanges)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Amber, because a timecode is time — the same reasoning, and the
            // same swatch, as the marker rail's. A phrase cut away entirely
            // has no output time at all and shows a dash: there is nowhere to
            // click to, and an invented number would say otherwise.
            Text(start.map(MarkerPane.timestamp) ?? "—")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(start == nil
                                 ? AnyShapeStyle(.tertiary)
                                 : AnyShapeStyle(SnittPalette.Swatch.amberText))
                .frame(width: 44, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if let start { state.seek(toOutput: start) } }

            WrappingLayout(spacing: 3) {
                ForEach(paragraph.words) { word in
                    wordView(word, isCut: cutIDs.contains(word.id),
                             isCurrent: word.id == currentID)
                        .id(word.id)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func wordView(_ word: TranscriptWord, isCut: Bool, isCurrent: Bool) -> some View {
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
            // Narration reads in the brand's cool teal against recorded speech
            // in the ordinary text colour. The two INTERLEAVE — narration is
            // spoken over footage that already has speech in it — so the
            // transcript alternates between them line by line, and telling
            // them apart has to be possible without reading either.
            .foregroundStyle(AudibleTranscript.isVoiceover(word)
                             ? AnyShapeStyle(Color(nsColor: SnittPalette.voiceover))
                             : AnyShapeStyle(.primary))
            // Struck through when the EDL cuts it — undoing the cut un-strikes
            // it with no bookkeeping, because cutWordIDs is derived.
            .strikethrough(isCut, color: .red)
            // The recognizer's own doubt, rendered: D68 read "loom is" at 0.34
            // for what was probably "Loom is". A transcript that hides how
            // sure it is invites trusting the wrong words.
            .opacity(word.confidence < 0.5 ? 0.55 : (isCut ? 0.6 : 1.0))
            // Bold marks the spoken word whether or not it is also selected,
            // so playback position stays readable while a phrase is picked out
            // for deletion — the two states must not compete for one signal.
            .fontWeight(isCurrent ? .bold : .regular)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(background(isSelected: selection.contains(word.id),
                                   isCurrent: isCurrent),
                        in: RoundedRectangle(cornerRadius: 3))
            .onTapGesture(count: 2) { beginEdit(word) }
            // `simultaneousGesture`, not a second `onTapGesture`. Two tap
            // gestures of different counts on one view make the single-tap one
            // WAIT for the double-tap one to fail, and that wait IS the
            // double-click interval — the reported half-second before a word
            // responds, and the same defect the marker rows had.
            //
            // The comment this replaces said the declaration ORDER was what
            // mattered ("count: 2 registered FIRST … the reverse order makes
            // the double-tap unreachable"). Order does decide which gesture
            // wins; it does nothing about the wait, because with two exclusive
            // tap gestures there is always something to wait for. Recognising
            // simultaneously is what removes it. A double click now selects
            // and then opens the editor, in that order, which is what editing
            // a word you have not selected should do anyway.
            .simultaneousGesture(TapGesture().onEnded { handleTap(word) })
            .contextMenu {
                Button("Edit Word…") { beginEdit(word) }
            }
        }
    }

    /// Selection is the accent fill; the playhead is a distinct tint. When a
    /// word is both, selection wins the fill and bold carries the playhead —
    /// otherwise "what am I about to delete" and "where is playback" would be
    /// the same colour.
    private func background(isSelected: Bool, isCurrent: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.3) }
        if isCurrent {
            return EditorChromePalette.currentHighlight
                .opacity(EditorChromePalette.currentHighlightOpacity)
        }
        return .clear
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
