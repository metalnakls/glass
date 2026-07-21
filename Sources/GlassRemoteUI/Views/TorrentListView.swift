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
    @State private var groupingTopology: [TorrentListItem]
    @State private var displayedTorrents: [TorrentSummary]
    @State private var updateBuffer = TorrentListUpdateBuffer()
    @State private var showsTorrentIcons = true

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
        _selection = selection
        self.rename = rename
        self.remove = remove
        self.removeSelected = removeSelected
        _groupingTopology = State(initialValue: TorrentNameSequenceGrouper.items(for: torrents))
        _displayedTorrents = State(initialValue: torrents)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(groupedItems) { item in
                switch item {
                case let .torrent(torrent):
                    torrentRow(torrent)
                case let .group(group):
                    torrentGroupRows(group)
                }
            }
        }
        .listStyle(.inset)
        .glassSwipeActionsContainer()
        .onChange(of: torrents) { _, updatedTorrents in
            if updateBuffer.isScrollInProgress {
                updateBuffer.deferredTorrents = updatedTorrents
            } else {
                applySnapshot(updatedTorrents)
            }
        }
        .onScrollPhaseChange { _, phase in
            updateBuffer.isScrollInProgress = phase.isScrolling
            guard !phase.isScrolling, let deferredTorrents = updateBuffer.deferredTorrents else { return }
            updateBuffer.deferredTorrents = nil
            applySnapshot(deferredTorrents)
        }
        .onGeometryChange(for: Bool.self, of: { geometry in
            geometry.size.width >= 430
        }) { shouldShowIcons in
            showsTorrentIcons = shouldShowIcons
        }
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
        .overlay {
            if displayedTorrents.isEmpty {
                emptyState
            }
        }
    }

    private var groupedItems: [TorrentListItem] {
        TorrentNameSequenceGrouper.updating(groupingTopology, with: displayedTorrents)
    }

    private var displayedGroupingIdentity: [TorrentGroupingIdentity] {
        groupingIdentity(for: displayedTorrents)
    }

    private var selectedTorrent: TorrentSummary? {
        guard let selection else { return nil }
        return displayedTorrents.first { $0.hashString == selection }
    }

    @ViewBuilder
    private func torrentGroupRows(_ group: TorrentNameSequenceGroup) -> some View {
        let isExpanded = !collapsedAutoGroupIDs.contains(group.id)

        TorrentRowView(
            torrent: group.summary,
            showsIcon: showsTorrentIcons,
            groupIsExpanded: isExpanded,
            groupCount: min(group.torrents.count, 3),
            toggleGroupExpansion: { toggleAutoGroup(group.id) }
        ) {
            Task { await toggleGroupTransfers(group) }
        }
        .equatable()
        .tag(group.id)
        .accessibilityElement(children: .contain)

        if isExpanded {
            ForEach(group.torrents) { torrent in
                torrentRow(torrent)
            }
        }
    }

    private func torrentRow(_ torrent: TorrentSummary) -> some View {
        TorrentRowView(
            torrent: torrent,
            showsIcon: showsTorrentIcons,
            pendingOldName: pendingRenameOldNames[torrent.hashString]
        ) {
            Task { await toggleTransfer(torrent) }
        }
        .equatable()
        .tag(torrent.hashString)
        .contextMenu {
            torrentContextMenu(for: torrent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete Torrent + Data", role: .destructive) {
                remove(torrent, true)
            }
            Button("Delete Torrent") {
                remove(torrent, false)
            }
            .tint(.orange)
        }
    }

    private func toggleAutoGroup(_ id: String) {
        withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.22)) {
            if collapsedAutoGroupIDs.contains(id) {
                collapsedAutoGroupIDs.remove(id)
            } else {
                if let group = groupedItems.compactMap({ item -> TorrentNameSequenceGroup? in
                    guard case let .group(group) = item, group.id == id else { return nil }
                    return group
                }).first,
                   group.torrents.contains(where: { $0.hashString == selection }) {
                    selection = id
                }
                collapsedAutoGroupIDs.insert(id)
            }
        }
    }

    private func applySnapshot(_ updatedTorrents: [TorrentSummary]) {
        let updatedIdentity = groupingIdentity(for: updatedTorrents)
        let hasStructuralChanges = updatedIdentity != displayedGroupingIdentity

        let updates = {
            if hasStructuralChanges {
                groupingTopology = TorrentNameSequenceGrouper.items(for: updatedTorrents)
            }
            displayedTorrents = updatedTorrents
            reconcileSelection(with: updatedTorrents)
        }

        if hasStructuralChanges, !accessibilityReduceMotion {
            withAnimation(.easeInOut(duration: 0.22), updates)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, updates)
        }
    }

    private func groupingIdentity(for torrents: [TorrentSummary]) -> [TorrentGroupingIdentity] {
        torrents.map { TorrentGroupingIdentity(hashString: $0.hashString, name: $0.name) }
    }

    private func reconcileSelection(with torrents: [TorrentSummary]) {
        guard let selection else { return }
        if selection.hasPrefix("auto-group:") {
            let validGroupIDs = Set(groupingTopology.compactMap { item -> String? in
                guard case let .group(group) = item else { return nil }
                return group.id
            })
            if !validGroupIDs.contains(selection) {
                self.selection = nil
            }
        } else if !torrents.contains(where: { $0.hashString == selection }) {
            self.selection = nil
        }
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
        Button("Rename…") {
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
        Button("Delete Torrent") {
            remove(torrent, false)
        }
        Button("Delete Torrent + Data", role: .destructive) {
            remove(torrent, true)
        }
    }
}

private struct TorrentGroupingIdentity: Equatable {
    let hashString: String
    let name: String
}

@MainActor
private final class TorrentListUpdateBuffer {
    var isScrollInProgress = false
    var deferredTorrents: [TorrentSummary]?
}
