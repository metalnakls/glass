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
    @AppearanceStorage("GlassList.lowercaseTitles") private var lowercaseTitles = false
    @AppearanceStorage("GlassList.paddingIsPermanent") private var paddingIsPermanent = false
    @AppearanceStorage("GlassList.leftPadding") private var leftPadding = UserDefaults.standard.object(forKey: "GlassList.sidePadding") as? Double ?? 18
    @AppearanceStorage("GlassList.rightPadding") private var rightPadding = UserDefaults.standard.object(forKey: "GlassList.sidePadding") as? Double ?? 18
    @AppearanceStorage("GlassList.itemVerticalPadding") private var itemVerticalPadding = 0.0
    @AppStorage("GlassList.grid") private var grid = false
    @AppStorage("GlassList.density") private var densityLevel = 1
    @State private var columnWidth: CGFloat = 0
    @State private var stickyHeaders = TorrentStickyHeaders()
    @AppearanceStorage("GlassList.headerFadeStrengthLight") private var headerFadeStrengthLight = UserDefaults.standard.object(forKey: "GlassList.headerFadeStrength") as? Double ?? 0.75
    @AppearanceStorage("GlassList.headerFadeStrengthDark") private var headerFadeStrengthDark = UserDefaults.standard.object(forKey: "GlassList.headerFadeStrength") as? Double ?? 0.75
    @AppearanceStorage("GlassList.headerFadeReach") private var headerFadeReach = 48.0
    @AppearanceStorage("GlassList.headerBackgroundIn") private var headerBackgroundIn = 0.22
    @AppearanceStorage("GlassList.headerBackgroundOut") private var headerBackgroundOut = 0.28
    @AppearanceStorage("GlassList.headerTitleIn") private var headerTitleIn = 0.18
    @AppearanceStorage("GlassList.headerTitleOut") private var headerTitleOut = 0.22
    @AppearanceStorage("GlassList.headerPushLead") private var headerPushLead = 0.0
    @AppearanceStorage("GlassList.headerFadeColorLight") private var headerFadeColorLight = "FFFFFF"
    @AppearanceStorage("GlassList.headerFadeColorDark") private var headerFadeColorDark = "0C0C0C"
    private var headerAppearance: TorrentHeaderAppearance {
        TorrentHeaderAppearance(strength: colorScheme == .dark ? headerFadeStrengthDark : headerFadeStrengthLight, reach: headerFadeReach,
            backgroundIn: headerBackgroundIn, backgroundOut: headerBackgroundOut,
            titleIn: headerTitleIn, titleOut: headerTitleOut, pushLead: headerPushLead,
            color: HeaderFadeColor.decode(colorScheme == .dark ? headerFadeColorDark : headerFadeColorLight))
    }
    @State private var elevationController = TorrentListElevationController()
    @Namespace private var folderMotion
    @State private var swipingRowID: String?
    @AppearanceStorage("GlassList.selectionEaseIn") private var selectionEaseIn = 0.25
    @AppearanceStorage("GlassList.selectionEaseOut") private var selectionEaseOut = 0.30
    @AppearanceStorage("GlassList.highlightColorLight") private var highlightColorLight = "FFFFFF"
    @AppearanceStorage("GlassList.highlightColorDark") private var highlightColorDark = "1F1F1F"
    @AppearanceStorage("GlassList.selectedHDRWhiteLight") private var selectedHDRWhiteLight = UserDefaults.standard.object(forKey: "GlassList.selectedHDRWhite") as? Double ?? 0.0
    @AppearanceStorage("GlassList.selectedHDRWhiteDark") private var selectedHDRWhiteDark = 0.0
    @AppearanceStorage("GlassList.selectedHDRSoftness") private var selectedHDRSoftness = 0.0
    @AppearanceStorage("GlassList.selectedHDRSpread") private var selectedHDRSpread = 0.0
    @AppearanceStorage("GlassList.columnLightBrightness") private var columnLightBrightness = 0.955
    @AppearanceStorage("GlassList.columnDarkBrightness") private var columnDarkBrightness = 0.105
    @AppearanceStorage("GlassList.shadowTopStrength") private var shadowTopStrength = 0.12
    @AppearanceStorage("GlassList.shadowTopSoftness") private var shadowTopSoftness = 8.0
    @AppearanceStorage("GlassList.shadowTopLift") private var shadowTopLift = 4.0
    @AppearanceStorage("GlassList.shadowBottomStrength") private var shadowBottomStrength = 0.22
    @AppearanceStorage("GlassList.shadowBottomSoftness") private var shadowBottomSoftness = 12.0
    @AppearanceStorage("GlassList.shadowBottomLift") private var shadowBottomLift = 7.0

    private var shadowSettings: TorrentShadowSettings {
        TorrentShadowSettings(topStrength: shadowTopStrength, topSoftness: shadowTopSoftness, topLift: shadowTopLift, bottomStrength: shadowBottomStrength, bottomSoftness: shadowBottomSoftness, bottomLift: shadowBottomLift, easeIn: selectionEaseIn, easeOut: selectionEaseOut, hdrWhite: colorScheme == .dark ? selectedHDRWhiteDark : selectedHDRWhiteLight, hdrSoftness: selectedHDRSoftness, hdrSpread: selectedHDRSpread, isDark: colorScheme == .dark, highlightColorLight: highlightColorLight, highlightColorDark: highlightColorDark, increasedContrast: colorContrast == .increased)
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorContrast

    private var listSurface: Color {
        Color(white: colorScheme == .dark ? columnDarkBrightness : columnLightBrightness)
    }

    private func headerIndex(_ id: String) -> Int {
        var index = 0
        for section in TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles) {
            if section.id == id { return index }
            index += section.rows.count + 1
        }
        return index
    }

    private var density: TorrentRowDensity {
        densityLevel == 0 ? .compact : (columnWidth > 0 ? TorrentRowDensity(width: max(0, columnWidth - leftPadding - rightPadding)) : .regular)
    }
    private var listRowHeight: CGFloat {
        max(0, (densityLevel == 0 ? 34 : densityLevel == 2 ? 76 : 60) + 2 * itemVerticalPadding)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            Group {
            if grid {
                ScrollView {
                    LazyVStack(spacing: 12, pinnedViews: .sectionHeaders) {
                        ForEach(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles)) { section in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: densityLevel == 0 ? 150 : densityLevel == 2 ? 240 : 190))], spacing: 12) {
                                    ForEach(section.rows) { row in
                                        liveRow(for: row).onTapGesture { selection = row.id }.id(row.id)
                                    }
                                }
                            } header: {
                                Text(section.title).font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).background(listSurface)
                            }
                        }
                    }.padding(.leading, leftPadding + 16).padding(.trailing, rightPadding + 16)
                }.background(listSurface)
            } else {
            List(selection: $selection) {
                ForEach(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles)) { section in
                    TorrentStickyTitle(title: section.title, id: section.id, rowIndex: headerIndex(section.id), inset: leftPadding + 16, controller: stickyHeaders)
                        .selectionDisabled()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                    ForEach(section.rows) { row in
                        liveRow(for: row)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listItemTint(.monochrome)
                            .tag(row.id)
                            .accessibilityElement(children: .contain)
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
            .environment(\.defaultMinListRowHeight, listRowHeight)
            .focusEffectDisabled()
            .tint(Color(nsColor: .secondaryLabelColor))
            .scrollEdgeEffectHidden(true, for: .top)
            .glassSwipeActionsContainer()
            .onChange(of: revealSelectionToken) { _, _ in
                revealAndScrollToTorrent(selection, using: scrollProxy)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .background(listSurface)
            }
            }
        }
        .onAppear {
            stickyHeaders.configure(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles), inset: leftPadding + 16)
            elevationController.observeTable { stickyHeaders.attach($0) }
        }
        .onChange(of: lowercaseTitles) { _, _ in stickyHeaders.configure(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles), inset: leftPadding + 16) }
        .onChange(of: leftPadding) { _, _ in stickyHeaders.configure(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles), inset: leftPadding + 16) }
        .onChange(of: headerAppearance, initial: true) { _, appearance in stickyHeaders.configureAppearance(appearance) }
        .onChange(of: presentation.rows.map(\.id)) { _, _ in
            stickyHeaders.configure(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles), inset: leftPadding + 16)
        }
        .task(id: columnWidth) {
            guard !paddingIsPermanent, columnWidth > 0 else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            // Preserve the gap of the former centered 480-point list exactly once.
            leftPadding = max(leftPadding, (columnWidth - 480) / 2)
            rightPadding = max(rightPadding, (columnWidth - 480) / 2)
            paddingIsPermanent = true
        }
        .onAppear {
            for (key, value) in [("GlassList.leftPadding", leftPadding), ("GlassList.rightPadding", rightPadding)] where UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value, forKey: key)
            }
            elevationController.dragSelectionChanged = { id in
                guard presentation.rows.contains(where: { $0.id == id }) else { return }
                if selection != id { selection = id }
            }
            synchronizePresentation(animated: false)
        }
        .onDisappear { elevationController.detach() }
        .onChange(of: grid) { _, value in if value { elevationController.detach() } }
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

    private func liveRow(for row: TorrentListRowPresentation) -> some View {
        TorrentListLiveRow(
            row: row,
            isSelected: selection == row.id,
            leftPadding: grid ? 0 : leftPadding,
            rightPadding: grid ? 0 : rightPadding,
            grid: grid,
            rowHeight: listRowHeight,
            folderMotion: folderMotion,
            folderIDs: row.groupMemberIDs.map { Array($0.prefix(3)) } ?? [],
            folderID: presentation.rows.first(where: { $0.groupMemberIDs?.prefix(3).contains(row.id) == true }) == nil ? nil : row.id,
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
            toggleTransfers: { await toggleTransfers(for: row) }
        )
        .draggable(row.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != row.id,
                  let dragged = presentation.rows.first(where: { $0.id == id }), dragged.sourceID == row.sourceID else { return false }
            @MainActor func hashes(_ item: TorrentListRowPresentation) -> [String] {
                switch item.kind {
                case let .torrent(record, _): return [record.hashString]
                case let .group(records, _, _): return records.map(\.hashString)
                }
            }
            Task { await model.reorder(hashes(dragged), before: hashes(row), sourceID: row.sourceID) }
            return true
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

    private func toggleTransfers(for row: TorrentListRowPresentation) async -> Bool {
        switch row.kind {
        case let .torrent(record, _):
            let torrent = record.summary
            if torrent.canStopTransfer {
                return await model.stop(torrent, sourceID: record.sourceID)
            } else {
                return await model.start(torrent, sourceID: record.sourceID)
            }
        case let .group(records, _, _):
            return await toggleGroupTransfers(records)
        }
    }

    private func isUnavailable(_ record: TorrentRecord) -> Bool {
        record.summary.hasStorageError || TorrentThumbnailService.shared.isShareUnavailable(
            sourceID: record.sourceID, directory: record.summary.downloadDir,
            isLocal: record.sourceID == model.localSourceID
        )
    }

    private func toggleGroupTransfers(_ records: [TorrentRecord]) async -> Bool {
        let liveTorrents = records.filter { $0.summary.id >= 0 }
        let unfinished = liveTorrents.filter { $0.summary.isUnfinished && !isUnavailable($0) }
        let transfers = unfinished.isEmpty ? liveTorrents : unfinished
        guard !transfers.isEmpty else { return false }
        var succeeded = true

        if transfers.contains(where: { $0.summary.canStopTransfer }) {
            for record in transfers where record.summary.canStopTransfer {
                let result = await model.stop(record.summary, sourceID: record.sourceID)
                succeeded = result && succeeded
            }
        } else {
            for record in transfers {
                let result = await model.start(record.summary, sourceID: record.sourceID)
                succeeded = result && succeeded
            }
        }
        return succeeded
    }

    @ViewBuilder
    private var emptyState: some View {
        if records.isEmpty, model.sources.allSatisfy({ !$0.isLoading }) {
            VStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 64, height: 64)
                Text("Drop torrents here").font(.title3.weight(.semibold))
                Text("Torrent files or magnet links").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { DropCorners().stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round)) }
            .padding(28)
            .allowsHitTesting(false)
        }

    }
}

