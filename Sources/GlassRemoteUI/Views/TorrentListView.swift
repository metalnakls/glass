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
    @State private var columnWidth: CGFloat = 0
    @State private var elevationController = TorrentListElevationController()
    @State private var shadowTuning = false
    @State private var swipingRowID: String?
    @AppStorage("GlassList.selectedHDRWhite") private var selectedHDRWhite = 0.0
    @AppStorage("GlassList.columnLightBrightness") private var columnLightBrightness = 0.955
    @AppStorage("GlassList.columnDarkBrightness") private var columnDarkBrightness = 0.105
    @AppStorage("GlassList.shadowTopStrength") private var shadowTopStrength = 0.12
    @AppStorage("GlassList.shadowTopSoftness") private var shadowTopSoftness = 8.0
    @AppStorage("GlassList.shadowTopLift") private var shadowTopLift = 4.0
    @AppStorage("GlassList.shadowBottomStrength") private var shadowBottomStrength = 0.22
    @AppStorage("GlassList.shadowBottomSoftness") private var shadowBottomSoftness = 12.0
    @AppStorage("GlassList.shadowBottomLift") private var shadowBottomLift = 7.0

    private var shadowSettings: TorrentShadowSettings {
        TorrentShadowSettings(topStrength: shadowTopStrength, topSoftness: shadowTopSoftness, topLift: shadowTopLift, bottomStrength: shadowBottomStrength, bottomSoftness: shadowBottomSoftness, bottomLift: shadowBottomLift)
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorContrast

    private var listSurface: Color {
        Color(white: colorScheme == .dark ? columnDarkBrightness : columnLightBrightness)
    }

    private var selectedSurface: Color {
        let base = colorScheme == .dark ? pow((0.21 + 0.055) / 1.055, 2.4) : 1.0
        let white = base + min(max(selectedHDRWhite, 0), 3)
        return Color(.sRGBLinear, white: white).headroom(max(1, white))
    }

    private var columnBrightness: Binding<Double> {
        Binding(get: { colorScheme == .dark ? columnDarkBrightness : columnLightBrightness }, set: {
            if colorScheme == .dark { columnDarkBrightness = $0 } else { columnLightBrightness = $0 }
        })
    }

    private var density: TorrentRowDensity {
        columnWidth > 0 ? TorrentRowDensity(width: columnWidth) : .regular
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $selection) {
                ForEach(presentation.rows) { row in
                    liveRow(for: row)
                    .listRowBackground(raisedSurface(selected: selection == row.id, isSwiping: swipingRowID == row.id))
                    .listItemTint(.monochrome)
                    .tag(row.id)
                    .accessibilityElement(children: .contain)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(listSurface)
            .contentMargins(.horizontal, nil, for: .scrollContent)
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
        }
        .onAppear {
            synchronizePresentation(animated: false)
        }
        .onDisappear { elevationController.detach() }
        .onChange(of: shadowSettings, initial: true) { _, settings in
            elevationController.configure(settings)
        }
        .onChange(of: selection) { _, value in
            if value == nil { elevationController.clear() }
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
        .overlay(alignment: .bottomTrailing) {
            if selection != nil {
                Button { shadowTuning = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Tune selection appearance")
                .accessibilityLabel("Tune selection appearance")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
                .popover(isPresented: $shadowTuning) { shadowControls }
            }
        }
        .overlay {
            if records.isEmpty {
                emptyState
            }
        }
    }

    private func raisedSurface(selected: Bool, isSwiping: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .circular)
            .fill(selected ? selectedSurface : .clear)
            .allowedDynamicRange(.high)
            .overlay {
                if selected && colorContrast == .increased {
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .strokeBorder(colorScheme == .dark ? .white.opacity(colorContrast == .increased ? 0.45 : 0.10) : .black.opacity(colorContrast == .increased ? 0.35 : 0.045), lineWidth: 1)
                }
            }
            .background(TorrentListElevationAnchor(controller: elevationController, selected: selected))
            .padding(.horizontal, 2)
            .padding(.trailing, isSwiping ? 120 : 0)
            .padding(.vertical, 3)
            .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.25), value: selected)
    }

    private var shadowControls: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selection Appearance").font(.headline)
                Spacer()
                Button("Done") { shadowTuning = false }
            }
            HStack {
                Text("HDR white")
                Spacer()
                Text(selectedHDRWhite, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Slider(value: $selectedHDRWhite, in: 0...3).accessibilityLabel("HDR white")
            shadowSlider("Column brightness", value: columnBrightness, range: 0...1, percent: true)
            Divider()
            Text("Above").font(.subheadline.weight(.semibold))
            shadowSlider("Strength", value: $shadowTopStrength, range: 0...0.65, percent: true)
            shadowSlider("Softness", value: $shadowTopSoftness, range: 0...32)
            shadowSlider("Lift", value: $shadowTopLift, range: 0...24)
            Divider()
            Text("Below").font(.subheadline.weight(.semibold))
            shadowSlider("Strength", value: $shadowBottomStrength, range: 0...0.65, percent: true)
            shadowSlider("Softness", value: $shadowBottomSoftness, range: 0...32)
            shadowSlider("Lift", value: $shadowBottomLift, range: 0...24)
            Button("Reset") {
                selectedHDRWhite = 0
                if colorScheme == .dark { columnDarkBrightness = 0.105 } else { columnLightBrightness = 0.955 }
                shadowTopStrength = 0.12; shadowTopSoftness = 8; shadowTopLift = 4
                shadowBottomStrength = 0.22; shadowBottomSoftness = 12; shadowBottomLift = 7
            }
        }
        .padding(16)
        }
        .frame(width: 280, height: 530)
    }

    private func shadowSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : "\(Int(value.wrappedValue.rounded()))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    private func liveRow(for row: TorrentListRowPresentation) -> TorrentListLiveRow {
        TorrentListLiveRow(
            row: row,
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
        TorrentRowView(
            torrent: summary,
            showsExtensions: showExtensions,
            density: density,
            groupIsExpanded: row.groupIsExpanded,
            groupCount: row.groupCount,
            toggleGroupExpansion: toggleGroupExpansion,
            pendingOldName: pendingOldName,
            thumbnailInput: row.torrentRecord.flatMap { TorrentThumbnailInput.movie($0.summary, sourceID: $0.sourceID, isLocal: $0.sourceID == model.localSourceID) },
            toggleTransfer: toggleTransfers
        )
        .equatable()
        .glassContextMenu(select: select) { contextMenuContent }
        .glassFlatSwipeActions(onPresentationChanged: swipePresentationChanged) {
            Button("Delete Torrent + Data", systemImage: "trash", role: .destructive) {
                removeRow(deleteData: true)
            }
            .labelStyle(.iconOnly)
            .help("Delete Torrent + Data")
            .tint(.red)
            Button("Delete Torrent", systemImage: "xmark") {
                removeRow(deleteData: false)
            }
            .labelStyle(.iconOnly)
            .help("Delete Torrent")
            .tint(.yellow)
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
        Text("Date added: \(formatTimestamp(torrent.addedDate))")
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
            fileCount: fileCount,
            addedDate: addedDate
        )
    }
}
