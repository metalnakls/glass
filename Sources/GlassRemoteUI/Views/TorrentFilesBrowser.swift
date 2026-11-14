import AppKit
import GlassRemoteCore
import SwiftUI

/// The same compact, hierarchical file list before and after adding a torrent.
struct TorrentFilesBrowser: View {
    let entries: [TorrentFileBrowserEntry]
    @Binding var searchText: String
    let onSetWanted: (Int, Bool) -> Void
    let onSetPriority: (Int, Int) -> Void
    let onSetAllWanted: (Bool) -> Void
    var onFileAction: ((TorrentFileTreeRow, TorrentFileActions.Action) -> Void)?
    var onKeyboardQuickLook: ((TorrentFileTreeRow, NSWindow, @escaping @MainActor () -> Bool) -> Void)?
    var keyboardContext: TorrentKeyboardQuickLookPolicy.Context = .selectionOnly
    var keyboardCommandsEnabled = false
    var showsControls = true
    var isCompact = false
    var showsCompletion = true
    var scrolls = false
    var thumbnailInput: ((TorrentFileBrowserEntry) -> TorrentThumbnailInput?)?
    var stagesChanges = false
    var onApplyWanted: (([Int: Bool]) -> Void)?
    var onSmartRename: (() -> Void)?
    @AppStorage("GlassList.showExtensions") private var showsExtensions = false
    @AppearanceStorage("GlassList.filePriorityGap") private var priorityGap = 4.0
    @AppearanceStorage("GlassInspector.nativeSelectionHighlight") private var nativeHighlight = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkboxScope = UUID()
    @State private var collapsed = Set<String>()
    @State private var treeCache = TorrentFileTreeCache()
    var editSession: TorrentFileEditSession?
    var editID = ""
    var showsActionBar = true
    var onSelectAll: (() -> Void)?
    var onSetPriorities: (([Int], Int) async -> Bool)?
    var sizeColumnText: String?
    var onSetWantedAsync: ((Int, Bool) async -> Bool)?
    @State private var wantedRequests: [Int: UUID] = [:]
    @State private var wantedFeedbackTasks: [Int: Task<Void, Never>] = [:]
    @State private var delayedWanted = Set<Int>()
    @State private var optimisticWanted: [Int: Bool] = [:]
    @State private var pendingPriorities: [Int: PendingPriority] = [:]
    private struct PendingPriority {
        let value: Int
        let requestID: UUID
    }
    @State private var nativeSelection = Set<String>()
    @State private var keyboardPreviewGeneration = 0
    @State private var availableWidth: CGFloat = 0
    @State private var localSelection = Set<Int>()
    @State private var localWanted: [Int: Bool] = [:]
    private var selection: Set<Int> {
        get { editSession?.selections[editID] ?? localSelection }
        nonmutating set { if let editSession { editSession.selections[editID] = newValue } else { localSelection = newValue } }
    }
    private var pendingWanted: [Int: Bool] {
        get { editSession?.wanted[editID] ?? localWanted }
        nonmutating set { if let editSession { editSession.wanted[editID] = newValue } else { localWanted = newValue } }
    }

    private func wanted(_ entry: TorrentFileBrowserEntry) -> Bool { optimisticWanted[entry.index] ?? pendingWanted[entry.index] ?? entry.isWanted }