private struct TorrentListLiveRow: View {
    @AppStorage("GlassList.showExtensions") private var showExtensions = false
    let row: TorrentListRowPresentation
    let isSelected: Bool
    let leftPadding: CGFloat
    let rightPadding: CGFloat
    let grid: Bool
    let rowHeight: CGFloat
    let folderMotion: Namespace.ID
    let folderIDs: [String]
    let folderID: String?
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
    let toggleTransfers: () async -> Bool

    var body: some View {
        TorrentSwipeRow(selected: isSelected, remove: removeRow, presentationChanged: swipePresentationChanged, commitsOnRelease: true, foregroundInset: grid ? 0 : leftPadding + 2, foregroundTrailingInset: grid ? 0 : rightPadding + 2) {
        TorrentRowView(
            torrent: summary,
            showsExtensions: showExtensions,
            density: density,
            grid: grid,
            folderMotion: folderMotion,
            folderIDs: folderIDs,
            folderID: folderID,
            groupIsExpanded: row.groupIsExpanded,
            groupCount: row.groupCount,
            toggleGroupExpansion: toggleGroupExpansion,
            pendingOldName: pendingOldName,
            shareUnavailable: shareUnavailable,
            thumbnailInput: row.torrentRecord.flatMap { TorrentThumbnailInput.movie($0.summary, sourceID: $0.sourceID, isLocal: $0.sourceID == model.localSourceID) },
            toggleTransfer: toggleTransfers
        )
        .equatable()
        .frame(minHeight: grid ? 164 : rowHeight)
        .background {
            // The card extends 14 points beyond the content on each side, and
            // follows the actual foreground view when native swipe actions move it.
            if !grid { TorrentListElevationAnchor(controller: elevationController, rowID: row.id, selected: isSelected, separatorLeadingInset: density.showsIcon ? 62 : 14)
                .padding(.horizontal, -14)
                .padding(.vertical, 3) }
        }
        .glassContextMenu(select: select) { contextMenuContent }
        .padding(.leading, grid ? 0 : leftPadding + 16)
        .padding(.trailing, grid ? 0 : rightPadding + 16)
        .background { if grid && isSelected { RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(0.15), radius: 8, y: 4) } }
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
