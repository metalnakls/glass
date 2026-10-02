import GlassRemoteCore
import SwiftUI

/// The canonical Finder-style file surface used before and after a torrent is added.
struct TorrentFilesBrowser: View {
    let entries: [TorrentFileBrowserEntry]
    @Binding var searchText: String
    let onSetWanted: (Int, Bool) -> Void
    let onSetPriority: (Int, Int) -> Void
    let onSetAllWanted: (Bool) -> Void
    var showsControls = true
    var thumbnailInput: ((TorrentFileBrowserEntry) -> TorrentThumbnailInput?)?

    @State private var sortOrder: [KeyPathComparator<TorrentFileBrowserEntry>] = [
        KeyPathComparator(\.displayName, order: .forward)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsControls {
                TorrentFilesBrowserControls(
                    searchText: $searchText,
                    onSetAllWanted: onSetAllWanted
                )
            }

            Table(filteredEntries.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("Picked", value: \.pickedSortValue) { entry in
                    Toggle(
                        "Download \(entry.displayName)",
                        isOn: Binding(
                            get: { entry.isWanted },
                            set: { onSetWanted(entry.index, $0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
                .width(min: 46, ideal: 54, max: 64)

                TableColumn("Name", value: \.displayName) { entry in
                    HStack(spacing: 6) {
                        TorrentFileIcon(fileName: entry.displayName, isFolder: false, size: 18, thumbnailInput: thumbnailInput?(entry))
                        Text(entry.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .width(min: 150, ideal: 260)

                TableColumn("Size", value: \.size) { entry in
                    Text(formatBytes(entry.size))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 82, max: 100)

                TableColumn("Progress", value: \.progress) { entry in
                    Text(entry.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 78, max: 92)

                TableColumn("Priority", value: \.priority) { entry in
                    Menu {
                        priorityMenu(for: entry)
                    } label: {
                        Label(
                            formatPriority(entry.priority),
                            systemImage: prioritySystemImage(entry.priority)
                        )
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Priority: \(formatPriority(entry.priority))")
                }
                .width(min: 58, ideal: 68, max: 82)
            }
            .tableStyle(.inset)
            .frame(height: tableHeight)
            .overlay {
                if filteredEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var filteredEntries: [TorrentFileBrowserEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.originalPath.localizedCaseInsensitiveContains(query)
        }
    }

    private var tableHeight: CGFloat {
        min(max(CGFloat(entries.count) * 28 + 30, 116), 300)
    }

    @ViewBuilder
    private func priorityMenu(for entry: TorrentFileBrowserEntry) -> some View {
        Toggle("High", isOn: priorityBinding(1, for: entry))
        Toggle("Normal", isOn: priorityBinding(0, for: entry))
        Toggle("Low", isOn: priorityBinding(-1, for: entry))
    }

    private func priorityBinding(_ priority: Int, for entry: TorrentFileBrowserEntry) -> Binding<Bool> {
        Binding(
            get: { entry.priority == priority },
            set: { isSelected in
                guard isSelected else { return }
                onSetPriority(entry.index, priority)
            }
        )
    }
}

struct TorrentFilesBrowserControls: View {
    @Binding var searchText: String
    let onSetAllWanted: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search Files", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 120, maxWidth: .infinity)
                .focusedValue(\.glassInspectorFileFilterFocused, true)

            ControlGroup {
                Button("All", systemImage: "checkmark.square") {
                    onSetAllWanted(true)
                }
                Button("None", systemImage: "square") {
                    onSetAllWanted(false)
                }
            }
            .controlSize(.small)
        }
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
