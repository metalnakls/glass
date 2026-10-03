import AppKit
import GlassRemoteCore
import SwiftUI

/// The same compact, hierarchical file table before and after adding a torrent.
struct TorrentFilesBrowser: View {
    let entries: [TorrentFileBrowserEntry]
    @Binding var searchText: String
    let onSetWanted: (Int, Bool) -> Void
    let onSetPriority: (Int, Int) -> Void
    let onSetAllWanted: (Bool) -> Void
    var showsControls = true
    var isCompact = false
    var thumbnailInput: ((TorrentFileBrowserEntry) -> TorrentThumbnailInput?)?
    var stagesChanges = false
    var onApplyWanted: (([Int: Bool]) -> Void)?
    var onSmartRename: (() -> Void)?
    @AppStorage("GlassList.showExtensions") private var showsExtensions = false
    @State private var collapsed = Set<String>()
    var editSession: TorrentFileEditSession?
    var editID = ""
    var showsActionBar = true
    var onSetPriorities: (([Int], Int) -> Void)?
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
                    Toggle("Select all files", isOn: Binding(
                        get: { !entries.isEmpty && entries.allSatisfy(wanted) },
                        set: { value in for entry in entries { setWanted(entry.index, value) } }
                    ))
                    .labelsHidden().toggleStyle(.checkbox)
                    TextField("Search Files", text: $searchText)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .focusedValue(\.glassInspectorFileFilterFocused, true)
                }
                .padding(.bottom, 6)
            }
            Table(rows, selection: Binding<Set<String>>(get: {
                nativeSelection
            }, set: { ids in
                nativeSelection = ids
                selection = Set(rows.filter { ids.contains($0.id) }.flatMap(\.indices))
            })) {
                TableColumn("") { row in
                    Toggle("Download \(row.name)", isOn: Binding(
                        get: { row.indices.allSatisfy { byIndex[$0].map(wanted) ?? false } },
                        set: { value in for index in row.indices { setWanted(index, value) } }
                    )).labelsHidden().toggleStyle(.checkbox).controlSize(.small)
                }.width(20)
                TableColumn("Name") { row in
                    TorrentSwipeRow(selected: !selection.isDisjoint(with: row.indices), remove: { higher in
                        let grouped = Dictionary(grouping: row.indices) { index in
                            min(1, max(-1, (byIndex[index]?.priority ?? 0) + (higher ? 1 : -1)))
                        }
                        for (priority, indices) in grouped { applyPriority(indices, priority) }
                    }, presentationChanged: { _ in }, compactActions: true,
                    leading: .init(name: "Lower priority", symbol: "arrow.down", color: .gray),
                    trailing: .init(name: "Raise priority", symbol: "arrow.up", color: .gray)) {
                        HStack(spacing: 4) {
                            if row.isFolder {
                                Button {
                                    if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
                                } label: {
                                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 20)
                                }.buttonStyle(.plain)
                            } else { Color.clear.frame(width: 14, height: 1) }
                            Text(row.isFolder ? row.name : TorrentExtensionPolicy.name(row.name, hiding: hiddenExtension))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, CGFloat(row.depth) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contextMenu {
                        Button("High Priority", systemImage: "star.fill") { setPriority(row, 1) }
                        Button("Normal Priority", systemImage: "minus") { setPriority(row, 0) }
                        Button("Low Priority", systemImage: "arrow.down") { setPriority(row, -1) }
                        if let onSmartRename { Divider(); Button("Smart Rename", action: onSmartRename) }
                    }
                }.width(min: 70, ideal: 180, max: .infinity)
                TableColumn("") { row in
                    Image(systemName: statusSymbol(row, byIndex: byIndex))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                }.width(18)
                TableColumn("Size") { row in
                    Text(formatBytes(row.size)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }.width(68)
            }
            .tableStyle(.inset)
            .controlSize(.small)
            .font(.system(size: 12))
            .frame(height: CGFloat(max(rows.count, 1)) * 24 + 28)
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if showsActionBar && (!selection.isEmpty || !pendingWanted.isEmpty) {
                HStack(spacing: 8) {
                    if !selection.isEmpty {
                        Button("Download") { for index in selection { setWanted(index, true) } }
                        Button("Skip") { for index in selection { setWanted(index, false) } }
                    }
                    Spacer(minLength: 0)
                    if !pendingWanted.isEmpty {
                        Button("Cancel") { pendingWanted = [:] }
                        Button("Apply") {
                            if let onApplyWanted { onApplyWanted(pendingWanted) }
                            else { for (index, value) in pendingWanted { onSetWanted(index, value) } }
                            pendingWanted = [:]
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small).padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func setWanted(_ index: Int, _ value: Bool) {
        if stagesChanges { pendingWanted[index] = value }
        else { onSetWanted(index, value) }
    }
    private func setPriority(_ row: TorrentFileTreeRow, _ value: Int) {
        let indices = selection.contains(row.indices.first ?? -1) ? Array(selection) : row.indices
        applyPriority(indices, value)
    }
    private func applyPriority(_ indices: [Int], _ value: Int) {
        if let onSetPriorities { onSetPriorities(indices, value) }
        else { for index in indices { onSetPriority(index, value) } }
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
