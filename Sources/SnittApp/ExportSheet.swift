// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SwiftUI
import SnittDocument

/// What the export sheet is deciding.
struct ExportRequest: Equatable {
    /// A `MovieExporter` format string, not a UTI — `"mp4"` or `"gif"`.
    private(set) var format: String = "mp4"
    var resolution: ExportResolution = .source
    var destination: URL
    var drawClicks: Bool = false

    init(destination: URL) { self.destination = destination }

    /// Changing the format renames the file, because a `.mp4` holding a GIF
    /// is a file Finder opens in the wrong app and QuickLook renders as
    /// nothing. `format` is `private(set)` so this is the only way to change
    /// it — a plain `var` lets a caller set the format and leave the
    /// extension behind, which is exactly the bug.
    mutating func setFormat(_ format: String) {
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
                format
                resolution
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

    private var format: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Format").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { request.format },
                set: { request.setFormat($0) })) {
                Text("MP4").tag("mp4")
                Text("GIF").tag("gif")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
            request.resolution = option.resolution
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

    private var footer: some View {
        HStack {
            Toggle("Draw clicks", isOn: $request.drawClicks)
                .toggleStyle(.checkbox)
                .help("Mark reported clicks on the exported video")
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
        request.setFormat("gif")
        return request
    }()
    ExportSheet(title: "Standup 2026-09-10", options: PreviewFixtures.exportOptions,
                isMeasuring: false, request: $request,
                onCancel: {}, onExport: {}, onChooseFolder: {})
}
#endif
