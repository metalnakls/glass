import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

struct TorrentListView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let records: [TorrentRecord]
    let structureRevision: Int
    let pendingRenameNames: [String: String]
    let pendingRenameOldNames: [String: String]
    @Binding var selection: String?
    let presentation: TorrentListPresentationModel
    let revealSelectionToken: UUID
    let rename: (TorrentSummary, UUID) -> Void
    let remove: (TorrentSummary, UUID, Bool) -> Void
    let removeSelected: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $selection) {
                ForEach(presentation.rows) { row in
                    TorrentListLiveRow(
                        row: row,
                        model: model,
                        platformIntegration: platformIntegration,
                        pendingOldName: row.torrentRecord.flatMap { pendingRenameOldNames[$0.id] },
                        select: { selection = row.id },
                        toggleGroupExpansion: { toggleAutoGroup(row) },
                        rename: rename,
                        remove: remove,
                        toggleTransfers: { Task { await toggleTransfers(for: row) } }
                    )
                    .background(TorrentListSelectionStyle().frame(width: 0, height: 0))
                    .listRowBackground(selectionBackground(for: row.id))
                    .listRowSeparator(.hidden)
                    .listItemTint(.monochrome)
                    .tag(row.id)
                    .accessibilityElement(children: .contain)
                }
            }
            .listStyle(.inset)
            .tint(Color(nsColor: .secondaryLabelColor))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .glassSwipeActionsContainer()
            .onChange(of: revealSelectionToken) { _, _ in
                revealAndScrollToTorrent(selection, using: scrollProxy)
            }
        }
        .onAppear {
            synchronizePresentation(animated: false)
        }
        .onChange(of: structureInput) { oldInput, newInput in
            let hasRowIdentityChanges = oldInput.recordIDs != newInput.recordIDs
                || oldInput.pendingRenameNames != newInput.pendingRenameNames
            synchronizePresentation(
                animated: hasRowIdentityChanges
            )
        }
        .onKeyPress(.delete, phases: [.down]) { keyPress in
            guard selection != nil, presentation.rows.contains(where: { $0.id == selection }) else { return .ignored }
            removeSelected(keyPress.modifiers.contains(.command))
            return .handled
        }
        .onKeyPress(.space, phases: [.down]) { _ in
            guard
                records.first(where: { $0.id == selection })?.sourceID == model.localSourceID,
                let selectedTorrent,
                platformIntegration.canPreviewDownloadedItem(for: selectedTorrent)
            else {
                return .ignored
            }
            platformIntegration.previewDownloadedItem(for: selectedTorrent)
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.sources.filter { $0.refreshErrorMessage != nil }) { source in
                    Label("\(model.sourceName(for: source.id)): \(source.records.isEmpty ? "Couldn’t connect" : "Showing last available torrents")", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(source.refreshErrorMessage ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
        }
        .overlay {
            if records.isEmpty {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func selectionBackground(for id: String) -> some View {
        if selection == id {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        }
    }

    private var structureInput: TorrentListStructureInput {
        TorrentListStructureInput(
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
            records: records,
            pendingRenameNames: pendingRenameNames,
            reduceMotion: accessibilityReduceMotion
        )
        reconcileSelection(with: updatedRows)
    }

    private func synchronizePresentation(animated: Bool) {
        let updatedRows = presentation.synchronize(
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

    private func revealAndScrollToTorrent(_ selectedID: String?, using scrollProxy: ScrollViewProxy) {
        guard let selectedID else { return }
        let rows = presentation.revealTorrent(
            selectedID,
            records: records,
            pendingRenameNames: pendingRenameNames,
            reduceMotion: accessibilityReduceMotion
        )
        reconcileSelection(with: rows)
        guard selection == selectedID else { return }

        Task { @MainActor in
            await Task.yield()
            if accessibilityReduceMotion {
                scrollProxy.scrollTo(selectedID, anchor: .center)
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    scrollProxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    private func toggleTransfers(for row: TorrentListRowPresentation) async {
        switch row.kind {
        case let .torrent(record, _):
            let torrent = record.summary
            if torrent.canStopTransfer {
                await model.stop(torrent, sourceID: record.sourceID)
            } else {
                await model.start(torrent, sourceID: record.sourceID)
            }
        case let .group(records, _, _):
            await toggleGroupTransfers(records)
        }
    }

    private func toggleGroupTransfers(_ records: [TorrentRecord]) async {
        let liveTorrents = records.filter { $0.summary.id >= 0 }
        guard !liveTorrents.isEmpty else { return }

        if liveTorrents.contains(where: { $0.summary.canStopTransfer }) {
            for record in liveTorrents where record.summary.canStopTransfer {
                await model.stop(record.summary, sourceID: record.sourceID)
            }
        } else {
            for record in liveTorrents {
                await model.start(record.summary, sourceID: record.sourceID)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if records.isEmpty, model.sources.allSatisfy({ !$0.isLoading }) {
            ContentUnavailableView(
                "No Torrents", systemImage: "tray",
                description: Text(model.selectedTorrentGroup == .downloading
                    ? "There are no downloading torrents." : "Add a torrent to this Mac or a server.")
            )
        }

    }
}

private struct TorrentListLiveRow: View {
    @AppStorage("GlassList.showExtensions") private var showExtensions = false
    let row: TorrentListRowPresentation
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let pendingOldName: String?
    let select: () -> Void
    let toggleGroupExpansion: () -> Void
    let rename: (TorrentSummary, UUID) -> Void
    let remove: (TorrentSummary, UUID, Bool) -> Void
    let toggleTransfers: () -> Void

    var body: some View {
        TorrentRowView(
            torrent: summary,
            showsExtensions: showExtensions,
            groupIsExpanded: row.groupIsExpanded,
            toggleGroupExpansion: toggleGroupExpansion,
            pendingOldName: pendingOldName,
            thumbnailInput: row.torrentRecord.flatMap { TorrentThumbnailInput.movie($0.summary, sourceID: $0.sourceID, isLocal: $0.sourceID == model.localSourceID) },
            toggleTransfer: toggleTransfers
        )
        .equatable()
        .glassSelectOnSecondaryClick(select)
        .contextMenu {
            if let record = row.torrentRecord {
                torrentContextMenu(for: record.summary)
                if let input = TorrentThumbnailInput.movie(record.summary, sourceID: record.sourceID, isLocal: record.sourceID == model.localSourceID) {
                    Button("Refresh Preview") { Task { await TorrentThumbnailService.shared.refresh(input) } }
                }
            } else {
                Button(summary.canStopTransfer ? "Pause" : "Resume", action: toggleTransfers)
                Button("Verify") {
                    if case let .group(records, _, _) = row.kind {
                        Task { for record in records { await model.verify(record.summary, sourceID: record.sourceID) } }
                    }
                }
                Divider()
                Button("Delete Torrent") { removeRow(deleteData: false) }
                Button("Delete Torrent + Data", role: .destructive) { removeRow(deleteData: true) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete Torrent + Data", systemImage: "trash.fill", role: .destructive) {
                removeRow(deleteData: true)
            }
            .labelStyle(.iconOnly)
            Button("Delete Torrent", systemImage: "trash") {
                removeRow(deleteData: false)
            }
            .labelStyle(.iconOnly)
            .tint(.orange)
        }
    }

    private func removeRow(deleteData: Bool) {
        switch row.kind {
        case let .torrent(record, _): remove(record.summary, record.sourceID, deleteData)
        case let .group(records, _, _):
            for record in records { remove(record.summary, record.sourceID, deleteData) }
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
                    await model.stop(torrent, sourceID: row.sourceID)
                } else {
                    await model.start(torrent, sourceID: row.sourceID)
                }
            }
        }
        Button("Verify") {
            Task { await model.verify(torrent, sourceID: row.sourceID) }
        }
        Button("Announce") {
            Task { await model.reannounce(torrent, sourceID: row.sourceID) }
        }
        Menu("Priority") {
            Toggle("High", isOn: priorityBinding(1, for: torrent))
            Toggle("Normal", isOn: priorityBinding(0, for: torrent))
            Toggle("Low", isOn: priorityBinding(-1, for: torrent))
        }
        Menu("Queue") {
            Button("Move to Top") {
                Task { await model.moveInQueue([torrent], direction: .top, sourceID: row.sourceID) }
            }
            Button("Move Up") {
                Task { await model.moveInQueue([torrent], direction: .up, sourceID: row.sourceID) }
            }
            Button("Move Down") {
                Task { await model.moveInQueue([torrent], direction: .down, sourceID: row.sourceID) }
            }
            Button("Move to Bottom") {
                Task { await model.moveInQueue([torrent], direction: .bottom, sourceID: row.sourceID) }
            }
        }
        Button("Rename…") {
            rename(summary, row.sourceID)
        }

        if row.sourceID == model.localSourceID {
            Divider()

            Button("Move Data…", systemImage: "folder") {
                Task {
                    do {
                        guard let directory = try await platformIntegration.chooseLocalDownloadDirectory(
                            startingAt: torrent.downloadDir
                        ) else { return }
                        _ = await model.moveLocalData(torrent, to: directory, sourceID: row.sourceID)
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
            remove(torrent, row.sourceID, false)
        }
        Button("Delete Torrent + Data", role: .destructive) {
            remove(torrent, row.sourceID, true)
        }
    }

    private func priorityBinding(_ priority: Int, for torrent: TorrentSummary) -> Binding<Bool> {
        Binding(
            get: { torrent.bandwidthPriority == priority },
            set: { isSelected in
                guard isSelected else { return }
                Task { await model.setTorrentPriority(torrent, priority: priority, sourceID: row.sourceID) }
            }
        )
    }
}

extension TorrentSummary {
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
