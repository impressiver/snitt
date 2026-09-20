// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittExport
import SwiftUI
import SnittDocument

/// What the export sheet is deciding.
struct ExportRequest: Equatable {
    /// A `MovieExporter` format string, not a UTI — `"mp4"` or `"gif"`.
    private(set) var format: String = "mp4"
    var resolution: ExportResolution = .source
    var destination: URL
    var drawClicks: Bool = false
    /// Burn the transcript in as captions. Defaults from the document's
    /// `showSubtitles`, so the sheet opens agreeing with the editor.
    var drawSubtitles: Bool = false
    /// Burn each marker in as a top-left banner.
    var drawMarkers: Bool = false
    /// A ceiling the export must fit under, or nil for none.
    ///
    /// The sheet does not offer this — a person picking a resolution by hand
    /// is choosing quality, not a byte budget. It exists for the destination
    /// presets, where the budget is the whole point: "GitHub" means 10 MB
    /// before it means anything else.
    var maxSizeBytes: Int?

    /// `drawClicks` defaults off so the previews and tests that construct a
    /// request directly are unaffected; the editor passes Playback ▸ Show
    /// Clicks through, so the sheet opens agreeing with the menu.
    init(destination: URL, drawClicks: Bool = false,
         drawSubtitles: Bool = false, drawMarkers: Bool = false,
         maxSizeBytes: Int? = nil) {
        self.destination = destination
        self.drawClicks = drawClicks
        self.drawSubtitles = drawSubtitles
        self.drawMarkers = drawMarkers
        self.maxSizeBytes = maxSizeBytes
    }

    /// The request that puts a recording somewhere specific.
    ///
    /// Everything the preset knows becomes one of the three settings the
    /// exporter already takes, so this adds no export machinery — it is a
    /// translation, and the size ladder does the work.
    ///
    /// The filename carries the destination, because these are made to be
    /// posted and a folder of `demo.mp4`, `demo-1.mp4`, `demo-2.mp4` does not
    /// say which one is the small one.
    static func forDestination(_ destination: ExportDestination,
                               basedOn url: URL,
                               drawClicks: Bool,
                               drawSubtitles: Bool = false,
                               drawMarkers: Bool = false) -> ExportRequest {
        let stem = url.deletingPathExtension().lastPathComponent
        let named = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(destination.id)")
            .appendingPathExtension(destination.format)
        var request = ExportRequest(destination: named,
                                    drawClicks: drawClicks,
                                    drawSubtitles: drawSubtitles,
                                    drawMarkers: drawMarkers,
                                    maxSizeBytes: destination.maxSizeBytes)
        request.resolution = destination.resolution
        request.setFormat(destination.format)
        return request
    }

    /// The preset these settings ARE, or nil for "Custom".
    ///
    /// **Derived, never stored**, and that is the whole design. The
    /// requirement is "manually adjusting settings selects Custom", and a
    /// stored flag would have to be cleared by every control that can change a
    /// setting — so the first control added later without that line leaves the
    /// menu claiming a preset the settings no longer match. Asking the settings
    /// what they are cannot drift from what they are.
    ///
    /// `maxSizeBytes` is the discriminator and is nil for anything chosen by
    /// hand: the sheet offers no byte-budget control, and every manual edit
    /// clears it (see `clearPreset`). So "custom" is not a heuristic here, it
    /// is a fact about the request.
    var destinationPreset: ExportDestination? {
        guard let maxSizeBytes else { return nil }
        return ExportDestination.all.first {
            $0.maxSizeBytes == maxSizeBytes
                && $0.format == format
                && $0.resolution == resolution
        }
    }

    /// Adopts a preset's settings. Does NOT export: the Export button does.
    ///
    /// Overlays and the folder are deliberately untouched. A preset says what
    /// a place will ACCEPT — a size ceiling, a resolution, a container — and
    /// says nothing about whether you wanted captions burned in or where you
    /// keep your files. Overriding those would make choosing a preset undo
    /// decisions it has no opinion about.
    mutating func apply(_ preset: ExportDestination) {
        maxSizeBytes = preset.maxSizeBytes
        resolution = preset.resolution
        setFormat(preset.format)
        rename(suffix: preset.id)
    }

