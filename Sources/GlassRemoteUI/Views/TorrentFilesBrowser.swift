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
    var showsControls = true
    var isCompact = false
    var shortEpisodeNames = false
    var thumbnailInput: ((TorrentFileBrowserEntry) -> TorrentThumbnailInput?)?
    var stagesChanges = false
    var onApplyWanted: (([Int: Bool]) -> Void)?
    var onSmartRename: (() -> Void)?
    @AppStorage("GlassList.showExtensions") private var showsExtensions = false
    @AppearanceStorage("GlassList.filePriorityGap") private var priorityGap = 4.0
    @State private var collapsed = Set<String>()
    var editSession: TorrentFileEditSession?
    var editID = ""
    var showsActionBar = true
    var onSetPriorities: (([Int], Int) async -> Bool)?
    @State private var pendingPriorities: [Int: PendingPriority] = [:]
    private struct PendingPriority {
        let value: Int
        let requestID: UUID
    }
    @State private var nativeSelection = Set<String>()
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

    private var rows: [TorrentFileTreeRow] {
        TorrentFileTreeRow.rows(entries: entries, collapsed: collapsed, query: searchText)
    }
    private var hiddenExtension: String? {
        showsExtensions ? nil : TorrentExtensionPolicy.hiddenExtension(paths: entries.map(\.originalPath))
    }
    private func wanted(_ entry: TorrentFileBrowserEntry) -> Bool { pendingWanted[entry.index] ?? entry.isWanted }

    var body: some View {
        let byIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        return VStack(alignment: .leading, spacing: 0) {
            if showsControls {
                HStack(spacing: 8) {
                    Toggle("Download all files", isOn: Binding(
                        get: { !entries.isEmpty && entries.allSatisfy(wanted) },
                        set: { value in setAllWanted(value) }
                    ))
                    .labelsHidden().toggleStyle(.checkbox).controlSize(.regular)
                    TextField("Search Files", text: $searchText)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .focusedValue(\.glassInspectorFileFilterFocused, true)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            List(selection: Binding<Set<String>>(get: { nativeSelection }, set: { ids in
                nativeSelection = ids
                selection = Set(rows.filter { ids.contains($0.id) }.flatMap(\.indices))
            })) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Toggle("Download \(row.name)", isOn: Binding(
                            get: { row.indices.allSatisfy { byIndex[$0].map(wanted) ?? false } },
                            set: { value in for index in row.indices { setWanted(index, value) } }
                        )).labelsHidden().toggleStyle(.checkbox).controlSize(.regular)
                        HStack(spacing: 0) {
                            if row.isFolder {
                                Button {
                                    if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
                                } label: {
                                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                                }.buttonStyle(.plain).padding(.trailing, 4)
                            }
                            Text(displayName(row))
                                .lineLimit(1).truncationMode(.middle)
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
                        .padding(.leading, CGFloat(row.depth) * 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatBytes(row.size))
                            Text(formatPercent(progress(row, byIndex: byIndex)))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption).monospacedDigit()
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        if NSEvent.modifierFlags.contains(.command) { onFileAction?(row, .reveal) }
                    })
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { adjustPriority(row, byIndex: byIndex, higher: true) } label: {
                            Label("Raise priority", systemImage: "arrow.up")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { adjustPriority(row, byIndex: byIndex, higher: false) } label: {
                            Label("Lower priority", systemImage: "arrow.down")
                        }
                    }
                    .tag(row.id)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .contextMenu {
                        Button("High Priority", systemImage: "star.fill") { setPriority(row, 1) }
                        Button("Normal Priority", systemImage: "minus") { setPriority(row, 0) }
                        Button("Low Priority", systemImage: "arrow.down") { setPriority(row, -1) }
                        if let onSmartRename { Divider(); Button("Smart Rename", action: onSmartRename) }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) {
                    Button("High Priority", systemImage: "star.fill") { setPriority(row, 1) }
                    Button("Normal Priority", systemImage: "minus") { setPriority(row, 0) }
                    Button("Low Priority", systemImage: "arrow.down") { setPriority(row, -1) }
                }
            } primaryAction: { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) { onFileAction?(row, .open) }
            }
            .onKeyPress(.space, phases: [.down]) { _ in
                guard let onFileAction, let row = rows.first(where: { nativeSelection.contains($0.id) }) else { return .ignored }
                onFileAction(row, .preview); return .handled
            }
            .onChange(of: selection) { _, selected in
                guard stagesChanges else { return }
                nativeSelection = Set(rows.filter { !$0.indices.isEmpty && $0.indices.allSatisfy(selected.contains) }.map(\.id))
            }
            .onChange(of: entries) { _, updated in
                for entry in updated where pendingPriorities[entry.index]?.value == entry.priority {
                    pendingPriorities[entry.index] = nil
                }
            }
            .listStyle(.plain)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, 38)
            .font(.system(size: 12))
            .frame(height: CGFloat(max(rows.count, 1)) * 38)
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if showsActionBar && (!selection.isEmpty || !pendingWanted.isEmpty) {
                HStack(spacing: 8) {
                    if !selection.isEmpty {
                        Button("Download") { for index in selection { setWanted(index, true) } }
                        Button("Skip") { for index in selection { setWanted(index, false) } }
                    }
                    if !pendingWanted.isEmpty {
                        Button("Apply") {
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

    private func displayName(_ row: TorrentFileTreeRow) -> String {
        let name = row.isFolder ? row.name : TorrentExtensionPolicy.name(row.name, hiding: hiddenExtension)
        guard shortEpisodeNames, !row.isFolder,
              let range = name.range(of: "^S[0-9]+E[0-9]+", options: [.regularExpression, .caseInsensitive]) else { return name }
        return String(name[range]).uppercased()
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
        pendingWanted[index] = nil
        onSetWanted(index, value)
    }
    private func setPriority(_ row: TorrentFileTreeRow, _ value: Int) {
        let indices = selection.contains(row.indices.first ?? -1) ? Array(selection) : row.indices
        applyPriority(indices, value)
    }
    private func adjustPriority(_ row: TorrentFileTreeRow, byIndex: [Int: TorrentFileBrowserEntry], higher: Bool) {
        let grouped = Dictionary(grouping: row.indices) { index in
            min(1, max(-1, priority(index, byIndex: byIndex) + (higher ? 1 : -1)))
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
        for entry in entries where query.isEmpty || entry.displayName.localizedCaseInsensitiveContains(query) || entry.originalPath.localizedCaseInsensitiveContains(query) {
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
                let row = Self(id: node.path, name: node.name, depth: depth, indices: node.indices, size: node.size, entry: node.entry)
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
    var body: some View {
        TextField("Search Files", text: $searchText)
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