    var body: some View {
        let layout = TorrentFileListLayout.shared
        let byIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        let rows = treeCache.rows(entries: entries, byIndex: byIndex, collapsed: collapsed, query: searchText)
        let nextRowIDs = Dictionary(uniqueKeysWithValues: zip(rows.map(\.id), rows.dropFirst().map(\.id)))
        let previousRowIDs = Dictionary(uniqueKeysWithValues: zip(rows.dropFirst().map(\.id), rows.map(\.id)))
        let hiddenExtension = showsExtensions ? nil : treeCache.hiddenExtension
        let widestSize = sizeColumnText ?? rows.map { formatBytes($0.size) }.max {
            $0.size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
                < $1.size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
        } ?? "0 KB"
        let inlineProgress = layout.canShowInlineProgress(width: availableWidth, sizeText: widestSize,
            depth: entries.map { max(0, $0.displayName.split(separator: "/").count - 1) }.max() ?? 0)
        let showsHierarchy = rows.contains(where: \.isFolder)
        let stacked = showsCompletion && !inlineProgress
        return VStack(alignment: .leading, spacing: 0) {
            if showsControls {
                HStack(spacing: 8) {
                    TorrentWantedCheckbox(value: !entries.isEmpty && entries.allSatisfy(wanted),
                        enabled: true, label: glassText("Download all files"), scope: checkboxScope,
                        id: "all", changed: setAllWanted)
                        .frame(width: layout.leadingIconWidth)
                    TextField(glassText("Search Files"), text: $searchText)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .focusedValue(\.glassInspectorFileFilterFocused, true)
                }
                .glassContentMargins()
                .padding(.bottom, 6)
            }
            List(selection: Binding<Set<String>>(get: { nativeSelection }, set: { ids in
                nativeSelection = ids
                selection = Set(rows.filter { ids.contains($0.id) }.flatMap(\.indices)
                    .filter { !isCompact || byIndex[$0]?.isComplete != true })
            })) {
                ForEach(rows) { row in
                    let completed = !row.indices.isEmpty && row.indices.allSatisfy { byIndex[$0]?.isComplete == true }
                    let separatorLeading = layout.iconLeadingInset(hierarchical: showsHierarchy) + CGFloat(row.depth) * layout.indent
                    HStack(spacing: layout.checkboxGap) {
                        TorrentWantedCheckbox(value: (isCompact && completed) || row.indices.allSatisfy { byIndex[$0].map(wanted) ?? false },
                            enabled: !(isCompact && completed), label: glassText("Download \(displayName(row, hiding: hiddenExtension))"),
                            scope: checkboxScope, id: row.id) { value in
                                for index in row.indices { setWanted(index, value) }
                            }
                            .frame(width: layout.leadingIconWidth)
                        HStack(spacing: layout.columnGap) {
                        HStack(spacing: 0) {
                            TorrentFileTreeLabel(row: row, name: displayName(row, hiding: hiddenExtension),
                                isExpanded: !collapsed.contains(row.id) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                showsHierarchy: showsHierarchy) {
                                    withAnimation(GlassMotion.animation(.structure, reduceMotion: reduceMotion)) {
                                        if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
                                    }
                            }
                            if row.indices.contains(where: delayedWanted.contains) {
                                GlassActivityIndicator(label: "Updating file selection", presentation: .alreadyDelayed, controlSize: .mini).padding(.leading, 6)
                            }
                            if row.indices.contains(where: { priority($0, byIndex: byIndex) > 0 }) {
                                FilePriorityIcon(high: true)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("High priority")
                                    .help("High priority")
                                    .padding(.leading, priorityGap)
                            } else if row.indices.contains(where: { priority($0, byIndex: byIndex) < 0 }) {
                                FilePriorityIcon(high: false)
                                    .offset(x: 0.5)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Low priority")
                                    .help("Low priority")
                                    .padding(.leading, priorityGap)
                            }
                            Spacer(minLength: 0)
                        }
                        TorrentFileMetadata(size: formatBytes(row.size), sizeColumnText: widestSize,
                            progress: showsCompletion && !completed && row.indices.allSatisfy({ byIndex[$0].map(wanted) ?? false })
                                ? formatPercent(progress(row, byIndex: byIndex)) : nil,
                            presentation: !showsCompletion ? .sizeOnly : (inlineProgress ? .inline : .stacked))
                        }
                    }
                    .frame(minHeight: layout.contentHeight(stacked: stacked))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in separatorLeading }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                    .padding(.horizontal, layout.selectionInterior)
                    .padding(.vertical, layout.verticalInset(stacked: stacked))
                    .background {
                        if isCompact && !nativeHighlight && nativeSelection.contains(row.id) {
                            let above = previousRowIDs[row.id].map { nativeSelection.contains($0) } ?? false
                            let below = nextRowIDs[row.id].map { nativeSelection.contains($0) } ?? false
                            TorrentFileSelectionShape(horizontalOutset: layout.selectionOutset, joinsAbove: above, joinsBelow: below)
                                .fill(Color.primary.opacity(0.07))
                        }
                        if isCompact && row.id == rows.first?.id {
                            TorrentFileListStyling(onDeselect: { index in
                                guard rows.indices.contains(index) else { return }
                                nativeSelection.remove(rows[index].id)
                                selection.subtract(rows[index].indices)
                            }, nativeHighlight: nativeHighlight)
                        }
                    }
                    .contentShape(.focusEffect, TorrentFileContextShape(horizontalOutset: layout.selectionOutset))
                    .glassContentMargins()
                    .contentShape(Rectangle())
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { adjustPriority(row, byIndex: byIndex, higher: true) } label: {
                            Image(nsImage: FilePriorityGlyph.swipeImage(high: true)).renderingMode(.original)
                        }.tint(.yellow).accessibilityLabel("Raise priority").help("Raise priority")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { adjustPriority(row, byIndex: byIndex, higher: false) } label: {
                            Image(nsImage: FilePriorityGlyph.swipeImage(high: false)).renderingMode(.original)
                        }.tint(.gray).accessibilityLabel("Lower priority").help("Lower priority")
                    }
                    .tag(row.id)
                    .listRowInsets(.vertical, 0)
                    .listRowInsets(.horizontal, 0)
                    .listRowSeparator(!TorrentInternalDragState.active && isCompact && (row.id == rows.last?.id
                        || nativeSelection.contains(row.id)
                        || (nextRowIDs[row.id].map { nativeSelection.contains($0) } ?? false)) ? .hidden : (isCompact ? .visible : .automatic), edges: .bottom)
                    .contextMenu {
                        Button(glassText("High Priority"), systemImage: "star.fill") { setPriority(row, 1) }
                        Button(glassText("Normal Priority"), systemImage: "minus") { setPriority(row, 0) }
                        Button(glassText("Low Priority"), systemImage: "arrow.down") { setPriority(row, -1) }
                        if let onSmartRename { Divider(); Button(glassText("Smart Rename"), action: onSmartRename) }
                    }
                }
            }
            .focusedValue(\.glassInspectorSelectAll, onSelectAll)
            .focusedValue(\.glassSearchDestination, .inspector)
            .contextMenu(forSelectionType: String.self) { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) {
                    Button(glassText("High Priority"), systemImage: "star.fill") { setPriority(row, 1) }
                    Button(glassText("Normal Priority"), systemImage: "minus") { setPriority(row, 0) }
                    Button(glassText("Low Priority"), systemImage: "arrow.down") { setPriority(row, -1) }
                }
            } primaryAction: { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) { onFileAction?(row, .open) }
            }
            .focusedSceneValue(\.glassInspectorQuickLookAction, keyboardQuickLookAction(rows: rows))
            .onChange(of: nativeSelection) { _, _ in keyboardPreviewGeneration += 1 }
            .onChange(of: entries) { _, _ in keyboardPreviewGeneration += 1 }
            .onChange(of: searchText) { _, _ in keyboardPreviewGeneration += 1 }
            .onChange(of: keyboardCommandsEnabled) { _, _ in keyboardPreviewGeneration += 1 }
            .onChange(of: keyboardContext) { _, _ in keyboardPreviewGeneration += 1 }
            .onChange(of: selection) { _, selected in
                guard stagesChanges else { return }
                nativeSelection = Set(rows.filter { row in
                    let editable = row.indices.filter { !isCompact || byIndex[$0]?.isComplete != true }
                    return !editable.isEmpty && editable.allSatisfy(selected.contains)
                }.map(\.id))
            }
            .onChange(of: entries) { _, updated in
                for entry in updated where optimisticWanted[entry.index] == entry.isWanted && wantedRequests[entry.index] == nil { optimisticWanted[entry.index] = nil }
                for entry in updated where pendingPriorities[entry.index]?.value == entry.priority {
                    pendingPriorities[entry.index] = nil
                }
            }
            .listStyle(.plain)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollContentBackground(.hidden)
            .scrollDisabled(!scrolls)
            .scrollIndicators(scrolls ? GlassScrollbarVisibility.visibility : .hidden)
            .environment(\.defaultMinListRowHeight, layout.rowHeight(stacked: stacked))
            .font(isCompact ? .body : .system(size: 12))
            .frame(height: scrolls ? nil : CGFloat(max(rows.count, 1)) * layout.rowHeight(stacked: stacked))
            .glassMotion(.structure, value: collapsed)
        }
        .onDisappear {
            for task in wantedFeedbackTasks.values { task.cancel() }
            wantedFeedbackTasks.removeAll()
            delayedWanted.removeAll()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if showsActionBar && (!selection.isEmpty || !pendingWanted.isEmpty) {
                HStack(spacing: 8) {
                    if !selection.isEmpty {
                        Button(glassText("Download")) { for index in selection { setWanted(index, true) } }
                        Button(glassText("Skip")) { for index in selection { setWanted(index, false) } }
                    }
                    if !pendingWanted.isEmpty {
                        Button(glassText("Apply")) {
                            if let onApplyWanted { onApplyWanted(pendingWanted) }
                            else { for (index, value) in pendingWanted { onSetWanted(index, value) } }
                            pendingWanted = [:]
                        }.buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small).padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func keyboardQuickLookAction(rows: [TorrentFileTreeRow]) -> (@MainActor (NSWindow) -> Void)? {
        let selectedRows = rows.filter { nativeSelection.contains($0.id) }
        guard selectedRows.count == 1,
              let callback = onKeyboardQuickLook,
              let entry = selectedRows[0].entry,
              TorrentKeyboardQuickLookPolicy.acceptsSpace(
                context: keyboardContext, callbackAvailable: true,
                commandsEnabled: keyboardCommandsEnabled, selectionCount: nativeSelection.count,
                path: entry.originalPath, isComplete: entry.isComplete,
                expectedSize: entry.size, firstResponder: nil
              ) else { return nil }
        let row = selectedRows[0]
        let generation = keyboardPreviewGeneration
        return { originatingWindow in
            guard TorrentKeyboardQuickLookPolicy.acceptsSpace(
                context: self.keyboardContext, callbackAvailable: self.onKeyboardQuickLook != nil,
                commandsEnabled: self.keyboardCommandsEnabled, selectionCount: self.nativeSelection.count,
                path: row.entry?.originalPath, isComplete: row.entry?.isComplete ?? false,
                expectedSize: row.entry?.size ?? 0, firstResponder: originatingWindow.firstResponder
            ) else { return }
            callback(row, originatingWindow) {
                generation == self.keyboardPreviewGeneration
                    && self.keyboardContext == .inspectorQuickLook
                    && self.keyboardCommandsEnabled
                    && self.nativeSelection.count == 1
                    && self.nativeSelection.contains(row.id)
                    && rows.contains(where: { $0.id == row.id })
                    && TorrentKeyboardQuickLookPolicy.requestStillBelongs(
                        to: originatingWindow, currentKeyWindow: NSApp.keyWindow,
                        applicationIsActive: NSApp.isActive
                    )
                    && !TorrentKeyboardQuickLookPolicy.isTextInputFirstResponder(originatingWindow.firstResponder)
            }
        }
    }

    func displayName(_ row: TorrentFileTreeRow, hiding hiddenExtension: String?) -> String {
        let name = row.isFolder ? row.name : TorrentExtensionPolicy.name(row.name, hiding: hiddenExtension)
        return name
    }

    private func progress(_ row: TorrentFileTreeRow, byIndex: [Int: TorrentFileBrowserEntry]) -> Double {
        let members = row.indices.compactMap { byIndex[$0] }
        guard row.size > 0 else { return 0 }
        let completed = members.reduce(0.0) { $0 + Double($1.isComplete ? $1.size : min($1.completedBytes, $1.size)) }
        return min(1, completed / Double(row.size))
    }

    private func selectFiles(_ indices: [Int], selected: Bool) {
        if selected { selection.formUnion(indices) }
        else { selection.subtract(indices) }
    }
    private func setAllWanted(_ value: Bool) {
        if stagesChanges {
            if let editSession {
                editSession.stageAll(value, current: Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0.isWanted) }), for: editID)
            } else {
                selection = []
                pendingWanted = Dictionary(uniqueKeysWithValues: entries.filter { $0.isWanted != value }.map { ($0.index, value) })
            }
        } else { onSetAllWanted(value) }
    }

    private func setWanted(_ index: Int, _ value: Bool) {
        guard !isCompact || entries.first(where: { $0.index == index })?.isComplete != true else { return }
        pendingWanted[index] = nil
        guard let onSetWantedAsync else { onSetWanted(index, value); return }
        let request = UUID()
        wantedRequests[index] = request
        delayedWanted.remove(index)
        wantedFeedbackTasks[index]?.cancel()
        wantedFeedbackTasks[index] = Task {
            do { try await Task.sleep(for: GlassLoadingFeedback.delay) } catch { return }
            guard !Task.isCancelled, wantedRequests[index] == request else { return }
            delayedWanted.insert(index)
        }
        optimisticWanted[index] = value
        Task {
            let succeeded = await onSetWantedAsync(index, value)
            guard wantedRequests[index] == request else { return }
            wantedRequests[index] = nil
            wantedFeedbackTasks[index]?.cancel()
            wantedFeedbackTasks[index] = nil
            delayedWanted.remove(index)
            if !succeeded { optimisticWanted[index] = nil }
        }
    }
    private func setPriority(_ row: TorrentFileTreeRow, _ value: Int) {
        let indices = selection.contains(row.indices.first ?? -1) ? Array(selection) : row.indices
        applyPriority(indices, value)
    }
    private func adjustPriority(_ row: TorrentFileTreeRow, byIndex: [Int: TorrentFileBrowserEntry], higher: Bool) {
        let grouped = Dictionary(grouping: row.indices) { index in
            TorrentFilePriority.swiping(current: priority(index, byIndex: byIndex), high: higher)
        }
        for (priority, indices) in grouped { applyPriority(indices, priority) }
    }

    private func priority(_ index: Int, byIndex: [Int: TorrentFileBrowserEntry]) -> Int {
        pendingPriorities[index]?.value ?? byIndex[index]?.priority ?? 0
    }

    private func applyPriority(_ indices: [Int], _ value: Int) {
        if let onSetPriorities {
            let requestID = UUID()
            let previous = pendingPriorities
            for index in indices { pendingPriorities[index] = PendingPriority(value: value, requestID: requestID) }
            Task {
                if !(await onSetPriorities(indices, value)) {
                    for index in indices where pendingPriorities[index]?.requestID == requestID {
                        pendingPriorities[index] = previous[index]
                    }
                }
            }
        }
        else { for index in indices { onSetPriority(index, value) } }
    }
    private func statusLabel(_ row: TorrentFileTreeRow, byIndex: [Int: TorrentFileBrowserEntry]) -> String {
        switch statusSymbol(row, byIndex: byIndex) {
        case "minus.circle": "Skipped"
        case "checkmark": "Complete"
        default: "Downloading"
        }
    }
    private func statusSymbol(_ row: TorrentFileTreeRow, byIndex: [Int: TorrentFileBrowserEntry]) -> String {
        let members = row.indices.compactMap { byIndex[$0] }
        if members.allSatisfy({ !wanted($0) }) { return "minus.circle" }
        if members.allSatisfy(\.isComplete) { return "checkmark" }
        return "arrow.down.circle"
    }
}

