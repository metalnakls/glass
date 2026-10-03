import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentInspectorView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let sourceID: UUID
    let selectedTorrentHash: String?
    let selectedTorrentGroup: TorrentNameSequenceGroup?
    @State private var fileSearchText = ""
    @State private var groupDetails: [String: TorrentDetails] = [:]
    @State private var groupDetailsError: String?
    @State private var isLoadingGroupDetails = false

    private func thumbnailInput(for entry: TorrentFileBrowserEntry, details: TorrentDetails) -> TorrentThumbnailInput? {
        guard let directory = details.downloadDir,
              ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mpeg", "mpg"].contains(URL(fileURLWithPath: entry.originalPath).pathExtension.lowercased()) else { return nil }
        return TorrentThumbnailInput(sourceID: sourceID, hashString: details.hashString,
            downloadDirectory: directory, filePath: entry.originalPath, length: entry.size,
            isComplete: entry.completedBytes >= entry.size, isLocal: sourceID == model.localSourceID)
    }

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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectHidden(true, for: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: detailLoadInput) {
            guard selectedTorrentGroup == nil else { return }
            guard let selectedTorrentHash else { return }
            let sections = Set(detailLoadInput.sections)
            model.setVisibleTorrentDetailSections(sections, forHashString: selectedTorrentHash, sourceID: sourceID)
            await withTaskGroup(of: Void.self) { group in
                for section in sections {
                    group.addTask {
                        await model.loadDetailSection(section, forHashString: selectedTorrentHash, sourceID: sourceID)
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
                let sections: Set<TorrentDetailSection> = [.files]
                let details = try await model.fetchDetails(
                    for: selectedTorrentGroup.torrents,
                    including: sections,
                    sourceID: sourceID
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
            sourceID: sourceID,
            hashString: selectedTorrentHash,
            detailsID: model.selectedTorrentDetails?.id,
            sections: [.files]
        )
    }

    private var groupDetailLoadInput: TorrentGroupInspectorLoadInput {
        TorrentGroupInspectorLoadInput(
            sourceID: sourceID,
            groupID: selectedTorrentGroup?.id,
            torrents: selectedTorrentGroup?.torrents ?? [],
            loadsFiles: true
        )
    }

    @ViewBuilder
    private var torrentSection: some View {
        if let group = selectedTorrentGroup {
            groupSection(group)
        } else if let details = model.selectedTorrentDetails {
            VStack(alignment: .leading, spacing: 12) {
                downloadLocation(details)
                Divider()
                Text("Files")
                    .font(.headline)
                if model.loadingTorrentDetailSections.contains(.files), details.files.isEmpty {
                    detailLoadingView("Loading files")
                } else if let error = model.torrentDetailSectionErrors[.files], details.files.isEmpty {
                    detailErrorView(error)
                } else {
                    filesBrowser(details)
                }
            }
        } else if selectedTorrentHash != nil {
            Text("Details unavailable. Select the torrent again to load files.")
                .foregroundStyle(.secondary)
        }
    }

    private func groupSection(_ group: TorrentNameSequenceGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let details = group.torrents.first.flatMap({ groupDetails[$0.hashString] }) {
                downloadLocation(details)
                Divider()
            }
            Text("Files")
                .font(.headline)
            TorrentFilesBrowserControls(searchText: $fileSearchText, onSetAllWanted: setAllGroupFiles, isCompact: true)
            if isLoadingGroupDetails, groupDetails.isEmpty {
                detailLoadingView("Loading files")
            } else if let groupDetailsError, groupDetails.isEmpty {
                detailErrorView(groupDetailsError)
            } else {
                ForEach(group.torrents, id: \.hashString) { torrent in
                    if let details = groupDetails[torrent.hashString] {
                        VStack(alignment: .leading, spacing: 8) {
                            // Distinguish members of a multi-torrent selection without repeating its title.
                            Text(groupMemberName(torrent, group: group))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if details.downloadDir != group.torrents.first.flatMap({ groupDetails[$0.hashString]?.downloadDir }) {
                                downloadLocation(details)
                            }
                            filesBrowser(details, showsControls: false)
                        }
                    }
                }
            }
        }
    }

    private func downloadLocation(_ details: TorrentDetails) -> some View {
        TorrentDownloadLocationView(
            directory: details.downloadDir,
            itemPath: details.files.first?.name.split(separator: "/").first.map(String.init) ?? details.name,
            sourceID: sourceID,
            isLocal: sourceID == model.localSourceID,
            localName: model.localSourceName,
            platformIntegration: platformIntegration
        )
    }

    private func filesBrowser(_ details: TorrentDetails, showsControls: Bool = true) -> some View {
        TorrentFilesBrowser(
            entries: fileEntries(for: details),
            searchText: $fileSearchText,
            onSetWanted: { index, wanted in setFileWanted(in: details, index: index, wanted: wanted) },
            onSetPriority: { index, priority in setFilePriority(in: details, index: index, priority: priority) },
            onSetAllWanted: { wanted in setAllFiles(in: details, wanted: wanted) },
            showsControls: showsControls,
            isCompact: true,
            thumbnailInput: { thumbnailInput(for: $0, details: details) }
        )
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
                await model.setFileWanted(details.summaryFallback, fileIndices: indices, wanted: wanted, sourceID: sourceID)
            }
        }
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
            await model.setFileWanted(details.summaryFallback, fileIndices: indices, wanted: wanted, sourceID: sourceID)
        }
    }

    private func setFileWanted(in details: TorrentDetails, index: Int, wanted: Bool) {
        Task {
            await model.setFileWanted(
                details.summaryFallback,
                fileIndices: [index],
                wanted: wanted,
                sourceID: sourceID
            )
        }
    }

    private func setFilePriority(in details: TorrentDetails, index: Int, priority: Int) {
        Task {
            await model.setFilePriority(
                details.summaryFallback,
                fileIndices: [index],
                priority: priority,
                sourceID: sourceID
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
    let sourceID: UUID
    let hashString: String?
    let detailsID: Int?
    let sections: [TorrentDetailSection]
}

private struct TorrentGroupInspectorLoadInput: Equatable {
    let sourceID: UUID
    let groupID: String?
    let torrents: [TorrentSummary]
    let loadsFiles: Bool
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
