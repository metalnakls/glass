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
    @AppearanceStorage("GlassList.sectionSpacing") private var sectionSpacing = 16.0
    @AppearanceStorage("GlassList.headerBottomPadding") private var headerBottomPadding = 0.0
    @AppStorage("GlassList.grid") private var storedGrid = false
    @AppStorage("GlassList.density") private var storedDensityLevel = 1
    @AppStorage("GlassList.enableIconView") private var enableIconView = false
    @AppStorage("GlassList.enableCompactView") private var enableCompactView = false
    private var grid: Bool { enableIconView && storedGrid }
    private var densityLevel: Int { enableCompactView ? storedDensityLevel : max(1, storedDensityLevel) }
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
    @State private var folderMotion = TorrentFolderMotion()
    @State private var artworkPreloader = TorrentArtworkPreloader()
    @State private var reorderingIDs: Set<String> = []
    @State private var swipingRowID: String?
    @AppearanceStorage("GlassList.selectionEaseIn") private var selectionEaseIn = 0.25
    @AppearanceStorage("GlassList.selectionEaseOut") private var selectionEaseOut = 0.30
    @AppearanceStorage("GlassList.highlightWidth") private var highlightWidth = 0.0
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
        TorrentShadowSettings(topStrength: shadowTopStrength, topSoftness: shadowTopSoftness, topLift: shadowTopLift, bottomStrength: shadowBottomStrength, bottomSoftness: shadowBottomSoftness, bottomLift: shadowBottomLift, easeIn: selectionEaseIn, easeOut: selectionEaseOut, hdrWhite: colorScheme == .dark ? selectedHDRWhiteDark : selectedHDRWhiteLight, hdrSoftness: selectedHDRSoftness, hdrSpread: selectedHDRSpread, isDark: colorScheme == .dark, highlightColorLight: highlightColorLight, highlightColorDark: highlightColorDark, increasedContrast: colorContrast == .increased, highlightWidth: highlightWidth)
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorContrast

    private var cardGeometry: TorrentCardGeometry {
        let overflow = density.showsIcon && !grid ? TorrentIconPose.leadingOverflow : 0
        return TorrentCardGeometry(leading: leftPadding + 2 - overflow, trailing: rightPadding + 2,
                                   separatorInset: (density.showsIcon ? 62 : 14) + overflow)
    }

    private var elevationRows: [String?] {
        TorrentListEntry.entries(for: presentation.rows, lowercase: lowercaseTitles).map { entry in
            switch entry {
            case .header: nil
            case let .torrent(row): row.id
            }
        }
    }

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
        densityLevel == 0 ? .compact : (enableCompactView && columnWidth > 0 ? TorrentRowDensity(width: max(0, columnWidth - leftPadding - rightPadding)) : .regular)
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
                                            .moveDisabled(rowIsAdding(row))
                                    }.reorderable(collectionID: section.id)
                                }
                            } header: {
                                Text(section.title).font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).background(listSurface)
                            }
                        }
                    }.padding(.leading, leftPadding + 16).padding(.trailing, rightPadding + 16)
                }.background(listSurface)
                .reorderContainer(for: TorrentListRowPresentation.self, in: String.self) { difference in
                    let destination: TorrentListReorderPlan.Destination
                    switch difference.destination.position {
                    case let .before(id): destination = .before(id)
                    case .end: destination = .end
                    }
                    applyNativeMove(sources: difference.sources, destination: destination)
                }
            } else {
            List(selection: $selection) {
                ForEach(TorrentListEntry.entries(for: presentation.rows, lowercase: lowercaseTitles)) { entry in
                    switch entry {
                    case let .header(section):
                        TorrentStickyTitle(title: section.title, id: section.id, rowIndex: headerIndex(section.id), inset: leftPadding + 16, controller: stickyHeaders)
                            .padding(.top, headerIndex(section.id) == 0 ? 16 : sectionSpacing)
                            .padding(.bottom, headerBottomPadding)
                            .selectionDisabled()
                            .moveDisabled(true)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    case let .torrent(row):
                        liveRow(for: row)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listItemTint(.monochrome)
                            .tag(row.id)
                            .accessibilityElement(children: .contain)
                            .moveDisabled(rowIsAdding(row))
                    }
                }.reorderable()
                    .listRowSeparator(.hidden)
                    .listRowSeparatorTint(.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            .reorderContainer(for: TorrentListEntry.self) { difference in
                let destination: TorrentListReorderPlan.Destination
                switch difference.destination.position {
                case let .before(id): destination = .before(id)
                case .end: destination = .end
                }
                applyNativeMove(sources: difference.sources, destination: destination)
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
            elevationController.setRows(elevationRows)
            stickyHeaders.configure(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles), inset: leftPadding + 16)
            elevationController.observeTable { table in
                stickyHeaders.attach(table)
                folderMotion.attach(table)
                artworkPreloader.attach(table)
            }
        }
        .onChange(of: artworkInputs, initial: true) { _, inputs in artworkPreloader.setInputs(inputs) }
        .onChange(of: lowercaseTitles) { _, _ in stickyHeaders.configure(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles), inset: leftPadding + 16) }
        .onChange(of: leftPadding) { _, _ in stickyHeaders.configure(TorrentListSection.sections(for: presentation.rows, lowercase: lowercaseTitles), inset: leftPadding + 16) }
        .onChange(of: headerAppearance, initial: true) { _, appearance in stickyHeaders.configureAppearance(appearance) }
        .onChange(of: TorrentListEntry.entries(for: presentation.rows, lowercase: lowercaseTitles).map(\.id)) { _, _ in
            elevationController.setRows(elevationRows)
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
            synchronizePresentation(animated: false)
        }
        .onDragSessionUpdated { session in
            switch session.phase {
            case .initial, .active:
                reorderingIDs = Set(session.draggedItemIDs(for: String.self))
                elevationController.setReordering(!reorderingIDs.isEmpty)
            case .ended, .dataTransferCompleted:
                reorderingIDs = []
                elevationController.setReordering(false)
            @unknown default: break
            }
        }
        .onDisappear { reorderingIDs = []; elevationController.setReordering(false); elevationController.detach(); folderMotion.detach(); artworkPreloader.detach() }
        .onChange(of: grid) { _, value in if value { elevationController.detach(); folderMotion.detach(); artworkPreloader.detach() } }
        .onChange(of: shadowSettings, initial: true) { _, settings in
            elevationController.configure(settings)
        }
        .onChange(of: cardGeometry, initial: true) { _, geometry in elevationController.configureGeometry(geometry) }
        .onChange(of: swipingRowID) { _, id in elevationController.setSwiping(id) }
        .onChange(of: selection, initial: true) { _, value in
            elevationController.setSelection(value)
        }
        .onPreferenceChange(TorrentListColumnWidthKey.self) { width in
            columnWidth = width
        }
        .onChange(of: structureInput) { oldInput, newInput in
            let hasRowIdentityChanges = oldInput.recordIDs != newInput.recordIDs
                || oldInput.pendingRenameNames != newInput.pendingRenameNames
                || oldInput.unfinishedIDs != newInput.unfinishedIDs
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
            guard let row = presentation.rows.first(where: { $0.id == selection }) else { return .ignored }
            performFileAction(for: row, action: .preview)
            return .handled
        }
        .overlay {
            if records.isEmpty {
                emptyState
            }
        }
    }

    private func rowIsAdding(_ row: TorrentListRowPresentation) -> Bool {
        switch row.kind {
        case let .torrent(record, _): record.isAdding
        case let .group(records, _, _): records.contains { $0.isAdding }
        }
    }

    private func applyNativeMove(sources: [String], destination: TorrentListReorderPlan.Destination) {
        guard let plan = TorrentListReorderPlan(sources: sources, destination: destination, rows: presentation.rows) else { return }
        // SwiftUI already animates the move. Update the presentation immediately,
        // then send the same move to the server without another drag animation.
        presentation.applyNativeMove(plan.orderedRows)
        Task { await model.reorder(plan.hashes, before: plan.beforeHashes, sourceID: plan.sourceID) }
    }

    private func liveRow(for row: TorrentListRowPresentation) -> some View {
        TorrentListLiveRow(
            row: row,
            iconPosition: presentation.rows.firstIndex(where: { $0.id == row.id }) ?? 0,
            isSelected: selection == row.id,
            isReordering: reorderingIDs.contains(row.id),
            leftPadding: grid ? 0 : leftPadding,
            rightPadding: grid ? 0 : rightPadding,
            grid: grid,
            rowHeight: listRowHeight,
            folderMotion: folderMotion,
            folderIDs: row.groupMemberIDs.map { Array($0.prefix(3)) } ?? [],
            folderID: presentation.rows.first(where: { $0.groupMemberIDs?.prefix(3).contains(row.id) == true }) == nil ? nil : row.id,
            elevationController: elevationController,
            fileAction: { performFileAction(for: row, action: $0) },
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
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            guard grid, visible,
                  let index = TorrentListEntry.entries(for: presentation.rows, lowercase: lowercaseTitles).firstIndex(where: { $0.id == row.id }) else { return }
            artworkPreloader.prefetchAround(index)
        }

    }

    private var artworkInputs: [TorrentThumbnailInput?] {
        TorrentListEntry.entries(for: presentation.rows, lowercase: lowercaseTitles).map { entry in
            guard case let .torrent(row) = entry, let record = row.torrentRecord else { return nil }
            return TorrentThumbnailInput.movie(record.summary, sourceID: record.sourceID, isLocal: record.sourceID == model.localSourceID)
        }
    }

    private func performFileAction(for row: TorrentListRowPresentation, action: TorrentFileActions.Action) {
        switch row.kind {
        case let .torrent(record, _): if record.isAdding { return }
        case let .group(records, _, _): if records.contains(where: { $0.isAdding }) { return }
        }
        let directory: String
        let path: String
        switch row.kind {
        case let .torrent(record, _):
            guard let downloadDirectory = record.summary.downloadDir else {
                TorrentFileActions.shared.showEmptyPreview(); return
            }
            directory = downloadDirectory
            let torrent = record.summary
            let details = model.readyTorrentDetails(forHashString: torrent.hashString, sourceID: row.sourceID, including: [.files])
            path = details?.files.first?.name.split(separator: "/").first.map(String.init) ?? torrent.name
        case let .group(records, _, _):
            guard let common = TorrentFileActions.groupDirectory(records.map(\.summary)) else {
                TorrentFileActions.shared.showEmptyPreview(); return
            }
            directory = common
            path = "."
        }
        Task {
            do { try await TorrentFileActions.shared.perform(action, sourceID: row.sourceID, directory: directory, path: path, isLocal: row.sourceID == model.localSourceID) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private var structureInput: TorrentListStructureInput {
        TorrentListStructureInput(
            revision: structureRevision,
            recordIDs: records.map(\.id),
            pendingRenameNames: pendingRenameNames,
            unfinishedIDs: records.filter { $0.summary.isUnfinished }.map(\.id)
        )
    }

    private var selectedTorrent: TorrentSummary? {
        guard let selection else { return nil }
        return records.first { $0.id == selection && !$0.isAdding }?.summary
    }

    private func toggleAutoGroup(_ row: TorrentListRowPresentation) {
        guard let memberIDs = row.groupMemberIDs else { return }
        if row.groupIsExpanded == true, let selection, memberIDs.contains(selection) {
            self.selection = row.id
        }
        if !grid && density.showsIcon {
            folderMotion.prepare(groupID: row.id, members: memberIDs,
                expanding: row.groupIsExpanded != true, inset: leftPadding + 16,
                indices: folderRowIndices(presentation.rows), reduceMotion: accessibilityReduceMotion)
        }
        let updatedRows = presentation.toggleGroup(
            row.id,
            records: records,
            pendingRenameNames: pendingRenameNames,
            reduceMotion: accessibilityReduceMotion
        )
        let indices = folderRowIndices(updatedRows)
        folderMotion.animateAfterLayout(indices: indices,
            expectedRows: updatedRows.count + TorrentListSection.sections(for: updatedRows).count)
        reconcileSelection(with: updatedRows)
    }

    private func folderRowIndices(_ rows: [TorrentListRowPresentation]) -> [String: Int] {
        var result: [String: Int] = [:]
        var index = 0
        for section in TorrentListSection.sections(for: rows) {
            index += 1 // Native inline section title.
            for row in section.rows { result[row.id] = index; index += 1 }
        }
        return result
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
            guard !record.isAdding else { return false }
            let torrent = record.summary
            if torrent.canStopTransfer {
                return await model.stop(torrent, sourceID: record.sourceID)
            } else {
                return await model.start(torrent, sourceID: record.sourceID)
            }
        case let .group(records, _, _):
            return await toggleGroupTransfers(records.filter { !$0.isAdding })
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
            .padding(28)
            .allowsHitTesting(false)
        }

    }
}

private struct TorrentListLiveRow: View {
    @AppStorage("GlassList.showExtensions") private var showExtensions = false
    let row: TorrentListRowPresentation
    let iconPosition: Int
    let isSelected: Bool
    let isReordering: Bool
    let leftPadding: CGFloat
    let rightPadding: CGFloat
    let grid: Bool
    let rowHeight: CGFloat
    let folderMotion: TorrentFolderMotion
    let folderIDs: [String]
    let folderID: String?
    let elevationController: TorrentListElevationController
    let fileAction: (TorrentFileActions.Action) -> Void
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

    private var artworkOverflow: CGFloat { density.showsIcon && !grid ? TorrentIconPose.leadingOverflow : 0 }

    var body: some View {
        TorrentNativeSwipeRow(enabled: !grid && !isAdding, remove: removeRow, presentationChanged: swipePresentationChanged) {
        TorrentRowView(
            torrent: summary,
            showsExtensions: showExtensions,
            density: density,
            grid: grid,
            folderMotion: folderMotion,
            folderIDs: folderIDs,
            folderID: folderID,
            iconPosition: iconPosition,
            torrentGroupLandingID: row.id,
            groupIsExpanded: row.groupIsExpanded,
            groupCount: row.groupCount,
            toggleGroupExpansion: toggleGroupExpansion,
            pendingOldName: pendingOldName,
            isAdding: isAdding,
            shareUnavailable: shareUnavailable,
            thumbnailInput: row.torrentRecord.flatMap { TorrentThumbnailInput.movie($0.summary, sourceID: $0.sourceID, isLocal: $0.sourceID == model.localSourceID) },
            fileAction: fileAction,
            toggleTransfer: toggleTransfers
        )
        .equatable()
        .allowsHitTesting(!isAdding)
        .frame(minHeight: grid ? 164 : rowHeight)
        .background {
            if isReordering {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .padding(.leading, -14 - artworkOverflow).padding(.trailing, -14)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            }
            // The card extends 14 points beyond the content on each side, and
            // follows the actual foreground view when native swipe actions move it.
            if !grid { TorrentListElevationAnchor(controller: elevationController, rowID: row.id, selected: isSelected, separatorLeadingInset: (density.showsIcon ? 62 : 14) + artworkOverflow)
                .padding(.leading, -14 - artworkOverflow)
                .padding(.trailing, -14)
                .padding(.vertical, 3) }
        }
        .simultaneousGesture(TapGesture().onEnded { select() })
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
        guard !isAdding else { return }
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

    private var isAdding: Bool {
        switch row.kind {
        case let .torrent(record, _): return record.isAdding
        case let .group(records, _, _): return records.contains { $0.isAdding }
        }
    }

    private var shareUnavailable: Bool {
        func isUnavailable(_ record: TorrentRecord) -> Bool {
            if record.isAdding { return false }
            return record.summary.hasStorageError || TorrentThumbnailService.shared.isShareUnavailable(
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