/// File paths and sizes define the tree. Progress, wanted flags and priorities
/// update the existing rows without rebuilding nodes or sorting folder contents.
@MainActor
final class TorrentFileTreeCache {
    private struct File: Equatable {
        let index: Int
        let originalPath: String
        let displayName: String
        let size: UInt64
        init(_ entry: TorrentFileBrowserEntry) {
            index = entry.index
            originalPath = entry.originalPath
            displayName = entry.displayName
            size = entry.size
        }
    }
    private var files: [File]?
    private var collapsed = Set<String>()
    private var query = ""
    private var cachedRows: [TorrentFileTreeRow] = []
    private(set) var hiddenExtension: String?

    func rows(entries: [TorrentFileBrowserEntry], byIndex: [Int: TorrentFileBrowserEntry],
              collapsed: Set<String>, query: String) -> [TorrentFileTreeRow] {
        let files = entries.map(File.init)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let topologyChanged = self.files != files
        if topologyChanged {
            hiddenExtension = TorrentExtensionPolicy.hiddenExtension(paths: entries.map(\.originalPath))
        }
        if topologyChanged || self.collapsed != collapsed || self.query != query {
            self.files = files
            self.collapsed = collapsed
            self.query = query
            cachedRows = TorrentFileTreeRow.rows(entries: entries, collapsed: collapsed, query: query)
        }
        // Keep file actions and callers supplied with current telemetry, even
        // though the path topology is shared across refreshes.
        return cachedRows.map { row in
            TorrentFileTreeRow(id: row.id, name: row.name, depth: row.depth,
                indices: row.indices, size: row.size, entry: row.entry.flatMap { byIndex[$0.index] })
        }
    }
}

