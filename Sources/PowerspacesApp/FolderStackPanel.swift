// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import SwiftUI

// MARK: - Model

/// One file or folder shown in a stack. Folders load their children lazily, the
/// first time they're expanded.
@MainActor
final class StackNode: ObservableObject, Identifiable {
    let url: URL
    let name: String
    let isFolder: Bool
    let dateAdded: Date
    let depth: Int
    @Published var isExpanded = false
    @Published private(set) var children: [StackNode]?
    /// Entries past the per-level cap (so a huge folder stays snappy); the row
    /// offers "Show N more in Finder" instead.
    private(set) var hiddenCount = 0

    init(url: URL, name: String, isFolder: Bool, dateAdded: Date, depth: Int) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.dateAdded = dateAdded
        self.depth = depth
    }

    var id: URL { url }

    func loadChildren(sort: StackSort) {
        let (nodes, hidden) = StackNode.contents(of: url, depth: depth + 1, sort: sort)
        children = nodes
        hiddenCount = hidden
    }

    /// Children once loaded, in the given sort. Folders are browsable in place;
    /// packages (.app, .rtfd, a Photos library …) are treated as files.
    static func contents(of folder: URL, depth: Int, sort: StackSort,
                         cap: Int = 200) -> ([StackNode], Int) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey,
                                      .addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var nodes = urls.map { url -> StackNode in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return StackNode(url: url,
                             name: v?.localizedName ?? url.lastPathComponent,
                             isFolder: v?.isDirectory == true && v?.isPackage != true,
                             dateAdded: v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast,
                             depth: depth)
        }
        switch sort {
        case .dateAdded:
            nodes.sort { $0.dateAdded > $1.dateAdded }
        case .name:
            nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .foldersFirst:
            nodes.sort {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        let hidden = max(0, nodes.count - cap)
        return (Array(nodes.prefix(cap)), hidden)
    }
}

enum StackSort: String, CaseIterable, Identifiable {
    case dateAdded, name, foldersFirst
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .name: return "Name"
        case .foldersFirst: return "Folders First"
        }
    }
}

/// The stack's state: its root folder's entries plus the accordion rule — at
/// most one expanded subfolder per level, so opening one collapses its siblings.
@MainActor
final class FolderStackModel: ObservableObject {
    let folder: URL
    @Published private(set) var root: [StackNode] = []
    @Published private(set) var rootHiddenCount = 0
    @Published var sort: StackSort {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey(folder))
            reload()
        }
    }

    init(folder: URL) {
        self.folder = folder
        // Remembered per folder; Downloads-style "newest first" by default.
        let saved = UserDefaults.standard.string(forKey: Self.sortKey(folder))
        sort = saved.flatMap(StackSort.init(rawValue:)) ?? .dateAdded
        reload()
    }

    private static func sortKey(_ folder: URL) -> String { "folderStackSort:" + folder.path }

    func reload() {
        let (nodes, hidden) = StackNode.contents(of: folder, depth: 0, sort: sort)
        root = nodes
        rootHiddenCount = hidden
    }

    /// Flip a subfolder open/closed. Opening it collapses its expanded siblings
    /// (and everything under them) — the accordion behaviour.
    func toggle(_ node: StackNode, siblings: [StackNode]) {
        guard node.isFolder else { return }
        if node.isExpanded {
            collapse(node)
        } else {
            siblings.filter { $0 !== node && $0.isExpanded }.forEach(collapse)
            if node.children == nil { node.loadChildren(sort: sort) }
            node.isExpanded = true
        }
        objectWillChange.send()
    }

    private func collapse(_ node: StackNode) {
        node.isExpanded = false
        node.children?.forEach { if $0.isExpanded { collapse($0) } }
    }

    /// Every row currently on screen, in display order (for sizing the panel).
    var visibleRowCount: Int {
        func count(_ nodes: [StackNode]) -> Int {
            nodes.reduce(0) { total, node in
                total + 1 + (node.isExpanded ? count(node.children ?? []) + (node.hiddenCount > 0 ? 1 : 0) : 0)
            }
        }
        return count(root) + (rootHiddenCount > 0 ? 1 : 0)
    }
}

// MARK: - View

private let rowHeight: CGFloat = 28
private let headerHeight: CGFloat = 44

