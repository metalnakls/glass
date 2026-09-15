import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentInspectorView: View {
    let model: RemoteAppModel
    let selectedTorrentHash: String?
    let selectedTorrentGroup: TorrentNameSequenceGroup?
    @AppStorage("GlassInspector.infoExpanded") private var isInfoExpanded = false
    @AppStorage("GlassInspector.filesExpanded") private var isFilesExpanded = false
    @AppStorage("GlassInspector.peersExpanded") private var isPeersExpanded = false
    @AppStorage("GlassInspector.trackersExpanded") private var isTrackersExpanded = false
    @AppStorage("GlassInspector.piecesExpanded") private var isPiecesExpanded = false
    @AppStorage("GlassInspector.settingsExpanded") private var isSettingsExpanded = false
    @State private var fileSearchText = ""
    @State private var groupDetails: [String: TorrentDetails] = [:]
    @State private var groupDetailsError: String?
    @State private var isLoadingGroupDetails = false
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
        .task(id: detailLoadInput) {
            guard selectedTorrentGroup == nil else { return }
            guard let selectedTorrentHash else { return }
            let sections = Set(detailLoadInput.sections)
            model.setVisibleTorrentDetailSections(sections, forHashString: selectedTorrentHash)
            await withTaskGroup(of: Void.self) { group in
                for section in sections {
                    group.addTask {
                        await model.loadDetailSection(section, forHashString: selectedTorrentHash)
                    }
                }
            }
        }
        .task(id: groupDetailLoadInput) {
            guard let selectedTorrentGroup else {
                groupDetails = [:]
                groupDetailsError = nil
                isLoadingGroupDetails = false
                return
            }
            isLoadingGroupDetails = groupDetails.isEmpty
            groupDetailsError = nil
            do {
                let sections: Set<TorrentDetailSection> = isFilesExpanded ? [.files] : []
                let details = try await model.fetchDetails(
                    for: selectedTorrentGroup.torrents,
                    including: sections
                )
                guard !Task.isCancelled else { return }
                groupDetails = Dictionary(uniqueKeysWithValues: details.map { ($0.hashString, $0) })
            } catch is CancellationError {
                return
            } catch {
                groupDetailsError = error.localizedDescription
            }
            isLoadingGroupDetails = false
        }
        .onChange(of: selectedTorrentHash) { _, hashString in
            if hashString == nil {
                fileSearchText = ""
            }
        }
        .onDisappear {
            fileSearchText = ""
        }
    }

    private var detailLoadInput: TorrentInspectorDetailLoadInput {
        TorrentInspectorDetailLoadInput(
            hashString: selectedTorrentHash,
            detailsID: model.selectedTorrentDetails?.id,
            sections: [
                isFilesExpanded ? .files : nil,
                isPeersExpanded ? .peers : nil,
                isTrackersExpanded ? .trackers : nil,
                isPiecesExpanded ? .pieces : nil
            ].compactMap { $0 }
        )
    }

    private var groupDetailLoadInput: TorrentGroupInspectorLoadInput {
        TorrentGroupInspectorLoadInput(
            groupID: selectedTorrentGroup?.id,
            torrents: selectedTorrentGroup?.torrents ?? [],
            loadsFiles: isFilesExpanded
        )
    }

    @ViewBuilder
    private var torrentSection: some View {
        if let group = selectedTorrentGroup {
            groupSection(group)
        } else if let details = model.selectedTorrentDetails {
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
                        if model.loadingTorrentDetailSections.contains(.files), details.files.isEmpty {
                            detailLoadingView("Loading files")
                        } else if let error = model.torrentDetailSectionErrors[.files], details.files.isEmpty {
                            detailErrorView(error)
                        } else {
                            TorrentFilesBrowser(
                                entries: fileEntries(for: details),
                                searchText: $fileSearchText,
                                onSetWanted: { index, wanted in
                                    setFileWanted(in: details, index: index, wanted: wanted)
                                },
                                onSetPriority: { index, priority in
                                    setFilePriority(in: details, index: index, priority: priority)
                                },
                                onSetAllWanted: { wanted in
                                    setAllFiles(in: details, wanted: wanted)
                                }
                            )
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Files")
                }

                DisclosureGroup(isExpanded: animatedBinding($isPeersExpanded)) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.loadingTorrentDetailSections.contains(.peers) {
                            detailLoadingView("Loading peers")
                        } else if let error = model.torrentDetailSectionErrors[.peers] {
                            detailErrorView(error)
                        } else if details.peers.isEmpty {
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
                        if model.loadingTorrentDetailSections.contains(.trackers) {
                            detailLoadingView("Loading trackers")
                        } else if let error = model.torrentDetailSectionErrors[.trackers] {
                            detailErrorView(error)
                        } else if details.trackerStats.isEmpty {
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
                        if model.loadingTorrentDetailSections.contains(.pieces) {
                            detailLoadingView("Loading pieces")
                        } else if let error = model.torrentDetailSectionErrors[.pieces] {
                            detailErrorView(error)
                        } else {
                            InspectorField("Pieces", details.pieceCount.map(String.init) ?? "Unavailable")
                            InspectorField("Piece Size", formatBytes(details.pieceSize))
                            if let pieceCount = details.pieceCount, let pieces = details.pieces {
                                InspectorField(
                                    "Complete",
                                    "\(completedPieceCount(from: pieces, total: pieceCount)) of \(pieceCount)")
                            }
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

    private func groupSection(_ group: TorrentNameSequenceGroup) -> some View {
        let summary = group.summary
        return VStack(alignment: .leading, spacing: 14) {
            Text(group.displayName)
                .font(.title3.bold())
                .lineLimit(3)

            DisclosureGroup(isExpanded: animatedBinding($isInfoExpanded)) {
                VStack(alignment: .leading, spacing: 8) {
                    InspectorField("Torrents", String(group.torrents.count))
                    InspectorField("Progress", formatPercent(summary.percentDone))
                    InspectorField("Size", formatBytes(summary.sizeWhenDone))
                    InspectorField("Left", formatBytes(summary.leftUntilDone))
                    InspectorField("Download", formatRate(summary.rateDownload))
                    InspectorField("Upload", formatRate(summary.rateUpload))
                }
                .padding(.top, 8)
            } label: {
                Text("Info")
            }

            DisclosureGroup(isExpanded: animatedBinding($isFilesExpanded)) {
                VStack(alignment: .leading, spacing: 12) {
                    TorrentFilesBrowserControls(
                        searchText: $fileSearchText,
                        onSetAllWanted: setAllGroupFiles
                    )
                    if isLoadingGroupDetails, groupDetails.isEmpty {
                        detailLoadingView("Loading files")
                    } else if let groupDetailsError, groupDetails.isEmpty {
                        detailErrorView(groupDetailsError)
                    } else {
                        ForEach(group.torrents, id: \.hashString) { torrent in
                            if let details = groupDetails[torrent.hashString] {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(groupMemberName(torrent, group: group))
                                        .font(.headline)
                                    TorrentFilesBrowser(
                                        entries: fileEntries(for: details),
                                        searchText: $fileSearchText,
                                        onSetWanted: { index, wanted in
                                            setFileWanted(in: details, index: index, wanted: wanted)
                                        },
                                        onSetPriority: { index, priority in
                                            setFilePriority(in: details, index: index, priority: priority)
                                        },
                                        onSetAllWanted: { wanted in
                                            setAllFiles(in: details, wanted: wanted)
                                        },
                                        showsControls: false
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Files")
            }
        }
    }

    private func groupMemberName(_ torrent: TorrentSummary, group: TorrentNameSequenceGroup) -> String {
        guard torrent.name.range(
            of: #"(?i)^season[\s._-]+[1-9]\d?$"#,
            options: .regularExpression
        ) != nil else { return torrent.name }
        let season = torrent.name.replacingOccurrences(
            of: #"(?i)^season[\s._-]+"#,
            with: "",
            options: .regularExpression
        )
        return "\(group.displayName) \(season)"
    }

    private func setAllGroupFiles(wanted: Bool) {
        for details in groupDetails.values {
            let indices = Array(details.files.indices)
            guard !indices.isEmpty else { continue }
            Task {
                await model.setFileWanted(details.summaryFallback, fileIndices: indices, wanted: wanted)
            }
        }
    }

    private func limitText(limit: Int?, enabled: Bool?) -> String {
        guard enabled == true, let limit else { return "Unlimited" }
        return "\(limit) KB/s"
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

    private func detailLoadingView(_ label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            GlassActivityIndicator(label: label)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    private func detailErrorView(_ error: String) -> some View {
        Text(error)
            .foregroundStyle(.secondary)
    }

    private func setAllFiles(in details: TorrentDetails, wanted: Bool) {
        let indices = Array(details.files.indices)
        guard !indices.isEmpty else { return }
        Task {
            await model.setFileWanted(details.summaryFallback, fileIndices: indices, wanted: wanted)
        }
    }

    private func setFileWanted(in details: TorrentDetails, index: Int, wanted: Bool) {
        Task {
            await model.setFileWanted(
                details.summaryFallback,
                fileIndices: [index],
                wanted: wanted
            )
        }
    }

    private func setFilePriority(in details: TorrentDetails, index: Int, priority: Int) {
        Task {
            await model.setFilePriority(
                details.summaryFallback,
                fileIndices: [index],
                priority: priority
            )
        }
    }

    private func fileEntries(for details: TorrentDetails) -> [TorrentFileBrowserEntry] {
        details.files.enumerated().map { index, file in
            let stats = details.fileStats.indices.contains(index) ? details.fileStats[index] : nil
            return TorrentFileBrowserEntry(
                index: index,
                file: file,
                rootName: details.name,
                completedBytes: stats?.bytesCompleted,
                isWanted: stats?.wanted ?? true,
                priority: stats?.priority ?? 0
            )
        }
    }
}

private struct TorrentInspectorDetailLoadInput: Equatable {
    let hashString: String?
    let detailsID: Int?
    let sections: [TorrentDetailSection]
}

private struct TorrentGroupInspectorLoadInput: Equatable {
    let groupID: String?
    let torrents: [TorrentSummary]
    let loadsFiles: Bool
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
