import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

struct TorrentListView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let sourceID: UUID
    let records: [TorrentRecord]
    let structureRevision: Int
    let pendingRenameNames: [String: String]
    let pendingRenameOldNames: [String: String]
    @Binding var selection: String?
    let rename: (TorrentSummary) -> Void
    let remove: (TorrentSummary, Bool) -> Void
    let removeSelected: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var presentation = TorrentListPresentationModel()
    @State private var rowDensity: TorrentRowDensity = .regular

    var body: some View {
        List(selection: $selection) {
            ForEach(presentation.rows) { row in
                TorrentListLiveRow(
                    row: row,
                    model: model,
                    platformIntegration: platformIntegration,
                    density: rowDensity,
                    pendingOldName: row.torrentRecord.flatMap { pendingRenameOldNames[$0.id] },
                    select: { selection = row.id },
                    toggleGroupExpansion: { toggleAutoGroup(row) },
                    rename: rename,
                    remove: remove,
                    toggleTransfers: { Task { await toggleTransfers(for: row) } }
                )
                .tag(row.id)
                .accessibilityElement(children: .contain)
            }
        }
        .listStyle(.inset)
        .glassSwipeActionsContainer()
        .onAppear {
            synchronizePresentation(sourceChanged: false, animated: false)
        }
        .onChange(of: structureInput) { oldInput, newInput in
            let sourceChanged = oldInput.sourceID != newInput.sourceID
            let hasRowIdentityChanges = oldInput.recordIDs != newInput.recordIDs
                || oldInput.pendingRenameNames != newInput.pendingRenameNames
            synchronizePresentation(
                sourceChanged: sourceChanged,
                animated: !sourceChanged && hasRowIdentityChanges
            )
        }
        .onGeometryChange(for: TorrentRowDensity.self, of: { geometry in
            TorrentRowDensity(width: geometry.size.width)
        }) { density in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rowDensity = density
            }
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
            if records.isEmpty {
                emptyState
            }
        }
    }

    private var structureInput: TorrentListStructureInput {
        TorrentListStructureInput(
            sourceID: sourceID,
            revision: structureRevision,
            recordIDs: records.map(\.id),
            pendingRenameNames: pendingRenameNames
        )
    }

    private var selectedTorrent: TorrentSummary? {
        guard let selection else { return nil }
        return records.first { $0.id == selection }?.summary
    }

    private func toggleAutoGroup(_ row: TorrentListRowPresentation) {
        guard let memberIDs = row.groupMemberIDs else { return }
        if row.groupIsExpanded == true, let selection, memberIDs.contains(selection) {
            self.selection = row.id
        }
        let updatedRows = presentation.toggleGroup(
            row.id,
            sourceID: sourceID,
            records: records,
            pendingRenameNames: pendingRenameNames,
            reduceMotion: accessibilityReduceMotion
        )
        reconcileSelection(with: updatedRows)
    }

    private func synchronizePresentation(sourceChanged: Bool, animated: Bool) {
        if sourceChanged {
            selection = nil
        }
        let updatedRows = presentation.synchronize(
            sourceID: sourceID,
            records: records,
            pendingRenameNames: pendingRenameNames,
            animated: animated,
            reduceMotion: accessibilityReduceMotion
        )
        reconcileSelection(with: updatedRows)
    }

    private func reconcileSelection(with rows: [TorrentListRowPresentation]) {
        guard let selection else { return }
        if !rows.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func toggleTransfers(for row: TorrentListRowPresentation) async {
        switch row.kind {
        case let .torrent(record, _):
            let torrent = record.summary
            if torrent.canStopTransfer {
                await model.stop(torrent)
            } else {
                await model.start(torrent)
            }
        case let .group(records, _, _):
            await toggleGroupTransfers(records.map(\.summary))
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
}

private struct TorrentListLiveRow: View {
    let row: TorrentListRowPresentation
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let density: TorrentRowDensity
    let pendingOldName: String?
    let select: () -> Void
    let toggleGroupExpansion: () -> Void
    let rename: (TorrentSummary) -> Void
    let remove: (TorrentSummary, Bool) -> Void
    let toggleTransfers: () -> Void

    var body: some View {
        TorrentRowView(
            torrent: summary,
            density: density,
            groupIsExpanded: row.groupIsExpanded,
            groupCount: row.groupCount,
            toggleGroupExpansion: toggleGroupExpansion,
            pendingOldName: pendingOldName,
            toggleTransfer: toggleTransfers
        )
        .equatable()
        .glassSelectOnSecondaryClick(select)
        .contextMenu {
            if row.isTorrent {
                torrentContextMenu(for: summary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.isTorrent {
                Button("Delete Torrent + Data", role: .destructive) {
                    remove(summary, true)
                }
                Button("Delete Torrent") {
                    remove(summary, false)
                }
                .tint(.orange)
            }
        }
    }

    private var summary: TorrentSummary {
        switch row.kind {
        case let .torrent(record, displayName):
            return displayName.map { record.summary.renamedForPresentation(to: $0) } ?? record.summary
        case let .group(records, displayName, _):
            return TorrentNameSequenceGroup(
                id: row.id,
                displayName: displayName,
                torrents: records.map(\.summary)
            ).summary
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
            Toggle("High", isOn: priorityBinding(1, for: torrent))
            Toggle("Normal", isOn: priorityBinding(0, for: torrent))
            Toggle("Low", isOn: priorityBinding(-1, for: torrent))
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

            Button("Move Data…", systemImage: "folder") {
                Task {
                    do {
                        guard let directory = try await platformIntegration.chooseLocalDownloadDirectory(
                            startingAt: torrent.downloadDir
                        ) else { return }
                        _ = await model.moveLocalData(torrent, to: directory)
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }

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

    private func priorityBinding(_ priority: Int, for torrent: TorrentSummary) -> Binding<Bool> {
        Binding(
            get: { torrent.bandwidthPriority == priority },
            set: { isSelected in
                guard isSelected else { return }
                Task { await model.setTorrentPriority(torrent, priority: priority) }
            }
        )
    }
}

private struct TorrentListStructureInput: Equatable {
    let sourceID: UUID
    let revision: Int
    let recordIDs: [String]
    let pendingRenameNames: [String: String]
}

@MainActor
@Observable
private final class TorrentListPresentationModel {
    private(set) var rows: [TorrentListRowPresentation] = []

    @ObservationIgnored private var activeSourceID: UUID?
    @ObservationIgnored private var collapsedGroupIDs: Set<String> = []

    @discardableResult
    func synchronize(
        sourceID: UUID,
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        animated: Bool,
        reduceMotion: Bool
    ) -> [TorrentListRowPresentation] {
        let sourceChanged = activeSourceID != sourceID
        if sourceChanged {
            activeSourceID = sourceID
            collapsedGroupIDs = TorrentGroupExpansionStore.collapsedGroupIDs(for: sourceID)
        }

        let updatedRows = TorrentListRowPresentation.rows(
            records: records,
            pendingRenameNames: pendingRenameNames,
            collapsedGroupIDs: collapsedGroupIDs
        )
        setRows(updatedRows, animated: animated && !sourceChanged, reduceMotion: reduceMotion)
        return updatedRows
    }

    @discardableResult
    func toggleGroup(
        _ groupID: String,
        sourceID: UUID,
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        reduceMotion: Bool
    ) -> [TorrentListRowPresentation] {
        if activeSourceID != sourceID {
            activeSourceID = sourceID
            collapsedGroupIDs = TorrentGroupExpansionStore.collapsedGroupIDs(for: sourceID)
        }

        if collapsedGroupIDs.contains(groupID) {
            collapsedGroupIDs.remove(groupID)
        } else {
            collapsedGroupIDs.insert(groupID)
        }
        TorrentGroupExpansionStore.save(collapsedGroupIDs, for: sourceID)

        let updatedRows = TorrentListRowPresentation.rows(
            records: records,
            pendingRenameNames: pendingRenameNames,
            collapsedGroupIDs: collapsedGroupIDs
        )
        setRows(updatedRows, animated: true, reduceMotion: reduceMotion)
        return updatedRows
    }

    private func setRows(
        _ updatedRows: [TorrentListRowPresentation],
        animated: Bool,
        reduceMotion: Bool
    ) {
        if animated, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.22)) {
                rows = updatedRows
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rows = updatedRows
            }
        }
    }
}

@MainActor
private struct TorrentListRowPresentation: Identifiable {
    enum Kind {
        case torrent(record: TorrentRecord, displayName: String?)
        case group(records: [TorrentRecord], displayName: String, isExpanded: Bool)
    }

    let id: String
    let kind: Kind

    var isTorrent: Bool {
        if case .torrent = kind { return true }
        return false
    }

    var torrentRecord: TorrentRecord? {
        guard case let .torrent(record, _) = kind else { return nil }
        return record
    }

    var groupIsExpanded: Bool? {
        guard case let .group(_, _, isExpanded) = kind else { return nil }
        return isExpanded
    }

    var groupMemberIDs: [String]? {
        guard case let .group(records, _, _) = kind else { return nil }
        return records.map(\.id)
    }

    var groupCount: Int {
        guard let groupMemberIDs else { return 0 }
        return min(groupMemberIDs.count, 3)
    }

    static func rows(
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        collapsedGroupIDs: Set<String>
    ) -> [TorrentListRowPresentation] {
        let summaries = records.map { record in
            pendingRenameNames[record.id].map { record.summary.renamedForPresentation(to: $0) }
                ?? record.summary
        }
        let topology = TorrentNameSequenceGrouper.items(for: summaries)
        let recordsByHash = Dictionary(
            records.map { ($0.summary.hashString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [TorrentListRowPresentation] = []
        rows.reserveCapacity(records.count + topology.count)

        for item in topology {
            switch item {
            case let .torrent(torrent):
                guard let record = recordsByHash[torrent.hashString] else { continue }
                rows.append(TorrentListRowPresentation(
                    id: record.id,
                    kind: .torrent(record: record, displayName: pendingRenameNames[record.id])
                ))
            case let .group(group):
                let memberRecords = group.torrents.compactMap { recordsByHash[$0.hashString] }
                guard !memberRecords.isEmpty else { continue }
                let isExpanded = !collapsedGroupIDs.contains(group.id)
                rows.append(TorrentListRowPresentation(
                    id: group.id,
                    kind: .group(records: memberRecords, displayName: group.displayName, isExpanded: isExpanded)
                ))
                if isExpanded {
                    rows.append(contentsOf: memberRecords.map { record in
                        TorrentListRowPresentation(
                            id: record.id,
                            kind: .torrent(record: record, displayName: pendingRenameNames[record.id])
                        )
                    })
                }
            }
        }
        return rows
    }
}

private enum TorrentGroupExpansionStore {
    private static let defaultsKey = "TorrentList.collapsedGroupsBySource"

    static func collapsedGroupIDs(for sourceID: UUID) -> Set<String> {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let storedGroups = try? JSONDecoder().decode([String: [String]].self, from: data)
        else {
            return []
        }
        return Set(storedGroups[sourceID.uuidString] ?? [])
    }

    static func save(_ collapsedGroupIDs: Set<String>, for sourceID: UUID) {
        var storedGroups: [String: [String]] = [:]
        if
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        {
            storedGroups = decoded
        }

        if collapsedGroupIDs.isEmpty {
            storedGroups.removeValue(forKey: sourceID.uuidString)
        } else {
            storedGroups[sourceID.uuidString] = collapsedGroupIDs.sorted()
        }

        if let data = try? JSONEncoder().encode(storedGroups) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

private extension TorrentSummary {
    func renamedForPresentation(to name: String) -> TorrentSummary {
        TorrentSummary(
            id: id,
            hashString: hashString,
            name: name,
            status: status,
            percentDone: percentDone,
            metadataPercentComplete: metadataPercentComplete,
            rateDownload: rateDownload,
            rateUpload: rateUpload,
            sizeWhenDone: sizeWhenDone,
            leftUntilDone: leftUntilDone,
            eta: eta,
            uploadRatio: uploadRatio,
            peersConnected: peersConnected,
            downloadDir: downloadDir,
            bandwidthPriority: bandwidthPriority,
            queuePosition: queuePosition,
            fileCount: fileCount
        )
    }
}
