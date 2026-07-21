import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentListView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let sourceID: UUID
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
    @State private var displayedGroupingIdentity: [TorrentGroupingIdentity]
    @State private var rows: [TorrentListRowPresentation]
    @State private var showsTorrentIcons = true

    init(
        model: RemoteAppModel,
        platformIntegration: any GlassPlatformIntegrating,
        sourceID: UUID,
        torrents: [TorrentSummary],
        pendingRenameOldNames: [String: String],
        selection: Binding<String?>,
        rename: @escaping (TorrentSummary) -> Void,
        remove: @escaping (TorrentSummary, Bool) -> Void,
        removeSelected: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.platformIntegration = platformIntegration
        self.sourceID = sourceID
        self.torrents = torrents
        self.pendingRenameOldNames = pendingRenameOldNames
        _selection = selection
        self.rename = rename
        self.remove = remove
        self.removeSelected = removeSelected
        let topology = TorrentNameSequenceGrouper.items(for: torrents)
        _groupingTopology = State(initialValue: topology)
        _displayedTorrents = State(initialValue: torrents)
        _displayedGroupingIdentity = State(initialValue: Self.groupingIdentity(for: torrents))
        _rows = State(initialValue: TorrentListRowPresentation.rows(
            topology: topology,
            torrents: torrents,
            collapsedGroupIDs: [],
            pendingRenameOldNames: pendingRenameOldNames
        ))
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                TorrentRowView(
                    torrent: row.torrent,
                    showsIcon: showsTorrentIcons,
                    groupIsExpanded: row.groupIsExpanded,
                    toggleGroupExpansion: { toggleAutoGroup(row) },
                    pendingOldName: row.pendingOldName
                ) {
                    Task { await toggleTransfers(for: row) }
                }
                .equatable()
                .tag(row.id)
                .accessibilityElement(children: .contain)
                .contextMenu {
                    if row.isTorrent {
                        torrentContextMenu(for: row.torrent)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if row.isTorrent {
                        Button("Delete Torrent + Data", role: .destructive) {
                            remove(row.torrent, true)
                        }
                        Button("Delete Torrent") {
                            remove(row.torrent, false)
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .listStyle(.inset)
        .glassSwipeActionsContainer()
        .onChange(of: sourceID) { _, _ in
            resetPresentation()
        }
        .onChange(of: torrents) { _, updatedTorrents in
            applySnapshot(updatedTorrents)
        }
        .onChange(of: pendingRenameOldNames) { _, _ in
            rebuildRows(animation: accessibilityReduceMotion ? nil : .easeOut(duration: 0.18))
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

    private var selectedTorrent: TorrentSummary? {
        guard let selection else { return nil }
        return displayedTorrents.first { $0.hashString == selection }
    }

    private func toggleAutoGroup(_ row: TorrentListRowPresentation) {
        guard case let .group(memberHashes, _) = row.kind else { return }
        let animation: Animation? = accessibilityReduceMotion ? nil : .easeInOut(duration: 0.22)
        withAnimation(animation) {
            if collapsedAutoGroupIDs.contains(row.id) {
                collapsedAutoGroupIDs.remove(row.id)
            } else {
                if let selection, memberHashes.contains(selection) {
                    self.selection = row.id
                }
                collapsedAutoGroupIDs.insert(row.id)
            }
            rows = makeRows()
        }
    }

    private func applySnapshot(_ updatedTorrents: [TorrentSummary]) {
        let updatedIdentity = Self.groupingIdentity(for: updatedTorrents)
        let hasStructuralChanges = updatedIdentity != displayedGroupingIdentity
        let updatedTopology = hasStructuralChanges
            ? TorrentNameSequenceGrouper.items(for: updatedTorrents)
            : groupingTopology

        let updates = {
            if hasStructuralChanges {
                groupingTopology = updatedTopology
                displayedGroupingIdentity = updatedIdentity
            }
            displayedTorrents = updatedTorrents
            reconcileSelection(with: updatedTorrents, topology: updatedTopology)
            rows = makeRows(topology: updatedTopology, torrents: updatedTorrents)
        }

        if hasStructuralChanges, !accessibilityReduceMotion {
            withAnimation(.easeInOut(duration: 0.22), updates)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, updates)
        }
    }

    private static func groupingIdentity(for torrents: [TorrentSummary]) -> [TorrentGroupingIdentity] {
        torrents.map { TorrentGroupingIdentity(hashString: $0.hashString, name: $0.name) }
    }

    private func resetPresentation() {
        let updatedTopology = TorrentNameSequenceGrouper.items(for: torrents)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            collapsedAutoGroupIDs.removeAll()
            groupingTopology = updatedTopology
            displayedTorrents = torrents
            displayedGroupingIdentity = Self.groupingIdentity(for: torrents)
            selection = nil
            rows = makeRows(topology: updatedTopology, torrents: torrents, collapsedGroupIDs: [])
        }
    }

    private func rebuildRows(animation: Animation?) {
        withAnimation(animation) {
            rows = makeRows()
        }
    }

    private func makeRows(
        topology: [TorrentListItem]? = nil,
        torrents: [TorrentSummary]? = nil,
        collapsedGroupIDs: Set<String>? = nil
    ) -> [TorrentListRowPresentation] {
        TorrentListRowPresentation.rows(
            topology: topology ?? groupingTopology,
            torrents: torrents ?? displayedTorrents,
            collapsedGroupIDs: collapsedGroupIDs ?? collapsedAutoGroupIDs,
            pendingRenameOldNames: pendingRenameOldNames
        )
    }

    private func reconcileSelection(with torrents: [TorrentSummary], topology: [TorrentListItem]) {
        guard let selection else { return }
        if selection.hasPrefix("auto-group:") {
            let validGroupIDs = Set(topology.compactMap { item -> String? in
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

    private func toggleTransfers(for row: TorrentListRowPresentation) async {
        switch row.kind {
        case .torrent:
            if row.torrent.canStopTransfer {
                await model.stop(row.torrent)
            } else {
                await model.start(row.torrent)
            }
        case let .group(memberHashes, _):
            let hashes = Set(memberHashes)
            await toggleGroupTransfers(displayedTorrents.filter { hashes.contains($0.hashString) })
        }
    }

    private func toggleGroupTransfers(_ torrents: [TorrentSummary]) async {
        let liveTorrents = torrents.filter { $0.id >= 0 }
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

private struct TorrentListRowPresentation: Identifiable, Equatable {
    enum Kind: Equatable {
        case torrent
        case group(memberHashes: [String], isExpanded: Bool)
    }

    let id: String
    let torrent: TorrentSummary
    let kind: Kind
    let pendingOldName: String?

    var isTorrent: Bool {
        kind == .torrent
    }

    var groupIsExpanded: Bool? {
        guard case let .group(_, isExpanded) = kind else { return nil }
        return isExpanded
    }

    static func rows(
        topology: [TorrentListItem],
        torrents: [TorrentSummary],
        collapsedGroupIDs: Set<String>,
        pendingRenameOldNames: [String: String]
    ) -> [TorrentListRowPresentation] {
        let items = TorrentNameSequenceGrouper.updating(topology, with: torrents)
        var rows: [TorrentListRowPresentation] = []
        rows.reserveCapacity(torrents.count + items.count)

        for item in items {
            switch item {
            case let .torrent(torrent):
                rows.append(torrentRow(torrent, pendingRenameOldNames: pendingRenameOldNames))
            case let .group(group):
                let isExpanded = !collapsedGroupIDs.contains(group.id)
                rows.append(TorrentListRowPresentation(
                    id: group.id,
                    torrent: group.summary,
                    kind: .group(
                        memberHashes: group.torrents.map(\.hashString),
                        isExpanded: isExpanded
                    ),
                    pendingOldName: nil
                ))
                if isExpanded {
                    rows.append(contentsOf: group.torrents.map {
                        torrentRow($0, pendingRenameOldNames: pendingRenameOldNames)
                    })
                }
            }
        }
        return rows
    }

    private static func torrentRow(
        _ torrent: TorrentSummary,
        pendingRenameOldNames: [String: String]
    ) -> TorrentListRowPresentation {
        TorrentListRowPresentation(
            id: torrent.hashString,
            torrent: torrent,
            kind: .torrent,
            pendingOldName: pendingRenameOldNames[torrent.hashString]
        )
    }
}
