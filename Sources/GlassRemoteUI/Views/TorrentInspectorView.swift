import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentInspectorView: View {
    let model: RemoteAppModel
    let selectedTorrentHash: String?
    @AppStorage("GlassInspector.infoExpanded") private var isInfoExpanded = false
    @AppStorage("GlassInspector.filesExpanded") private var isFilesExpanded = false
    @AppStorage("GlassInspector.peersExpanded") private var isPeersExpanded = false
    @AppStorage("GlassInspector.trackersExpanded") private var isTrackersExpanded = false
    @AppStorage("GlassInspector.piecesExpanded") private var isPiecesExpanded = false
    @AppStorage("GlassInspector.settingsExpanded") private var isSettingsExpanded = false
    @AppStorage("GlassInspector.fileSort") private var fileSortRawValue = TorrentFileSort.name
        .rawValue
    @AppStorage("GlassInspector.fileSortAscending") private var isFileSortAscending = true
    @State private var fileSearchText = ""
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Group {
            if selectedTorrentHash == nil {
                ContentUnavailableView(
                    "No Torrent Selected",
                    systemImage: "info.circle",
                    description: Text("Select a torrent to show details.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if model.isLoadingTorrentDetails {
                HStack(spacing: 8) {
                    GlassActivityIndicator(label: "Loading torrent details")
                        .foregroundStyle(.secondary)
                    Text("Loading details…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let error = model.torrentDetailsError {
                ContentUnavailableView(
                    "Couldn’t Load Details",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        torrentSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var torrentSection: some View {
        if let details = model.selectedTorrentDetails {
            VStack(alignment: .leading, spacing: 14) {
                Text(details.name)
                    .font(.title3.bold())
                    .lineLimit(3)

                DisclosureGroup(isExpanded: animatedBinding($isInfoExpanded)) {
                    VStack(alignment: .leading, spacing: 8) {
                        InspectorField("Status", details.status.map(formatStatus) ?? "Unavailable")
                        InspectorField("Progress", details.percentDone.map(formatPercent) ?? "Unavailable")
                        InspectorField("Size", formatBytes(details.sizeWhenDone ?? details.totalSize))
                        InspectorField("Left", formatBytes(details.leftUntilDone))
                        InspectorField("Ratio", formatRatio(details.uploadRatio))
                        InspectorField("Download Dir", details.downloadDir ?? "Unavailable")
                        InspectorField("Added", formatTimestamp(details.addedDate))
                        InspectorField("Active", formatTimestamp(details.activityDate))
                        InspectorField("Downloaded", formatBytes(details.downloadedEver))
                        InspectorField("Uploaded", formatBytes(details.uploadedEver))
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Info")
                }

                DisclosureGroup(isExpanded: animatedBinding($isFilesExpanded)) {
                    VStack(alignment: .leading, spacing: 8) {
                        filesControls
                        TorrentFilesSection(
                            model: model,
                            details: details,
                            searchText: fileSearchText,
                            sort: fileSort,
                            isAscending: isFileSortAscending
                        )
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Files")
                        .contextMenu {
                            Button("All", systemImage: "checkmark.square") {
                                setAllFiles(in: details, wanted: true)
                            }
                            Button("None", systemImage: "square") {
                                setAllFiles(in: details, wanted: false)
                            }
                        }
                }

                DisclosureGroup(isExpanded: animatedBinding($isPeersExpanded)) {
                    VStack(alignment: .leading, spacing: 8) {
                        if details.peers.isEmpty {
                            Text("No peers")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(details.peers.enumerated()), id: \.offset) { _, peer in
                                InspectorField(
                                    peer.address ?? "Peer",
                                    "\(formatRate(peer.rateToClient ?? 0)) down, \(formatRate(peer.rateToPeer ?? 0)) up"
                                )
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Peers")
                }

                DisclosureGroup(isExpanded: animatedBinding($isTrackersExpanded)) {
                    VStack(alignment: .leading, spacing: 8) {
                        if details.trackerStats.isEmpty {
                            Text("No trackers")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(details.trackerStats) { tracker in
                                InspectorField(
                                    tracker.host ?? tracker.announce ?? "Tracker",
                                    tracker.lastAnnounceResult?.isEmpty == false
                                        ? tracker.lastAnnounceResult! : "Ready"
                                )
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Trackers")
                }

                DisclosureGroup(isExpanded: animatedBinding($isPiecesExpanded)) {
                    VStack(alignment: .leading, spacing: 8) {
                        InspectorField("Pieces", details.pieceCount.map(String.init) ?? "Unavailable")
                        InspectorField("Piece Size", formatBytes(details.pieceSize))
                        if let pieceCount = details.pieceCount, let pieces = details.pieces {
                            InspectorField(
                                "Complete",
                                "\(completedPieceCount(from: pieces, total: pieceCount)) of \(pieceCount)")
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Pieces")
                }

                DisclosureGroup(isExpanded: animatedBinding($isSettingsExpanded)) {
                    VStack(alignment: .leading, spacing: 8) {
                        InspectorField(
                            "Download Limit",
                            limitText(limit: details.downloadLimit, enabled: details.downloadLimited))
                        InspectorField(
                            "Upload Limit", limitText(limit: details.uploadLimit, enabled: details.uploadLimited))
                        InspectorField(
                            "Seed Ratio",
                            details.seedRatioLimit.map { $0.formatted(.number.precision(.fractionLength(2))) }
                                ?? "Unavailable")
                        InspectorField("Priority", formatPriority(details.bandwidthPriority))
                        InspectorField("Queue", details.queuePosition.map { "#\($0 + 1)" } ?? "Unavailable")
                        InspectorField("Private", formatBool(details.isPrivate))
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Settings")
                }
            }
        } else if selectedTorrentHash != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Details Unavailable")
                    .font(.title3.bold())
                Text("Select the torrent again to load details.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func limitText(limit: Int?, enabled: Bool?) -> String {
        guard enabled == true, let limit else { return "Unlimited" }
        return "\(limit) KB/s"
    }

    private var fileSort: TorrentFileSort {
        TorrentFileSort(rawValue: fileSortRawValue) ?? .name
    }

    private var fileSortBinding: Binding<TorrentFileSort> {
        Binding(
            get: { fileSort },
            set: { fileSortRawValue = $0.rawValue }
        )
    }

    private var filesControls: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $fileSearchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 72, maxWidth: .infinity)

            Menu {
                Picker("Sort By", selection: fileSortBinding) {
                    ForEach(TorrentFileSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Divider()

                Toggle("Ascending", isOn: $isFileSortAscending)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("Sort Files")
        }
    }

    private func animatedBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { isExpanded in
                withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    binding.wrappedValue = isExpanded
                }
            }
        )
    }

    private func setAllFiles(in details: TorrentDetails, wanted: Bool) {
        let indices = Array(details.files.indices)
        guard !indices.isEmpty else { return }
        Task {
            await model.setFileWanted(details.summaryFallback, fileIndices: indices, wanted: wanted)
        }
    }
}

private struct TorrentFilesSection: View {
    let model: RemoteAppModel
    let details: TorrentDetails
    let searchText: String
    let sort: TorrentFileSort
    let isAscending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text("No matching files")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Toggle(
                            isOn: Binding(
                                get: { entry.stats?.wanted ?? true },
                                set: { isWanted in
                                    Task {
                                        await model.setFileWanted(
                                            details.summaryFallback,
                                            fileIndices: [entry.index],
                                            wanted: isWanted
                                        )
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.file.name)
                                    .lineLimit(2)
                                Text(
                                    "\(formatBytes(entry.file.bytesCompleted)) of \(formatBytes(entry.file.length))"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        Menu {
                            priorityMenu(for: entry)
                        } label: {
                            Image(systemName: prioritySystemImage(entry.stats?.priority))
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 18, height: 18)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Priority: \(formatPriority(entry.stats?.priority))")
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(entry.stats?.wanted == false ? "Download" : "Don’t Download") {
                            setWanted(entry.stats?.wanted == false, for: entry)
                        }

                        Divider()

                        Menu("Priority") {
                            priorityMenu(for: entry)
                        }
                    }
                }
            }
        }
    }

    private var entries: [TorrentFileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = details.files.enumerated().compactMap { index, file -> TorrentFileEntry? in
            guard query.isEmpty || file.name.localizedCaseInsensitiveContains(query) else { return nil }
            let stats = details.fileStats.indices.contains(index) ? details.fileStats[index] : nil
            return TorrentFileEntry(index: index, file: file, stats: stats)
        }

        return values.sorted { lhs, rhs in
            let comparison = sort.compare(lhs, rhs)
            if comparison == .orderedSame {
                return lhs.index < rhs.index
            }
            return isAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    @ViewBuilder
    private func priorityMenu(for entry: TorrentFileEntry) -> some View {
        Button("High", systemImage: entry.stats?.priority == 1 ? "checkmark" : "arrow.up") {
            setPriority(1, for: entry)
        }
        Button("Normal", systemImage: entry.stats?.priority == 0 ? "checkmark" : "equal") {
            setPriority(0, for: entry)
        }
        Button("Low", systemImage: entry.stats?.priority == -1 ? "checkmark" : "arrow.down") {
            setPriority(-1, for: entry)
        }
    }

    private func setWanted(_ wanted: Bool, for entry: TorrentFileEntry) {
        Task {
            await model.setFileWanted(details.summaryFallback, fileIndices: [entry.index], wanted: wanted)
        }
    }

    private func setPriority(_ priority: Int, for entry: TorrentFileEntry) {
        Task {
            await model.setFilePriority(
                details.summaryFallback, fileIndices: [entry.index], priority: priority)
        }
    }
}

private enum TorrentFileSort: String, CaseIterable, Identifiable {
    case name
    case size
    case progress
    case priority

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .progress: "Progress"
        case .priority: "Priority"
        }
    }

    func compare(_ lhs: TorrentFileEntry, _ rhs: TorrentFileEntry) -> ComparisonResult {
        switch self {
        case .name:
            lhs.file.name.localizedStandardCompare(rhs.file.name)
        case .size:
            compareValues(lhs.file.length, rhs.file.length)
        case .progress:
            compareValues(lhs.progress, rhs.progress)
        case .priority:
            compareValues(lhs.stats?.priority ?? 0, rhs.stats?.priority ?? 0)
        }
    }

    private func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

private struct TorrentFileEntry: Identifiable {
    let index: Int
    let file: TorrentFile
    let stats: TorrentFileStats?

    var id: Int { index }

    var progress: Double {
        guard file.length > 0 else { return 0 }
        return Double(file.bytesCompleted) / Double(file.length)
    }
}

private struct InspectorField: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow(alignment: .top) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 86, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
    }
}

extension TorrentDetails {
    fileprivate var summaryFallback: TorrentSummary {
        TorrentSummary(
            id: id,
            hashString: hashString,
            name: name,
            status: status ?? TransmissionTorrentStatus.stopped.rawValue,
            percentDone: percentDone ?? 0,
            metadataPercentComplete: 1,
            rateDownload: 0,
            rateUpload: 0,
            sizeWhenDone: sizeWhenDone ?? totalSize ?? 0,
            leftUntilDone: leftUntilDone ?? 0,
            eta: eta ?? -1,
            uploadRatio: uploadRatio ?? -1,
            peersConnected: nil,
            downloadDir: downloadDir,
            bandwidthPriority: bandwidthPriority,
            queuePosition: queuePosition
        )
    }
}