    /// Returns to "Custom": no byte budget, and no preset in the filename.
    ///
    /// Settings are LEFT ALONE. Someone who picked GitHub, liked 720p, and
    /// then wanted it without the 10 MB ceiling should get exactly that, not a
    /// silent reset to source resolution.
    mutating func clearPreset() {
        maxSizeBytes = nil
        rename(suffix: nil)
    }

    /// Re-stems the filename for `suffix`, removing any preset suffix already
    /// there.
    ///
    /// The removal is the part that matters. Without it, trying three presets
    /// in a row produces `demo-github-slack-x.mp4` — and the name that carries
    /// the wrong preset is worse than one that carries none, because the
    /// filename is the only thing distinguishing two exports of one recording
    /// once they are sitting in a folder together.
    private mutating func rename(suffix: String?) {
        let folder = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        var stem = destination.deletingPathExtension().lastPathComponent
        for known in ExportDestination.all where stem.hasSuffix("-\(known.id)") {
            stem = String(stem.dropLast(known.id.count + 1))
        }
        if let suffix { stem += "-\(suffix)" }
        destination = folder.appendingPathComponent(stem).appendingPathExtension(ext)
    }

    /// Changing the format renames the file, because a `.mp4` holding a GIF
    /// is a file Finder opens in the wrong app and QuickLook renders as
    /// nothing. `format` is `private(set)` so this is the only way to change
    /// it — a plain `var` lets a caller set the format and leave the
    /// extension behind, which is exactly the bug.
    /// Pick a format, as a person picking one means it.
    ///
    /// **One mutation, and that is the whole point.** The picker used to call
    /// `setFormat` and then `clearPreset`, two `mutating` calls on a SwiftUI
    /// `@Binding` — and the second re-READS the binding before it writes. The
    /// read came back with the pre-write value, so `clearPreset` wrote the old
    /// format back over the new one: the GIF segment lit up under the pointer
    /// and snapped back to MP4, and no part of the sheet ever saw the change.
    ///
    /// `setFormat` is private now so no call site can rebuild that pair.
    mutating func choose(format: String) {
        setFormat(format)
        // Changing a setting by hand is what makes this Custom.
        clearPreset()
    }

    /// Pick a resolution by hand. One mutation, for the reason above — this
    /// call site had the identical pair, so a resolution chosen by hand did
    /// not stick either.
    mutating func choose(resolution: ExportResolution) {
        self.resolution = resolution
        // Picking a resolution by hand is choosing QUALITY, not a byte budget
        // — `maxSizeBytes`' own doc comment says so — and the two fight: the
        // size ladder would walk back down from whatever was just chosen.
        clearPreset()
    }

    private mutating func setFormat(_ format: String) {
        self.format = format
        destination = destination.deletingPathExtension()
            .appendingPathExtension(format)
    }

    /// GIF size cannot be estimated: a GIF's weight tracks how much the
    /// picture MOVES and its frames carry no interframe compression, so
    /// AVFoundation's number describes an H.264 export and says nothing
    /// about it. `ExportEstimator` refuses rather than answering from the
    /// wrong codec.
    var estimatesApply: Bool { format == "mp4" }
}

/// Choosing what an export will be, with what it will cost stated first.
///
/// This replaces a bare `NSSavePanel` with a popup bolted into its accessory
/// slot. The accessory worked and looked like an afterthought, which it was —
/// the sizes were there and nothing about the panel said they mattered.
///
/// **One sheet, not a sheet and then a save panel.** The conventional macOS
/// export flow is options-then-panel, and it is two dialogs to answer one
/// question: what am I making, and where does it go. The destination is a row
/// here, and Change… opens a folder chooser only when someone wants a
/// different folder — which is not most exports.
struct ExportSheet: View {
    let title: String
    let options: [ExportOption]
    /// Nil while the composition is still being measured.
    let isMeasuring: Bool
    /// How long the edited recording runs, for the preset duration check.
    ///
    /// Zero when the caller does not know, which reads as "no warning" rather
    /// than "under every limit" — the two are the same answer here, and
    /// inventing a duration to compare against would be worse than staying
    /// quiet.
    var durationSeconds: Double = 0
    @Binding var request: ExportRequest
    let onCancel: () -> Void
    let onExport: () -> Void
    let onChooseFolder: () -> Void

