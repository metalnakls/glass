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
    @State private var collapsed = Set<String>()
    @State private var selection = Set<Int>()
    @State private var pendingWanted: [Int: Bool] = [:]

    private var rows: [TorrentFileTreeRow] {
        TorrentFileTreeRow.rows(entries: entries, collapsed: collapsed, query: searchText)
    }
    private func wanted(_ entry: TorrentFileBrowserEntry) -> Bool { pendingWanted[entry.index] ?? entry.isWanted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    TorrentSwipeRow(selected: !selection.isDisjoint(with: row.indices), remove: { higher in
                        for index in row.indices {
                            let current = entries.first { $0.index == index }?.priority ?? 0
                            onSetPriority(index, min(1, max(-1, current + (higher ? 1 : -1))))
                        }
                    }, presentationChanged: { _ in },
                    leading: .init(name: "Lower priority", symbol: "arrow.down", color: .gray),
                    trailing: .init(name: "Raise priority", symbol: "arrow.up", color: .gray)) {
                        HStack(spacing: 5) {
                            Toggle("Download \(row.name)", isOn: Binding(
                                get: { row.indices.allSatisfy { index in entries.first { $0.index == index }.map(wanted) ?? false } },
                                set: { value in for index in row.indices { setWanted(index, value) } }
                            ))
                            .labelsHidden().toggleStyle(.checkbox)
                            .padding(.leading, CGFloat(row.depth) * 12)
                            if row.isFolder {
                                Button {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
                                    }
                                } label: {
                                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .frame(width: 20, height: 26).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Text(row.name)
                                .font(.system(size: 12, weight: row.isFolder ? .medium : .regular))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(formatBytes(row.size)).font(.system(size: 10)).monospacedDigit()
                                HStack(spacing: 3) {
                                    if let priority = row.entry?.priority, priority != 0 {
                                        Image(systemName: priority > 0 ? "star.fill" : "arrow.down")
                                    }
                                    Image(systemName: statusSymbol(row))
                                }
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 29)
                        .padding(.horizontal, 3)
                        .background(selection.isDisjoint(with: row.indices) ? Color.clear : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                for index in row.indices {
                                    if !selection.insert(index).inserted { selection.remove(index) }
                                }
                            } else { selection = Set(row.indices) }
                        }
                        .contextMenu {
                            Button("High Priority", systemImage: "star.fill") { setPriority(row, 1) }
                            Button("Normal Priority", systemImage: "minus") { setPriority(row, 0) }
                            Button("Low Priority", systemImage: "arrow.down") { setPriority(row, -1) }
                            if let onSmartRename {
                                Divider()
                                Button("Smart Rename", action: onSmartRename)
                            }
                        }
                    }
                    Divider().opacity(0.35)
                }
                if rows.isEmpty { Text("No matching files").font(.caption).foregroundStyle(.secondary).padding(.vertical, 10) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if !selection.isEmpty || !pendingWanted.isEmpty {
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
        for index in indices { onSetPriority(index, value) }
    }
    private func statusSymbol(_ row: TorrentFileTreeRow) -> String {
        let members = entries.filter { row.indices.contains($0.index) }
        if members.allSatisfy({ !wanted($0) }) { return "minus.circle" }
        if members.allSatisfy({ $0.completedBytes >= $0.size }) { return "checkmark" }
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

    static func rows(entries: [TorrentFileBrowserEntry], collapsed: Set<String>, query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = entries.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.originalPath.localizedCaseInsensitiveContains(query) }
        func descend(_ prefix: String, depth: Int) -> [Self] {
            let members = visible.filter { prefix.isEmpty || $0.displayName.hasPrefix(prefix + "/") }
            let names = Set(members.compactMap { entry -> String? in
                let suffix = prefix.isEmpty ? entry.displayName : String(entry.displayName.dropFirst(prefix.count + 1))
                return suffix.split(separator: "/").first.map(String.init)
            }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return names.flatMap { name -> [Self] in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let children = members.filter { $0.displayName == path || $0.displayName.hasPrefix(path + "/") }
                let entry = children.count == 1 && children[0].displayName == path ? children[0] : nil
                let row = Self(id: path, name: name, depth: depth, indices: children.map(\.index), size: children.reduce(0) { $0 + $1.size }, entry: entry)
                return [row] + (entry == nil && (!collapsed.contains(path) || !query.isEmpty) ? descend(path, depth: depth + 1) : [])
            }
        }
        return descend("", depth: 0)
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
        priority: Int = 0
    ) {
        self.index = index
        self.originalPath = file.name
        self.displayName = displayName ?? Self.relativePath(file.name, removingRoot: rootName)
        self.size = file.length
        self.completedBytes = completedBytes ?? file.bytesCompleted
        self.isWanted = isWanted
        self.priority = priority
    }

    static func relativePath(_ path: String, removingRoot rootName: String) -> String {
        let rootPrefix = rootName + "/"
        guard path.hasPrefix(rootPrefix) else { return path }
        return String(path.dropFirst(rootPrefix.count))
    }
}
