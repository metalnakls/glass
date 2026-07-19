import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentListView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let torrents: [TorrentSummary]
    let pendingRenameOldNames: [String: String]
    @Binding var selection: String?
    let rename: (TorrentSummary) -> Void
    let remove: (TorrentSummary, Bool) -> Void
    let removeSelected: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var collapsedAutoGroupIDs = Set<String>()
    @State private var groupedItems: [TorrentListItem]
    @State private var usesCompactRows = false
    @FocusState private var isTorrentListFocused: Bool
    @Namespace private var groupFolderNamespace

    init(
        model: RemoteAppModel,
        platformIntegration: any GlassPlatformIntegrating,
        torrents: [TorrentSummary],
        pendingRenameOldNames: [String: String],
        selection: Binding<String?>,
        rename: @escaping (TorrentSummary) -> Void,
        remove: @escaping (TorrentSummary, Bool) -> Void,
        removeSelected: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.platformIntegration = platformIntegration
        self.torrents = torrents
        self.pendingRenameOldNames = pendingRenameOldNames
        self._selection = selection
        self.rename = rename
        self.remove = remove
        self.removeSelected = removeSelected
        self._groupedItems = State(initialValue: TorrentNameSequenceGrouper.items(for: torrents))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groupedItems) { item in
                        torrentListItem(item)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .glassSwipeActionsContainer()
            .onGeometryChange(for: Bool.self, of: { proxy in
                proxy.size.width < 430
            }) { usesCompactRows = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($isTorrentListFocused)
            .onMoveCommand(perform: moveSelection)
            .onKeyPress(.delete, phases: [.down]) { keyPress in
                guard selectedTorrent != nil else { return .ignored }
                removeSelected(keyPress.modifiers.contains(.command))
                return .handled
            }
            .onKeyPress(.space, phases: [.down]) { _ in
                guard
                    model.isLocalSourceSelected,
                    let selectedTorrent,
                    platformIntegration.canPreviewDownloadedItem(for: selectedTorrent)
                else {
                    return .ignored
                }
                platformIntegration.previewDownloadedItem(for: selectedTorrent)
                return .handled
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                if accessibilityReduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(.snappy(duration: 0.24)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: torrents) { _, torrents in
                groupedItems = TorrentNameSequenceGrouper.items(for: torrents)
            }
        }
        .overlay {
            if torrents.isEmpty, model.filteredTorrents.isEmpty {
                emptyState
            }
        }
    }

    private var visibleSelectionIDs: [String] {
        groupedItems.flatMap { item -> [String] in
            switch item {
            case let .torrent(torrent):
                return [torrent.hashString]
            case let .group(group):
                let isExpanded = !collapsedAutoGroupIDs.contains(group.id)
                return isExpanded ? [group.id] + group.torrents.map(\.hashString) : [group.id]
            }
        }
    }

    private var selectedTorrent: TorrentSummary? {
        guard let selection else { return nil }
        return torrents.first { $0.hashString == selection }
    }

    @ViewBuilder
    private func torrentListItem(_ item: TorrentListItem) -> some View {
        switch item {
        case let .torrent(torrent):
            torrentRow(torrent)
        case let .group(group):
            torrentGroupRows(group)
        }
    }

    @ViewBuilder
    private func torrentGroupRows(_ group: TorrentNameSequenceGroup) -> some View {
        let isExpanded = !collapsedAutoGroupIDs.contains(group.id)

        VStack(spacing: 0) {
        TorrentRowView(
            torrent: group.summary,
            isGroup: true,
            isSelected: selection == group.id,
            usesCompactLayout: usesCompactRows
            ) {
                Task { await toggleGroupTransfers(group) }
            }
            .id(group.id)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                isTorrentListFocused = true
                selection = group.id
            }
            .glassSelectOnSecondaryClick {
                isTorrentListFocused = true
                selection = group.id
            }
            .overlay(alignment: .leading) {
                autoGroupFolderButton(group, isExpanded: isExpanded)
                    .frame(width: 42, height: 50, alignment: .center)
                    .padding(.leading, 26)
            }

            if isExpanded {
                ForEach(Array(group.torrents.enumerated()), id: \.offset) { index, torrent in
                    torrentRow(
                        torrent,
                        isNested: true,
                        iconAnimationID: index < 3 ? groupFolderAnimationID(group.id, index: index) : nil
                    )
                    .transition(.identity)
                }
            }
        }
    }

    private func torrentRow(
        _ torrent: TorrentSummary,
        isNested: Bool = false,
        iconAnimationID: String? = nil
    ) -> some View {
        TorrentRowView(
            torrent: torrent,
            isNested: isNested,
            isSelected: selection == torrent.hashString,
            usesCompactLayout: usesCompactRows,
            pendingOldName: pendingRenameOldNames[torrent.hashString],
            iconAnimationNamespace: iconAnimationID == nil ? nil : groupFolderNamespace,
            iconAnimationID: iconAnimationID
        ) {
            Task { await toggleTransfer(torrent) }
        }
        .id(torrent.hashString)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .padding(.leading, isNested ? 58 : 16)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            isTorrentListFocused = true
            selection = torrent.hashString
        }
        .glassSelectOnSecondaryClick {
            isTorrentListFocused = true
            selection = torrent.hashString
        }
        .contextMenu {
            torrentContextMenu(for: torrent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", role: .destructive) {
                remove(torrent, false)
            }
            Button(torrent.canStopTransfer ? "Pause" : "Resume") {
                Task { await toggleTransfer(torrent) }
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = visibleSelectionIDs
        guard !ids.isEmpty else {
            selection = nil
            return
        }

        let currentIndex = selection.flatMap { ids.firstIndex(of: $0) }
        switch direction {
        case .up:
            selection = ids[max((currentIndex ?? ids.count) - 1, 0)]
        case .down:
            selection = ids[min((currentIndex ?? -1) + 1, ids.count - 1)]
        default:
            return
        }
    }

    private func autoGroupFolderButton(
        _ group: TorrentNameSequenceGroup,
        isExpanded: Bool
    ) -> some View {
        Button {
            isTorrentListFocused = true
            selection = group.id
            toggleAutoGroup(group.id)
        } label: {
            GroupFolderFanIcon(
                groupID: group.id,
                count: min(group.torrents.count, 3),
                namespace: groupFolderNamespace,
                isExpanded: isExpanded
            )
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide Torrents" : "Show Torrents")
        .accessibilityLabel("\(group.displayName) group")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .focusable(false)
        .focusEffectDisabled()
    }

    private func toggleAutoGroup(_ id: String) {
        withAnimation(accessibilityReduceMotion ? nil : .smooth(duration: 0.32)) {
            if collapsedAutoGroupIDs.contains(id) {
                collapsedAutoGroupIDs.remove(id)
            } else {
                collapsedAutoGroupIDs.insert(id)
            }
        }
    }

    private func groupFolderAnimationID(_ groupID: String, index: Int) -> String {
        "\(groupID):folder:\(index)"
    }

    private func toggleTransfer(_ torrent: TorrentSummary) async {
        if torrent.canStopTransfer {
            await model.stop(torrent)
        } else {
            await model.start(torrent)
        }
    }

    private func toggleGroupTransfers(_ group: TorrentNameSequenceGroup) async {
        let liveTorrents = group.torrents.filter { $0.id >= 0 }
        guard !liveTorrents.isEmpty else { return }

        if liveTorrents.contains(where: \.canStopTransfer) {
            for torrent in liveTorrents where torrent.canStopTransfer {
                await model.stop(torrent)
            }
        } else {
            for torrent in liveTorrents {
                await model.start(torrent)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = model.refreshErrorMessage, !model.isLocalSourceSelected {
            ContentUnavailableView(
                "Couldn’t Reach Server",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
        } else {
            ContentUnavailableView(
                "No Torrents",
                systemImage: "tray",
                description: Text(model.isLocalSourceSelected ? "Add a torrent to this Mac." : "This filter has no matching torrents.")
            )
        }
    }

    @ViewBuilder
    private func torrentContextMenu(for torrent: TorrentSummary) -> some View {
        Button(torrent.canStopTransfer ? "Pause" : "Resume") {
            Task {
                if torrent.canStopTransfer {
                    await model.stop(torrent)
                } else {
                    await model.start(torrent)
                }
            }
        }
        Button("Verify") {
            Task { await model.verify(torrent) }
        }
        Button("Announce") {
            Task { await model.reannounce(torrent) }
        }
        Menu("Priority") {
            Button("High") {
                Task { await model.setTorrentPriority(torrent, priority: 1) }
            }
            Button("Normal") {
                Task { await model.setTorrentPriority(torrent, priority: 0) }
            }
            Button("Low") {
                Task { await model.setTorrentPriority(torrent, priority: -1) }
            }
        }
        Menu("Queue") {
            Button("Move to Top") {
                Task { await model.moveInQueue([torrent], direction: .top) }
            }
            Button("Move Up") {
                Task { await model.moveInQueue([torrent], direction: .up) }
            }
            Button("Move Down") {
                Task { await model.moveInQueue([torrent], direction: .down) }
            }
            Button("Move to Bottom") {
                Task { await model.moveInQueue([torrent], direction: .bottom) }
            }
        }
        Button("Rename...") {
            rename(torrent)
        }

        if model.isLocalSourceSelected {
            Divider()

            Button("Quick Look") {
                platformIntegration.previewDownloadedItem(for: torrent)
            }
            .disabled(!platformIntegration.canPreviewDownloadedItem(for: torrent))

            Button("Show in Finder") {
                platformIntegration.revealDownloadedItem(for: torrent)
            }
            .disabled(!platformIntegration.canRevealDownloadedItem(for: torrent))
        }

        Divider()
        Button("Remove") {
            remove(torrent, false)
        }
        Button("Remove and Delete Data", role: .destructive) {
            remove(torrent, true)
        }
    }
}

private struct GroupFolderFanIcon: View {
    let groupID: String
    let count: Int
    let namespace: Namespace.ID
    let isExpanded: Bool

    var body: some View {
        ZStack {
            TorrentFileIcon(fileName: "", isFolder: true, size: 29)
                .zIndex(-1)

            if !isExpanded {
                ForEach(0..<count, id: \.self) { index in
                    folder(at: index)
                        .matchedGeometryEffect(
                            id: "\(groupID):folder:\(index)",
                            in: namespace,
                            isSource: true
                        )
                }
            }
        }
        .frame(width: 42, height: 50)
        .contentShape(Rectangle())
    }

    private func folder(at index: Int) -> some View {
        TorrentFileIcon(fileName: "", isFolder: true, size: 29)
            .rotationEffect(rotation(for: index), anchor: .bottom)
            .offset(offset(for: index))
            .zIndex(Double(index))
    }

    private func rotation(for index: Int) -> Angle {
        guard count > 1 else { return .zero }
        let progress = Double(index) / Double(count - 1)
        return .degrees(-10 + (20 * progress))
    }

    private func offset(for index: Int) -> CGSize {
        guard count > 1 else { return .zero }
        let progress = CGFloat(index) / CGFloat(count - 1)
        let horizontal = -6 + (12 * progress)
        let vertical = abs(progress - 0.5) * 3
        return CGSize(width: horizontal, height: vertical)
    }
}
