import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

private struct TorrentListColumnWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
    @AppStorage("GlassList.paddingIsPermanent") private var paddingIsPermanent = false
    @AppStorage("GlassList.sidePadding") private var sidePadding = 18.0
    @State private var columnWidth: CGFloat = 0
    @State private var elevationController = TorrentListElevationController()
    @State private var swipingRowID: String?
    @AppStorage("GlassList.selectionEaseIn") private var selectionEaseIn = 0.25
    @AppStorage("GlassList.selectionEaseOut") private var selectionEaseOut = 0.30
    @AppStorage("GlassList.selectedHDRWhite") private var selectedHDRWhite = 0.0
    @AppStorage("GlassList.selectedHDRSoftness") private var selectedHDRSoftness = 0.0
    @AppStorage("GlassList.selectedHDRSpread") private var selectedHDRSpread = 0.0
    @AppStorage("GlassList.columnLightBrightness") private var columnLightBrightness = 0.955
    @AppStorage("GlassList.columnDarkBrightness") private var columnDarkBrightness = 0.105
    @AppStorage("GlassList.shadowTopStrength") private var shadowTopStrength = 0.12
    @AppStorage("GlassList.shadowTopSoftness") private var shadowTopSoftness = 8.0
    @AppStorage("GlassList.shadowTopLift") private var shadowTopLift = 4.0
    @AppStorage("GlassList.shadowBottomStrength") private var shadowBottomStrength = 0.22
    @AppStorage("GlassList.shadowBottomSoftness") private var shadowBottomSoftness = 12.0
    @AppStorage("GlassList.shadowBottomLift") private var shadowBottomLift = 7.0

    private var shadowSettings: TorrentShadowSettings {
        TorrentShadowSettings(topStrength: shadowTopStrength, topSoftness: shadowTopSoftness, topLift: shadowTopLift, bottomStrength: shadowBottomStrength, bottomSoftness: shadowBottomSoftness, bottomLift: shadowBottomLift, easeIn: selectionEaseIn, easeOut: selectionEaseOut, hdrWhite: selectedHDRWhite, hdrSoftness: selectedHDRSoftness, hdrSpread: selectedHDRSpread, isDark: colorScheme == .dark, increasedContrast: colorContrast == .increased)
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorContrast

    private var listSurface: Color {
        Color(white: colorScheme == .dark ? columnDarkBrightness : columnLightBrightness)
    }

    private var density: TorrentRowDensity {
        columnWidth > 0 ? TorrentRowDensity(width: max(0, columnWidth - 2 * sidePadding)) : .regular
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $selection) {
                ForEach(TorrentListSection.sections(for: presentation.rows)) { section in
                    Section {
                        ForEach(section.rows) { row in
                            liveRow(for: row)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listItemTint(.monochrome)
                                .tag(row.id)
                                .accessibilityElement(children: .contain)
                        }
                    } header: {
                        Text(section.title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(.vertical, 8)
                            .padding(.leading, sidePadding + 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(listSurface)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: TorrentListColumnWidthKey.self,
                    value: proxy.size.width
                )
            })
            .environment(\.defaultMinListRowHeight, 60)
            .focusEffectDisabled()
            .tint(Color(nsColor: .secondaryLabelColor))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .glassSwipeActionsContainer()
            .onChange(of: revealSelectionToken) { _, _ in
                revealAndScrollToTorrent(selection, using: scrollProxy)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .background(listSurface)
        }
        .task(id: columnWidth) {
            guard !paddingIsPermanent, columnWidth > 0 else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            // Preserve the gap of the former centered 480-point list exactly once.
            sidePadding = max(sidePadding, (columnWidth - 480) / 2)
            paddingIsPermanent = true
        }
        .onAppear {
            if UserDefaults.standard.object(forKey: "GlassList.sidePadding") == nil {
                UserDefaults.standard.set(sidePadding, forKey: "GlassList.sidePadding")
            }
            elevationController.dragSelectionChanged = { id in
                guard presentation.rows.contains(where: { $0.id == id }) else { return }
                if selection != id { selection = id }
            }
            synchronizePresentation(animated: false)
        }
        .onDisappear { elevationController.detach() }
        .onChange(of: shadowSettings, initial: true) { _, settings in
            elevationController.configure(settings)
        }
        .onChange(of: selection, initial: true) { _, value in
            elevationController.setSelection(value)
        }
        .onPreferenceChange(TorrentListColumnWidthKey.self) { width in
            columnWidth = width
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

    private func liveRow(for row: TorrentListRowPresentation) -> TorrentListLiveRow {
        TorrentListLiveRow(
            row: row,
            isSelected: selection == row.id,
            sidePadding: sidePadding,
            elevationController: elevationController,
            density: density,
            model: model,
            platformIntegration: platformIntegration,
            pendingOldName: row.torrentRecord.flatMap { pendingRenameOldNames[$0.id] },
            select: { selection = row.id },
            swipePresentationChanged: { visible in
                let update = { swipingRowID = visible ? row.id : (swipingRowID == row.id ? nil : swipingRowID) }
                if accessibilityReduceMotion { update() } else { withAnimation(.easeInOut(duration: 0.20), update) }
            },
            toggleGroupExpansion: { toggleAutoGroup(row) },
            rename: rename,
            remove: remove,
            toggleTransfers: { Task { await toggleTransfers(for: row) } }
        )
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

    private func isUnavailable(_ record: TorrentRecord) -> Bool {
        record.summary.hasStorageError || TorrentThumbnailService.shared.isShareUnavailable(
            sourceID: record.sourceID, directory: record.summary.downloadDir,
            isLocal: record.sourceID == model.localSourceID
        )
    }

    private func toggleGroupTransfers(_ records: [TorrentRecord]) async {
        let liveTorrents = records.filter { $0.summary.id >= 0 }
        let unfinished = liveTorrents.filter { $0.summary.isUnfinished && !isUnavailable($0) }
        let transfers = unfinished.isEmpty ? liveTorrents : unfinished
        guard !transfers.isEmpty else { return }

        if transfers.contains(where: { $0.summary.canStopTransfer }) {
            for record in transfers where record.summary.canStopTransfer {
                await model.stop(record.summary, sourceID: record.sourceID)
            }
        } else {
            for record in transfers {
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
    let isSelected: Bool
    let sidePadding: CGFloat
    let elevationController: TorrentListElevationController
    let density: TorrentRowDensity
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let pendingOldName: String?
    let select: () -> Void
    let swipePresentationChanged: (Bool) -> Void
    let toggleGroupExpansion: () -> Void
    let rename: (TorrentSummary, UUID) -> Void
    let remove: (TorrentSummary, UUID, Bool) -> Void
    let toggleTransfers: () -> Void

    var body: some View {
        TorrentSwipeRow(selected: isSelected, remove: removeRow, presentationChanged: swipePresentationChanged) {
        TorrentRowView(
            torrent: summary,
            showsExtensions: showExtensions,
            density: density,
            groupIsExpanded: row.groupIsExpanded,
            groupCount: row.groupCount,
            toggleGroupExpansion: toggleGroupExpansion,
            pendingOldName: pendingOldName,
            shareUnavailable: shareUnavailable,
            thumbnailInput: row.torrentRecord.flatMap { TorrentThumbnailInput.movie($0.summary, sourceID: $0.sourceID, isLocal: $0.sourceID == model.localSourceID) },
            toggleTransfer: toggleTransfers
        )
        .equatable()
        .frame(minHeight: 60)
        .background {
            // The card extends 14 points beyond the content on each side, and
            // follows the actual foreground view when native swipe actions move it.
            TorrentListElevationAnchor(controller: elevationController, rowID: row.id, selected: isSelected, separatorLeadingInset: density.showsIcon ? 62 : 14)
                .padding(.horizontal, -14)
                .padding(.vertical, 3)
        }
        .glassContextMenu(select: select) { contextMenuContent }
        .padding(.horizontal, sidePadding + 16)
        }
    }


    @ViewBuilder
    var contextMenuContent: some View {
        if let record = row.torrentRecord {
            torrentContextMenu(for: record.summary)
            if let input = TorrentThumbnailInput.movie(record.summary, sourceID: record.sourceID, isLocal: record.sourceID == model.localSourceID) {
                Button("Refresh Preview") { Task { await TorrentThumbnailService.shared.refresh(input) } }
            }
        } else {
            Button("Delete Torrent") { removeRow(deleteData: false) }
            Button("Delete Torrent + Data", role: .destructive) { removeRow(deleteData: true) }
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

    private var shareUnavailable: Bool {
        func isUnavailable(_ record: TorrentRecord) -> Bool {
            record.summary.hasStorageError || TorrentThumbnailService.shared.isShareUnavailable(
                sourceID: record.sourceID, directory: record.summary.downloadDir,
                isLocal: record.sourceID == model.localSourceID
            )
        }
        switch row.kind {
        case let .torrent(record, _):
            return isUnavailable(record)
        case let .group(members, _, _):
            if members.contains(where: { $0.summary.isUnfinished && !isUnavailable($0) }) {
                return false
            }
            return members.contains(where: isUnavailable)
        }
    }

    @ViewBuilder
    private func torrentContextMenu(for torrent: TorrentSummary) -> some View {
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
        Text("Date added: \(formatTimestamp(torrent.addedDate))")
        Divider()
        Button("Delete Torrent") {
            remove(torrent, row.sourceID, false)
        }
        Button("Delete Torrent + Data", role: .destructive) {
            remove(torrent, row.sourceID, true)
        }
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
            fileCount: fileCount,
            addedDate: addedDate,
            error: error,
            errorString: errorString,
            doneDate: doneDate
        )
    }
}