struct TorrentFileTreeRow: Identifiable {
    let id: String
    let name: String
    let depth: Int
    let indices: [Int]
    let size: UInt64
    let entry: TorrentFileBrowserEntry?
    var isFolder: Bool { entry == nil }

    private final class Node {
        let path: String
        let name: String
        var entry: TorrentFileBrowserEntry?
        var indices: [Int] = []
        var size: UInt64 = 0
        var children: [String: Node] = [:]
        init(path: String, name: String) { self.path = path; self.name = name }
    }

    static func rows(entries: [TorrentFileBrowserEntry], collapsed: Set<String>, query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = Node(path: "", name: "")
        func matches(_ entry: TorrentFileBrowserEntry) -> Bool {
            if query.isEmpty || entry.displayName.localizedCaseInsensitiveContains(query) || entry.originalPath.localizedCaseInsensitiveContains(query) { return true }
            let folders = entry.displayName.split(separator: "/").dropLast()
                .map { TorrentNameCleaner.seasonFolderName(String($0)) }.joined(separator: "/")
            return folders.localizedCaseInsensitiveContains(query)
        }
        for entry in entries where matches(entry) {
            let components = entry.displayName.split(separator: "/").map(String.init)
            var parent = root
            for (offset, name) in components.enumerated() {
                let path = parent.path.isEmpty ? name : parent.path + "/" + name
                let node = parent.children[name] ?? Node(path: path, name: name)
                parent.children[name] = node
                node.indices.append(entry.index)
                node.size += entry.size
                if offset == components.count - 1 { node.entry = entry }
                parent = node
            }
        }
        func flatten(_ parent: Node, depth: Int) -> [Self] {
            parent.children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.flatMap { node in
                let title = node.entry == nil ? TorrentNameCleaner.seasonFolderName(node.name) : node.name
                let row = Self(id: node.path, name: title, depth: depth, indices: node.indices, size: node.size, entry: node.entry)
                return [row] + (node.entry == nil && (!collapsed.contains(node.path) || !query.isEmpty) ? flatten(node, depth: depth + 1) : [])
            }
        }
        return flatten(root, depth: 0)
    }
}