struct FolderStackView: View {
    @ObservedObject var model: FolderStackModel
    var onOpen: (URL) -> Void
    var onReveal: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.root.isEmpty {
                Text("Empty folder")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: rowHeight * 2)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        rows(model.root, hidden: model.rootHiddenCount, parent: model.folder)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 340)
        .background(VisualEffectBackground())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.folder.path))
                .resizable().frame(width: 22, height: 22)
            Text(FileManager.default.displayName(atPath: model.folder.path))
                .font(.headline).lineLimit(1)
            Spacer()
            Menu {
                Picker("Sort By", selection: $model.sort) {
                    ForEach(StackSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort")
            // Opening a folder URL opens it in a Finder window.
            Button { onOpen(model.folder) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Open in Finder")
        }
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
    }

    /// One level of rows; an expanded folder's children render directly beneath
    /// it (indented), which is what makes the list an accordion. Recursive, hence
    /// type-erased. `Group` flattens into the surrounding `LazyVStack`.
    private func rows(_ nodes: [StackNode], hidden: Int, parent: URL) -> AnyView {
        AnyView(Group {
            ForEach(nodes) { node in
                StackRow(node: node,
                         onTap: {
                             if node.isFolder {
                                 withAnimation(.easeInOut(duration: 0.15)) { model.toggle(node, siblings: nodes) }
                             } else {
                                 onOpen(node.url)
                             }
                         },
                         onOpen: onOpen, onReveal: onReveal)
                if node.isExpanded, let children = node.children {
                    if children.isEmpty {
                        placeholder("Empty", depth: node.depth + 1)
                    } else {
                        rows(children, hidden: node.hiddenCount, parent: node.url)
                    }
                }
            }
            if hidden > 0 {
                Button("Show \(hidden) more in Finder…") { onOpen(parent) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .padding(.leading, CGFloat(nodes.first?.depth ?? 0) * 16 + 38)
            }
        })
    }

    private func placeholder(_ text: String, depth: Int) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .padding(.leading, CGFloat(depth) * 16 + 38)
    }
}

private struct StackRow: View {
    @ObservedObject var node: StackNode
    let onTap: () -> Void
    let onOpen: (URL) -> Void
    let onReveal: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Chevron column (kept for files too, so names line up).
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                .opacity(node.isFolder ? 0.7 : 0)
                .frame(width: 12)
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable().frame(width: 20, height: 20)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(node.depth) * 16)
        .padding(.trailing, 10)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering ? Color.accentColor.opacity(0.25) : .clear)
            .padding(.horizontal, 4))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        // Drag the file itself out of the stack, like a Dock stack. The provider
        // carries the file's URL (not a copy of its contents), so Finder moves or
        // copies the real file under its real name, and other apps receive the file
        // as-is. `NSItemProvider(contentsOf:)` handed over only the data, and Finder
        // then named the new file after its type ("JavaScript.js", "Patch file.PATCH").
        .onDrag {
            let provider = NSItemProvider(object: node.url as NSURL)
            provider.suggestedName = node.url.lastPathComponent
            return provider
        }
        .contextMenu {
            Button("Open") { onOpen(node.url) }
            Button("Show in Finder") { onReveal(node.url) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([node.url as NSURL])
            }
            Divider()
            Button("Move to Trash") {
                NSWorkspace.shared.recycle([node.url]) { _, _ in }
            }
        }
        .help(node.url.path)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Panel

/// A floating stack for a pinned folder, anchored to its dock tile like the macOS
/// Dock's List view. Subfolders expand in place (one open per level). Dismisses
/// on Escape, a click in another app, opening an item, or clicking the tile again.
@MainActor
final class FolderStackPanel: NSPanel {
    private var model: FolderStackModel?
    private var sizeObserver: Any?
    private var clickOutsideMonitor: Any?
    private var keyMonitor: Any?
    /// The tile it's anchored to, in screen coordinates, and that tile's screen.
    private var anchor: NSRect = .zero
    private weak var anchorScreen: NSScreen?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    /// Open the stack for `folder` above (or beside) `tile`; clicking the same
    /// tile again closes it.
    func toggle(folder: URL, from tile: NSView) {
        if isVisible, model?.folder == folder { close(); return }
        guard let window = tile.window else { return }
        anchor = window.convertToScreen(tile.convert(tile.bounds, to: nil))
        anchorScreen = window.screen

        let model = FolderStackModel(folder: folder)
        self.model = model
        let root = FolderStackView(
            model: model,
            onOpen: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onReveal: { [weak self] url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
                self?.close()
            })
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        contentView = hosting

        // Grow/shrink with the accordion so short lists don't sit in a tall box.
        sizeObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutAtAnchor() }
        }
        layoutAtAnchor()
        installMonitors()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        removeMonitors()
        sizeObserver = nil
        model = nil
        super.close()
    }

    /// Size to the visible rows (capped to most of the screen) and sit on the
    /// bar's inner side of the tile, keeping the dock-facing edge fixed.
    private func layoutAtAnchor() {
        guard let model, let screen = anchorScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let rows = max(model.visibleRowCount, 2)
        let height = min(headerHeight + 9 + CGFloat(rows) * rowHeight, visible.height * 0.7)
        let size = NSSize(width: 340, height: height)
        let gap: CGFloat = 10
        var origin: NSPoint
        switch Preferences.shared.barPosition {
        case .bottom: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .top:    origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
        case .left:   origin = NSPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .right:  origin = NSPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
        }
        // Keep it on screen.
        let frame = screen.frame.insetBy(dx: 6, dy: 6)
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
        invalidateShadow()
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event } // Escape
            self.close()
            return nil
        }
        // Global monitors don't see our own windows, so a click on the tile itself
        // reaches `toggle` (which closes) instead of reopening straight away.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        keyMonitor = nil
        clickOutsideMonitor = nil
    }
}
