// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import SnittCapture
import SnittDocument

/// The window File ▸ New opens, and also the front door: a bare launch and a
/// Dock click with no window open both show this rather than an `NSOpenPanel`
/// or silently reopening the last document — see `LaunchOpenPrompt`.
///
/// This replaced `EmptyDocumentWindow`, which only ever had one thing to say
/// ("drop a video here"). This window has a person's actual state to
/// report — recent recordings, a hotkey that may have been rebound, a
/// permission that may still be missing — so it reads from `WelcomeContent`,
/// the pure decision layer, rather than deciding any of that itself. This
/// file is the AppKit half: layout, callbacks, and the handful of OS reads
/// (`RecentDocuments`, the three `*Access.isGranted()` checks,
/// `HotkeySettings.load`) that `WelcomeContent` cannot reach on its own
/// because it is deliberately not `@MainActor` and touches no UI.
///
/// **This window never asks for a permission.** It reads `isGranted()` on
/// each service and nothing else — never `ensureGranted()`, never a
/// `CGRequest…`/`requestAccess` call. `PermissionLadder` reserves asking for
/// the first use of the feature that needs it, never at launch, and this
/// window opens at launch (or on ⌘N, which is close enough to "no feature
/// has been used yet" to carry the same rule). Snitt DOES ask, just not
/// here: `RecordingCoordinator.startRecording` runs the ladder on the first
/// recording, and the Settings toggles run it when a feature is switched on.
/// Getting that wrong would raise a TCC dialog every time this window opens,
/// which is exactly the repeated-prompt failure the ladder exists to avoid.
///
/// **This window never enumerates windows.** Nothing here touches
/// `SCShareableContent` — that enumeration itself re-triggers macOS's
/// recurring consent prompt (see `ConsentExplainer`), and doing it every
/// time this window opened would mean every launch paid for it.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    /// Open windows, so a second ⌘N brings the first forward rather than
    /// stacking a duplicate — the same reuse the one shared
    /// `SettingsWindowController` already does.
    private(set) static var open: [WelcomeWindow] = []

    let window: NSWindow

    private let onRecord: () -> Void
    private let onOpenExisting: () -> Void
    private let onImportVideo: ([URL]) -> Void
    private let onOpenRecent: (URL) -> Void
    private let onDroppedFiles: ([URL]) -> Void

    /// The Record button's frame in window coordinates, refreshed on every
    /// mouse move so `keennessAndNodding` always compares the pointer
    /// against where the button currently is rather than a stale layout.
    private var recordButtonFrame: NSRect = .zero

    /// Test seams. These mirror decisions made while building the content
    /// view — whether the permission section was included, and how many
    /// recents rows it produced — so a test can assert on them without
    /// walking a live view hierarchy, the same way
    /// `SettingsWindowController.checkbox(titled:)` exists purely for its
    /// own tests to reach past the window into what it built.
    private(set) var hasPermissionSection = false
    private(set) var recentsRowCount = 0

    private static let tipIndexKey = "com.impressiver.snitt.welcomeWindow.tipIndex"

    /// Held only so `makeContent` can line the left column's caption up with
    /// the sidebar's buttons. The two are built by separate methods and the
    /// constraint spans both, so neither method can own it.
    private weak var menuBarCaption: NSView?
    private weak var sidebarButtonRow: NSView?

    /// Natural, and only, size — see this type's doc comment on why a fixed
    /// size is correct here rather than a compromise.
    /// 25% up on the 720x460 this started at. Control metrics, fonts and
    /// edge insets deliberately did NOT scale with it: macOS controls have
    /// fixed metrics, so the extra space goes to breathing room rather than
    /// to a uniformly zoomed window that would look like a scaled bitmap.
    static let contentSize = NSSize(width: 900, height: 575)
    private static let leftColumnWidth: CGFloat = 500

    // MARK: - Showing

    /// - Parameters:
    ///   - onRecord: the same action the status item's record command runs.
    ///   - onOpenExisting: the same path File ▸ Open uses.
    ///   - onImportVideo: a chosen or dropped video file.
    ///   - onOpenRecent: a `.snitt` bundle picked from the recents list.
    ///   - onDroppedFiles: files dropped on the window that were not routed
    ///     to one of the above — present so a drop of mixed `.snitt` and
    ///     video files still opens everything rather than only the first
    ///     match.
    @discardableResult
    static func show(defaults: UserDefaults = .standard,
                     recentURLs: [URL] = RecentDocuments.urls(),
                     screenRecordingGranted: Bool = ScreenRecordingAccess.isGranted(),
                     microphoneGranted: Bool = MicrophoneAccess.isGranted(),
                     inputMonitoringGranted: Bool = InputMonitoringAccess.isGranted(),
                     onRecord: @escaping () -> Void,
                     onOpenExisting: @escaping () -> Void,
                     onImportVideo: @escaping ([URL]) -> Void,
                     onOpenRecent: @escaping (URL) -> Void,
                     onDroppedFiles: @escaping ([URL]) -> Void,
                     activate: Bool = true) -> WelcomeWindow {
        if let existing = open.first {
            if activate {
                existing.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return existing
        }

        // Rotates on every open rather than every launch, so someone who
        // keeps the window around across several recordings still sees the
        // tips move — the same reasoning `WelcomeContent.guidance`'s own doc
        // comment gives for deriving its state rather than spending a flag.
        let tipIndex = defaults.integer(forKey: tipIndexKey)
        defaults.set(tipIndex + 1, forKey: tipIndexKey)

        let recordCombination = HotkeySettings.load(defaults)[.record]
        let recents = WelcomeContent.recents(from: recentURLs)
        let guidance = WelcomeContent.guidance(
            hasRecordings: !recents.isEmpty,
            recordShortcut: recordCombination.displayString,
            tipIndex: tipIndex)
        let permissionRows = WelcomeContent.permissionRows(
            screenRecordingGranted: screenRecordingGranted,
            microphoneGranted: microphoneGranted,
            inputMonitoringGranted: inputMonitoringGranted,
            microphoneEnabled: MicrophoneSettings.load(defaults).enabled,
            inputLoggingEnabled: EventLoggingSettings.load(defaults).enabled)

        let controller = WelcomeWindow(
            guidance: guidance,
            recents: recents,
            permissionRows: permissionRows,
            recordShortcut: recordCombination,
            onRecord: onRecord,
            onOpenExisting: onOpenExisting,
            onImportVideo: onImportVideo,
            onOpenRecent: onOpenRecent,
            onDroppedFiles: onDroppedFiles)
        open.append(controller)
        if activate {
            controller.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return controller
    }

    /// Test-only: drops every open window without touching AppKit's close
    /// machinery, which races another suite's real window close.
    static func resetForTesting() { open.removeAll() }

    /// Dismisses the front door, because something better is now on screen.
    ///
    /// Called from `EditorWindowController.show()`. The dependency points
    /// that way deliberately: this is the welcome window's own rule — it is
    /// shown only when there is no document on screen — so putting the rule
    /// here keeps the editor ignorant of a window it has no other reason to
    /// know about, and one call site means the rule cannot be half applied.
    ///
    /// A notification would decouple it further. SnittApp uses
    /// `NotificationCenter` nowhere at all, and introducing the first one
    /// for a single in-module call would trade a checked reference for an
    /// unchecked string.
    ///
    /// Iterates a COPY: `window.close()` runs `windowWillClose`, which
    /// removes the controller from `open` while the loop is reading it.
    static func closeForEditor() {
        for controller in open { controller.window.close() }
    }

    private init(guidance: WelcomeContent.Guidance,
                recents: [WelcomeContent.Entry],
                permissionRows: [WelcomeContent.PermissionRow],
                recordShortcut: HotkeyCombination,
                onRecord: @escaping () -> Void,
                onOpenExisting: @escaping () -> Void,
                onImportVideo: @escaping ([URL]) -> Void,
                onOpenRecent: @escaping (URL) -> Void,
                onDroppedFiles: @escaping ([URL]) -> Void) {
        self.onRecord = onRecord
        self.onOpenExisting = onOpenExisting
        self.onImportVideo = onImportVideo
        self.onOpenRecent = onOpenRecent
        self.onDroppedFiles = onDroppedFiles

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Welcome to Snitt"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Fixed size, not merely a starting size: there is nothing in this
        // window worth reflowing for, and a window that cannot be resized
        // below its own natural size needs no minimum-size dance either.
        window.setContentSize(Self.contentSize)
        window.minSize = Self.contentSize
        window.maxSize = Self.contentSize
        // The same over-release trap every other window in this app
        // documents: a programmatically created NSWindow defaults this to
        // true, which frees it out from under the reference held here.
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.contentView = makeContent(guidance: guidance, recents: recents,
                                         permissionRows: permissionRows,
                                         recordShortcut: recordShortcut)
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        mascotView?.lookAway()
        mouseTracker?.stop()
        mouseTracker = nil
        Self.open.removeAll { $0 === self }
    }

    // MARK: - Content

    private func makeContent(guidance: WelcomeContent.Guidance,
                             recents: [WelcomeContent.Entry],
                             permissionRows: [WelcomeContent.PermissionRow],
                             recordShortcut: HotkeyCombination) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let left = makeLeftColumn(guidance: guidance, permissionRows: permissionRows)
        let separator = NSBox()
        separator.boxType = .separator
        let right = makeRightColumn(recents: recents, recordShortcut: recordShortcut)

        for view in [left, separator, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        // The caption under the left column and the buttons at the foot of
        // the sidebar are the two things on the window's bottom edge, so they
        // read as one row and have to sit on one line. Constrained to each
        // other rather than both to a hardcoded inset, because a push
        // button's height is a system metric this code does not get to know.
        if let caption = menuBarCaption, let buttons = sidebarButtonRow {
            caption.centerYAnchor.constraint(equalTo: buttons.centerYAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: Self.leftColumnWidth),

            separator.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            right.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            right.topAnchor.constraint(equalTo: container.topAnchor),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Catches drags anywhere over the window — including over the
        // sidebar and the controls inside it — while declining clicks, so
        // every button underneath keeps working. Layered LAST, so it sits
        // above everything else and still catches the drag.
        let drop = VideoDropView(frame: .zero)
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        container.addSubview(drop)
        NSLayoutConstraint.activate([
            drop.topAnchor.constraint(equalTo: container.topAnchor),
            drop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            drop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            drop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return container
    }

    /// Routes a drop to whichever callback its contents earn: `.snitt`
    /// bundles to `onOpenRecent` (one call per bundle, which is what
    /// `onOpenRecent`'s single-`URL` shape already commits to), importable
    /// video to `onImportVideo`, and anything else — a drag that resolved to
    /// file URLs but not to either kind — to `onDroppedFiles` so it is not
    /// silently dropped on the floor.
    private func handleDrop(_ urls: [URL]) {
        let videos = urls.filter(ImportableMedia.canOpen)
        let bundles = urls.filter { $0.pathExtension.lowercased() == "snitt" }
        let rest = urls.filter { !videos.contains($0) && !bundles.contains($0) }
        if !videos.isEmpty { onImportVideo(videos) }
        for bundle in bundles { onOpenRecent(bundle) }
        if !rest.isEmpty { onDroppedFiles(rest) }
    }

    // MARK: - Left column

    private func makeLeftColumn(guidance: WelcomeContent.Guidance,
                                permissionRows: [WelcomeContent.PermissionRow]) -> NSView {
        let column = NSView()

        let mascot = makeMascot()
        let headline = NSTextField(labelWithString: Self.headlineText(for: guidance))
        headline.font = .systemFont(ofSize: 21, weight: .semibold)
        headline.alignment = .center

        var stackViews: [NSView] = [mascot, headline]

        switch guidance {
        case .gettingStarted:
            let subtitle = NSTextField(labelWithString: "Then trim the dead air and send it.")
            subtitle.font = .systemFont(ofSize: 12.5)
            subtitle.textColor = .secondaryLabelColor
            subtitle.alignment = .center
            stackViews.append(subtitle)
        case .tip(let text):
            let tip = NSTextField(wrappingLabelWithString: text)
            tip.font = .systemFont(ofSize: 11.5)
            tip.textColor = .secondaryLabelColor
            tip.alignment = .center
            tip.preferredMaxLayoutWidth = 340
            tip.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            stackViews.append(tip)
        }

        if WelcomeContent.needsAttention(permissionRows),
           let section = Self.makePermissionSection(permissionRows) {
            stackViews.append(section)
            hasPermissionSection = true
        }

        let mainStack = NSStackView(views: stackViews)
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 32
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let menuBarLine = Self.makeMenuBarLine()
        menuBarLine.translatesAutoresizingMaskIntoConstraints = false
        menuBarCaption = menuBarLine

        column.addSubview(mainStack)
        column.addSubview(menuBarLine)
        NSLayoutConstraint.activate([
            mainStack.centerYAnchor.constraint(equalTo: column.centerYAnchor),
            mainStack.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 40),
            mainStack.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -40),
            mainStack.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            mainStack.topAnchor.constraint(greaterThanOrEqualTo: column.topAnchor, constant: 46),

            menuBarLine.bottomAnchor.constraint(lessThanOrEqualTo: column.bottomAnchor,
                                                constant: -16),
            menuBarLine.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            menuBarLine.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 40),
            menuBarLine.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -40),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: menuBarLine.topAnchor, constant: -16),
        ])

        return column
    }

    /// The face, at its natural size.
    ///
    /// Held on the window because the window is what drives it: it is the
    /// only party that knows where its own Record button is, and a tracking
    /// area on the mascot could only ever see the pointer while it was
    /// inside those 188x144 points.
    private func makeMascot() -> MascotView {
        let mascot = MascotView(frame: NSRect(x: 0, y: 0, width: 188, height: 144))
        mascot.widthAnchor.constraint(equalToConstant: 188).isActive = true
        mascot.heightAnchor.constraint(equalToConstant: 144).isActive = true
        mascotView = mascot
        return mascot
    }

    /// "Welcome to Snitt" the first time there is nothing to show yet,
    /// "Ready when you are" once there is — `Guidance` already carries that
    /// distinction, so this just names the two strings in one place rather
    /// than inlining them at the call site.
    nonisolated static func headlineText(for guidance: WelcomeContent.Guidance) -> String {
        switch guidance {
        case .gettingStarted: return "Welcome to Snitt"
        case .tip: return "Ready when you are"
        }
    }

    /// One row per permission, plus the relaunch footnote — or `nil` when
    /// there is nothing to report, so a caller can skip the section outright
    /// rather than inserting an empty box.
    private static func makePermissionSection(_ rows: [WelcomeContent.PermissionRow]) -> NSView? {
        guard !rows.isEmpty else { return nil }

        let rowViews = rows.map(makePermissionRow)
        let stack = NSStackView(views: rowViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let missingRequiringRelaunch = rows.filter { !$0.isGranted && $0.requiresRelaunch }.count
        guard let footnote = relaunchLine(missingCount: missingRequiringRelaunch) else {
            return stack
        }
        let footnoteLabel = NSTextField(labelWithString: footnote)
        footnoteLabel.font = .systemFont(ofSize: 11)
        footnoteLabel.textColor = .secondaryLabelColor

        let section = NSStackView(views: [stack, footnoteLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    private static func makePermissionRow(_ row: WelcomeContent.PermissionRow) -> NSView {
        let symbolName = row.isGranted ? "checkmark" : "exclamationmark.triangle.fill"
        let description = row.isGranted ? "granted" : "missing"
        let image = NSImage(systemSymbolName: symbolName,
                            accessibilityDescription: "\(row.service.displayName) \(description)")
        let icon = NSImageView(image: image ?? NSImage())
        if row.isGranted {
            icon.contentTintColor = .systemGreen
        } else {
            icon.contentTintColor = .systemOrange
        }

        let label = NSTextField(labelWithString: row.service.displayName)
        label.font = .systemFont(ofSize: 11.5)
        if row.isGranted {
            label.textColor = .secondaryLabelColor
        }

        var rowViews: [NSView] = [icon, label]
        if !row.isGranted {
            let button = NSButton(title: "Open Settings…", target: nil, action: nil)
            button.bezelStyle = .push
            button.controlSize = .small
            button.target = PermissionSettingsOpener.shared
            button.action = #selector(PermissionSettingsOpener.open(_:))
            // `NSButton` itself carries no `representedObject` — only its
            // `NSCell` does — so the service to open rides on the cell.
            button.cell?.representedObject = row.service
            rowViews.append(button)
        }

        let stack = NSStackView(views: rowViews)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    /// How the permission footnote pluralises, as a function with no AppKit
    /// in it so it can be tested without building the row stack above it.
    ///
    /// `nil` for zero: a healthy launch gets no footnote at all, matching
    /// `WelcomeContent.needsAttention`'s own "nothing missing means no
    /// section" rule one level down.
    /// "or press [shortcut] anywhere" — pulled from `HotkeyCombination`
    /// rather than written as a literal, because the record hotkey is
    /// rebindable in Settings; a hardcoded ⌥⌘5 here would lie to anyone who
    /// changed it, the same mistake `WelcomeContent.tips` already guards
    /// against for the tip copy.
    nonisolated static func recordCaption(_ combination: HotkeyCombination) -> String {
        "or press \(combination.displayString) anywhere"
    }

    nonisolated static func relaunchLine(missingCount: Int) -> String? {
        switch missingCount {
        case 0: return nil
        case 1: return "Takes effect after you relaunch Snitt."
        case 2: return "Both take effect after you relaunch Snitt."
        default: return "These take effect after you relaunch Snitt."
        }
    }

    /// "Snitt looks like [icon] in your menu bar", with the icon as an
    /// inline `NSTextAttachment` rather than a separate label beside the
    /// text — so it reads as one sentence, including to a screen reader,
    /// rather than as a sentence next to an unrelated picture.
    ///
    /// The symbol is `record.circle` because that is literally what
    /// `StatusItemController.presentation(for: .idle, now:)` hands the
    /// status item — any other glyph here would show a menu-bar icon this
    /// build does not actually have.
    private static func makeMenuBarLine() -> NSTextField {
        let result = NSMutableAttributedString(string: "Snitt looks like ")
        let attachment = NSTextAttachment()
        let symbolImage = NSImage(systemSymbolName: "record.circle",
                                  accessibilityDescription: "a record circle")
        attachment.image = symbolImage
        // Sits on the text baseline rather than floating above or below it.
        let fontSize: CGFloat = 11
        attachment.bounds = NSRect(x: 0, y: -2, width: fontSize, height: fontSize)
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: " in your menu bar"))
        result.addAttributes([.font: NSFont.systemFont(ofSize: 11),
                              .foregroundColor: NSColor.secondaryLabelColor],
                             range: NSRange(location: 0, length: result.length))

        let label = NSTextField(labelWithAttributedString: result)
        label.alignment = .center
        return label
    }

    // MARK: - Right column (sidebar)

    private func makeRightColumn(recents: [WelcomeContent.Entry],
                                 recordShortcut: HotkeyCombination) -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState

        let header = NSTextField(labelWithString: "Recent")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let recentsContent: NSView = recents.isEmpty
            ? Self.makeEmptyRecentsState()
            : makeRecentsList(recents)

        let topStack = NSStackView(views: [header, recentsContent])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 10
        recentsContent.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        topStack.translatesAutoresizingMaskIntoConstraints = false

        let recordButton = NSButton(title: "Record a Window", target: self,
                                    action: #selector(recordTapped))
        recordButton.bezelStyle = .push
        recordButton.keyEquivalent = "\r"
        recordButton.controlSize = .large

        let caption = NSTextField(labelWithString: Self.recordCaption(recordShortcut))
        caption.font = .systemFont(ofSize: 11.5)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .center

        let recordStack = NSStackView(views: [recordButton, caption])
        recordStack.orientation = .vertical
        recordStack.alignment = .centerX
        recordStack.spacing = 8
        recordStack.translatesAutoresizingMaskIntoConstraints = false

        let middle = NSView()
        middle.translatesAutoresizingMaskIntoConstraints = false
        middle.addSubview(recordStack)
        NSLayoutConstraint.activate([
            recordStack.centerXAnchor.constraint(equalTo: middle.centerXAnchor),
            recordStack.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
        ])

        let openButton = NSButton(title: "Open…", target: self, action: #selector(openTapped))
        openButton.bezelStyle = .push
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importTapped))
        importButton.bezelStyle = .push
        let bottomRow = NSStackView(views: [openButton, importButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        sidebarButtonRow = bottomRow

        sidebar.addSubview(topStack)
        sidebar.addSubview(middle)
        sidebar.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            topStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            topStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),

            bottomRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),

            middle.topAnchor.constraint(equalTo: topStack.bottomAnchor),
            middle.bottomAnchor.constraint(equalTo: bottomRow.topAnchor),
            middle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            middle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
        ])

        recordButtonFrame = recordButton.frame
        trackMouseForMascot(in: sidebar, buttonFrameProvider: { [weak recordButton] in
            recordButton?.convert(recordButton?.bounds ?? .zero, to: nil) ?? .zero
        })

        return sidebar
    }

    private static func makeEmptyRecentsState() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "play.rectangle",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)

        let label = NSTextField(labelWithString: "Nothing here yet")
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        // Deliberately compact — this used to run to about 120 points and
        // pushed the primary Record button down the pane. It only has to
        // say "there is nothing to list here", not fill the space a full
        // recents list would have taken.
        stack.heightAnchor.constraint(lessThanOrEqualToConstant: 60).isActive = true
        return stack
    }

    private func makeRecentsList(_ entries: [WelcomeContent.Entry]) -> NSView {
        let rows = entries.enumerated().map { index, entry in
            Self.makeRecentRow(entry, isFirst: index == 0, target: self,
                               action: #selector(recentRowTapped(_:)))
        }
        recentsRowCount = rows.count
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Dated precisely enough to tell two recordings apart.
    ///
    /// This used to be a `RelativeDateTimeFormatter`, which collapsed every
    /// bundle older than a few weeks to the same phrase. The product owner's
    /// own list showed four DIFFERENT recordings, taken seconds apart on one
    /// branch at one commit, as four identical rows reading
    /// "726d2ac · last month". A recents list whose rows cannot be told
    /// apart does not do the one thing it exists for.
    ///
    /// `doesRelativeDateFormatting` keeps the friendly head of the range, so
    /// today and yesterday still read as words, and everything older gets a
    /// real date. The TIME is the part that actually disambiguates, and it
    /// is why `timeStyle` is not `.none`: two recordings on one afternoon
    /// share a date and differ only by clock time.
    ///
    /// Still collides for recordings made inside the same minute. That is
    /// the shape of a development machine hammering the record hotkey, not
    /// of use, and the alternative is seconds in a sidebar.
    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// The row's second line: what the name carried, then when it was made.
    ///
    /// Split out of `makeRecentRow` so a test can reach it. The window is
    /// the right home for it even so — `WelcomeContent`'s doc comment gives
    /// the reason, which is that formatting a date is locale-dependent
    /// presentation and testing it one layer down would mean pinning
    /// English.
    ///
    /// Main-actor isolated, unlike the pure string helpers beside it:
    /// `DateFormatter` is not `Sendable`, and a cached one shared across
    /// actors is exactly the data race the compiler is right to refuse.
    static func rowDetail(_ entry: WelcomeContent.Entry) -> String {
        [entry.detail, rowDateFormatter.string(from: entry.modified)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// One row in the recents sidebar list.
    ///
    /// Borderless and without a per-row card: `NSVisualEffectView`'s
    /// `.sidebar` material already reads as a sidebar, and a card behind
    /// every row on top of that is the "it looks like a web page" mistake
    /// this task's spec calls out by name. Only the first row gets a subtle
    /// selection fill, which is the cue a real macOS sidebar list gives for
    /// "the top/most relevant item", not a decoration repeated down the list.
    ///
    /// **The two lines are real labels, not an `attributedTitle`.** An
    /// earlier version put both lines in one attributed string separated by
    /// a newline and laid the icon over the top of it. That produced the
    /// defect the product owner photographed: `NSButtonCell` CENTRES its
    /// title, so the name sat in the middle of the row while the second line
    /// ran underneath the icon. A cell has no way to indent around a
    /// sibling subview, so the fix has to be real views in a stack.
    private static func makeRecentRow(_ entry: WelcomeContent.Entry, isFirst: Bool,
                                      target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(entry.url.absoluteString)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .noImage
        button.setButtonType(.momentaryChange)
        button.cell?.representedObject = entry.url

        let detailLine = Self.rowDetail(entry)

        let icon = NSImageView(image: NSImage(systemSymbolName: "film",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        let detail = NSTextField(labelWithString: detailLine)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor

        // Truncate rather than compress. A branch name is long and the
        // sidebar is not wide, so without this the row either grows the
        // window or squeezes the date off the end; a tail ellipsis keeps the
        // recognisable head of the name, which is the part being read.
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false

        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        if isFirst {
            button.layer?.backgroundColor = NSColor.selectedContentBackgroundColor
                .withAlphaComponent(0.12).cgColor
        }

        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor,
                                          constant: -8),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])

        // The labels and the icon are presentation; the BUTTON is the thing
        // a screen reader should find, and it needs a title of its own now
        // that it no longer has one. Without this the row announces as an
        // unlabelled button, which is worse than the attributedTitle was.
        for view in [icon, title, detail] as [NSView] {
            view.setAccessibilityElement(false)
        }
        button.setAccessibilityLabel(detailLine.isEmpty
            ? entry.title
            : "\(entry.title), \(detailLine)")

        return button
    }

    // MARK: - Mascot keenness and nodding

    /// Tracks the pointer inside `view` and recomputes keenness/nodding
    /// against the Record button's frame on every move.
    ///
    /// `MascotView` does not exist in this worktree yet (it is being written
    /// in parallel), so there is nothing to assign these onto today — see
    /// the TODO below. The window still owns the computation, because only
    /// the window knows where its own Record button is; `MascotView` itself
    /// has no reason to know that.
    private func trackMouseForMascot(in view: NSView, buttonFrameProvider: @escaping () -> NSRect) {
        let tracker = MouseMoveTracker(view: view) { [weak self] pointInWindow in
            guard let self else { return }
            let frame = buttonFrameProvider()
            self.recordButtonFrame = frame
            let (keenness, isNodding) = Self.keennessAndNodding(pointer: pointInWindow, buttonFrame: frame)
            self.latestKeenness = keenness
            self.latestIsNodding = isNodding
            guard let mascot = self.mascotView else { return }
            mascot.keenness = keenness
            mascot.isNodding = isNodding
            // Converted into the mascot's own coordinates, since that is what
            // `lookAt` expects and the tracker reports in the content view's.
            if let content = mascot.window?.contentView {
                mascot.lookAt(mascot.convert(pointInWindow, from: content))
            }
        }
        mouseTracker = tracker
    }

    /// Held only so `MouseMoveTracker`'s local monitor outlives this method.
    private var mouseTracker: MouseMoveTracker?
    /// Weak: the view belongs to the window's own view tree.
    private weak var mascotView: MascotView?
    /// Where the last computed values land until `MascotView` exists to
    /// receive them. Not read anywhere yet; kept so the computation this
    /// task asks for is actually wired to live mouse movement rather than
    /// sitting unused.
    private(set) var latestKeenness: Double = 0
    private(set) var latestIsNodding: Bool = false

    /// Converts the pointer's distance from the Record button's centre into
    /// how keen (0...1) and how attentive (`isNodding`) the mascot should
    /// look. Pure, so `MascotView`'s eventual wiring can stay a one-line
    /// assignment and this geometry can be tested without a window.
    ///
    /// Flat 0 while the pointer is far away, a smooth ramp as it closes in,
    /// and flat 1 once it is within about 40 points of the button's centre —
    /// "about 40", because clamping the ramp's near edge to EXACTLY the
    /// button's own radius would make keenness visibly jump to 1 the instant
    /// the cursor crosses an arbitrary-looking boundary, rather than finishing
    /// the climb just before `isNodding` takes over the read entirely.
    /// `isNodding` is the separate, binary signal for "inside the frame" —
    /// it does not interpolate, because a mascot cannot "almost" notice you
    /// moused over its button.
    nonisolated static func keennessAndNodding(pointer: NSPoint,
                                               buttonFrame: NSRect) -> (keenness: Double, isNodding: Bool) {
        let center = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        let dx = pointer.x - center.x
        let dy = pointer.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()

        let innerRadius = 40.0
        let rampWidth = 240.0
        let outerRadius = innerRadius + rampWidth

        let keenness: Double
        if distance <= innerRadius {
            keenness = 1.0
        } else if distance >= outerRadius {
            keenness = 0.0
        } else {
            keenness = 1.0 - (distance - innerRadius) / rampWidth
        }

        return (keenness, buttonFrame.contains(pointer))
    }

    // MARK: - Actions

    @objc private func recordTapped() { onRecord() }

    @objc private func openTapped() { onOpenExisting() }

    @objc private func importTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportableMedia.types
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        onImportVideo(panel.urls)
    }

    @objc private func recentRowTapped(_ sender: NSButton) {
        guard let url = sender.cell?.representedObject as? URL else { return }
        onOpenRecent(url)
    }
}

/// Carries a permission's `Open Settings…` button to its destination.
///
/// `NSButton`'s `target` must be an `AnyObject`, and `PermissionOnboarding`
/// is an `enum` namespace with no instance to be one — this is a single
/// shared, stateless receiver rather than growing `WelcomeWindow` yet
/// another per-row closure the button would otherwise need to carry.
@MainActor
final class PermissionSettingsOpener: NSObject {
    static let shared = PermissionSettingsOpener()

    @objc func open(_ sender: NSButton) {
        guard let service = sender.cell?.representedObject as? PermissionOnboarding.Service else { return }
        NSWorkspace.shared.open(PermissionOnboarding.settingsURL(for: service))
    }
}

/// A local mouse-moved monitor scoped to one view's window, for the mascot's
/// keenness tracking.
///
/// A local (not global) monitor: this only has to work while the welcome
/// window is key, and a global monitor would need Input Monitoring just to
/// animate a mascot — a permission this window is explicit about never
/// touching for anything else.
@MainActor
final class MouseMoveTracker {
    private weak var view: NSView?
    /// `nonisolated(unsafe)` only so `deinit` — which always runs
    /// nonisolated, even on a main-actor class (see `PlayerLayerView`'s own
    /// doc comment on that) — can remove the monitor. Safe here because
    /// nothing else ever touches this property off the main thread: both
    /// the assignment above and every removal below run on it, the same
    /// single-threaded use `HotkeyMonitor.hotKeyRef`/`handlerRef` rely on
    /// without needing this annotation at all (that type just isn't
    /// actor-isolated in the first place).
    nonisolated(unsafe) private var monitor: Any?
    private let onMove: (NSPoint) -> Void

    init(view: NSView, onMove: @escaping (NSPoint) -> Void) {
        self.view = view
        self.onMove = onMove
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard let view, let window = view.window,
              let windowView = window.contentView else { return }
        // A local monitor sees mouse-moved events for EVERY window in the
        // app, and `locationInWindow` is relative to whichever window the
        // event belongs to. Without this guard a pointer moving over an open
        // editor drove the mascot, in this window's coordinate space.
        guard event.window === window else { return }
        let point = windowView.convert(event.locationInWindow, from: nil)
        onMove(point)
    }

    /// Removes the monitor without waiting to be deallocated.
    ///
    /// `deinit` does this too, but the window is held in a static registry
    /// until `windowWillClose` empties it, so relying on deallocation timing
    /// would leave a monitor running for an indeterminate stretch after the
    /// window is gone.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