struct TorrentFilesBrowserControls: View {
    @Binding var searchText: String
    let onSetAllWanted: (Bool) -> Void
    var isCompact = false
    var showsCompletion = true
    var body: some View {
        TextField(glassText("Search Files"), text: $searchText)
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .focusedValue(\.glassInspectorFileFilterFocused, true)
    }
}

struct TorrentFileBrowserEntry: Identifiable, Hashable {
    let index: Int
    let originalPath: String
    let displayName: String
    let size: UInt64
    let completedBytes: UInt64
    let isWanted: Bool
    let priority: Int

    var isComplete: Bool { wasCompleted || completedBytes >= size }
    let wasCompleted: Bool

    var id: Int { index }
    var pickedSortValue: Int { isWanted ? 0 : 1 }

    var progress: Double {
        guard size > 0 else { return 0 }
        return min(Double(completedBytes) / Double(size), 1)
    }

    init(
        index: Int,
        file: TorrentFile,
        rootName: String,
        displayName: String? = nil,
        completedBytes: UInt64? = nil,
        isWanted: Bool = true,
        priority: Int = 0,
        wasCompleted: Bool = false
    ) {
        self.index = index
        self.originalPath = file.name
        let relative = Self.relativePath(file.name, removingRoot: rootName)
        if let displayName, !displayName.contains("/"), relative.contains("/") {
            self.displayName = (relative as NSString).deletingLastPathComponent + "/" + displayName
        } else { self.displayName = displayName ?? relative }
        self.size = file.length
        self.completedBytes = completedBytes ?? file.bytesCompleted
        self.isWanted = isWanted
        self.priority = priority
        self.wasCompleted = wasCompleted
    }

    /// Grouping an already prepared entry must preserve its relative display path.
    init(grouping entry: Self, index: Int, prefix: String) {
        self.index = index
        originalPath = entry.originalPath
        displayName = prefix + entry.displayName
        size = entry.size
        completedBytes = entry.completedBytes
        priority = entry.priority
        isWanted = entry.isWanted
        wasCompleted = entry.wasCompleted
    }

    static func commonRoot(paths: [String]) -> String? {
        guard let first = paths.first?.split(separator: "/").first, !paths.isEmpty,
              paths.allSatisfy({ path in
                  let parts = path.split(separator: "/")
                  return parts.count > 1 && parts.first == first
              }) else { return nil }
        return String(first)
    }

    static func relativePath(_ path: String, removingRoot rootName: String) -> String {
        let rootPrefix = rootName + "/"
        guard path.hasPrefix(rootPrefix) else { return path }
        return String(path.dropFirst(rootPrefix.count))
    }
}