    private var estimatesApply: Bool { request.estimatesApply }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                preset
                format
                resolution
                overlays
                headline
                destination
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Which kind of file is about to be written, said in a glyph so
            // the format segment below reads as a confirmation rather than as
            // the only place that fact appears.
            Image(systemName: request.format == "gif" ? "photo.stack" : "film")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export").font(.headline)
                Text(verbatim: title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// "Export for" — moved here out of the menu bar (D95-era `File ▸ Export
    /// for`), where it exported immediately and gave nobody a chance to see
    /// what it had decided.
    ///
    /// Selecting one SETS the settings below and stops. The Export button is
    /// still the only thing that writes a file, so a preset is now a starting
    /// point you can adjust rather than a command you have to get right first
    /// time.
    private var preset: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export for").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { request.destinationPreset?.id ?? Self.customPresetID },
                set: { id in
                    if let destination = ExportDestination.named(id) {
                        request.apply(destination)
                    } else {
                        request.clearPreset()
                    }
                })) {
                Text("Custom").tag(Self.customPresetID)
                Divider()
                ForEach(ExportDestination.all) { destination in
                    Text(destination.name).tag(destination.id)
                }
            }
            .labelsHidden()
            if let note = request.destinationPreset?.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let overrun = Self.durationWarning(for: request.destinationPreset,
                                                  durationSeconds: durationSeconds) {
                Label(overrun, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What to say when the recording is longer than the preset allows, or
    /// nil when it is not.
    ///
    /// Shown HERE, while the settings are being chosen, rather than in an
    /// alert after the export — which is where it used to be, because
    /// `File ▸ Export for` wrote the file before there was anywhere to say it.
    /// Knowing before you export is the point of the move.
    ///
    /// Snitt still does not shorten anything to fit. Trimming to satisfy
    /// someone else's policy destroys content, and the person finds out by
    /// watching their own demo stop mid-sentence.
    static func durationWarning(for preset: ExportDestination?,
                                durationSeconds: Double) -> String? {
        guard let preset, durationSeconds > 0,
              preset.exceedsDuration(durationSeconds) else { return nil }
        let limit = Int((preset.maxDurationSeconds ?? 0).rounded())
        return "Longer than \(preset.name) accepts (\(limit / 60)m \(limit % 60)s). "
             + "It will export at full length — trim it yourself if that matters."
    }

    /// Not a destination id, and it must never collide with one — the picker's
    /// selection is an id, so a preset called "custom" would be unreachable.
    /// `ExportDestinationTests` pins that.
    static let customPresetID = "__custom__"

    private var format: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Format").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { request.format },
                set: { request.choose(format: $0) })) {
                Text("MP4").tag("mp4")
                Text("GIF").tag("gif")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Its natural width, not the row's. A segmented picker fills the
            // space it is given, which turned two short words into a slab
            // spanning the sheet — the system's own segmented controls sit at
            // the width of what is in them.
            .fixedSize()
        }
    }

    @ViewBuilder
    private var resolution: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Resolution").font(.caption).foregroundStyle(.secondary)
                if isMeasuring {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if options.isEmpty {
                // Losing the measurement loses the MENU, never the export.
                Text("Sizes could not be measured. Exports at the recording's "
                     + "own resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(options, id: \.resolution) { option in
                        row(for: option)
                        if option.resolution != options.last?.resolution { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                if estimatesApply {
                    Text(ExportPreflight.caveat)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("A GIF's size depends on how much the picture moves, "
                         + "so these figures do not apply to it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A row per resolution, with the two facts that let someone choose
    /// between them — and the ceiling greyed rather than hidden for GIF, so
    /// the rows do not reflow when the format changes.
    private func row(for option: ExportOption) -> some View {
        Button {
            request.choose(resolution: option.resolution)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.resolution == request.resolution
                      ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(option.resolution == request.resolution
                                     ? Color.accentColor : .secondary)
                Text(option.resolution.rawValue)
                    .font(.body)
                    .fontWeight(option.resolution == request.resolution ? .semibold : .regular)
                    .frame(width: 60, alignment: .leading)
                Text(option.pixels)
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(option.ceiling)
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(estimatesApply ? .secondary : .tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // Selection stays the system accent: it is the one thing on this
            // sheet that means "you picked this", and that is the user's
            // colour everywhere else on their Mac.
            .background(option.resolution == request.resolution
                        ? Color.accentColor.opacity(0.09) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The two numbers the estimator actually produces, given the weight they
    /// earn: this is the feature — an export priced before you commit — and
    /// until now both figures were caption-sized, one per row.
    ///
    /// **Size ceiling and output length, not "export time".** An earlier draft
    /// of this design asked for an export-time estimate; no such number exists
    /// anywhere in the codebase, and inventing one would have put a guess next
    /// to a measurement. `durationSeconds` is exact, already computed, and
    /// answers a question somebody about to export actually has.
    ///
    /// The wording is `ExportPreflight.ceiling`'s, verbatim — "at most", never
    /// "≈" — because `estimatedMaxBytes` is an upper bound and the CLI and the
    /// MCP tool already say it that way. Three surfaces, one sentence.
    @ViewBuilder
    private var headline: some View {
        if let picked = options.first(where: { $0.resolution == request.resolution })
            ?? options.first {
            HStack(spacing: 10) {
                stat(estimatesApply ? picked.ceiling : "—", "size ceiling")
                stat(picked.length, "output length")
            }
            // The numbers change under the pointer as a measurement lands;
            // crossfading stops them popping, and tabular digits stop the
            // cards resizing around them.
            .animation(.easeInOut(duration: 0.2), value: isMeasuring)
            .animation(.easeInOut(duration: 0.2), value: request.resolution)
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save to").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(verbatim: request.destination.deletingLastPathComponent().lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…", action: onChooseFolder)
            }
            Text(verbatim: request.destination.lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// What gets drawn ON the recording, as its own section.
    ///
    /// "Draw clicks" used to sit alone beside the Export button, which was
    /// tolerable for one checkbox and stops being so at three: the row a
    /// person's eye goes to for "am I done" is not where a decision about the
    /// content belongs. Subtitles and markers join it here, grouped under a
    /// heading like Format and Resolution above.
    ///
    /// Each defaults from the DOCUMENT — the Playback ▸ Show toggles — so the
    /// sheet opens agreeing with what the editor was showing, and each stays
    /// overridable for this one export.
    private var overlays: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overlays").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Draw subtitles", isOn: $request.drawSubtitles)
                    .help("Burn the transcript into the video as captions")
                Toggle("Draw markers", isOn: $request.drawMarkers)
                    .help("Burn each marker in as a banner at the top left")
                Toggle("Draw clicks", isOn: $request.drawClicks)
                    .help("Mark clicks on the exported video")
            }
            .toggleStyle(.checkbox)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Export", action: onExport)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#if DEBUG
// Three previews rather than one: the measured state is what someone sees
// almost always, the measuring state is what they see first, and the failed
// measurement is the one nobody looks at until it ships wrong.
#Preview("Export — measured") {
    @Previewable @State var request = ExportRequest(
        destination: URL(fileURLWithPath: "/Users/somebody/Desktop/Standup.mp4"))
    ExportSheet(title: "Standup 2026-09-10", options: PreviewFixtures.exportOptions,
                isMeasuring: false, request: $request,
                onCancel: {}, onExport: {}, onChooseFolder: {})
}

#Preview("Export — measuring") {
    @Previewable @State var request = ExportRequest(
        destination: URL(fileURLWithPath: "/Users/somebody/Desktop/Standup.mp4"))
    ExportSheet(title: "Standup 2026-09-10", options: [],
                isMeasuring: true, request: $request,
                onCancel: {}, onExport: {}, onChooseFolder: {})
}

#Preview("Export — GIF, estimates disclaimed") {
    @Previewable @State var request: ExportRequest = {
        var request = ExportRequest(
            destination: URL(fileURLWithPath: "/Users/somebody/Desktop/Standup.mp4"))
        request.choose(format: "gif")
        return request
    }()
    ExportSheet(title: "Standup 2026-09-10", options: PreviewFixtures.exportOptions,
                isMeasuring: false, request: $request,
                onCancel: {}, onExport: {}, onChooseFolder: {})
}
#endif
