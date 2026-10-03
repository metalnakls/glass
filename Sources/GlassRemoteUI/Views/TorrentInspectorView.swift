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
    @State private var snapshot: TorrentInspectorSnapshot?
    @State private var groupDetailsError: String?

    private var selectionKey: String? {
        selectedTorrentGroup.map { "group:" + $0.id } ?? selectedTorrentHash.map { "torrent:" + $0 }
    }

    private var readyDetails: TorrentDetails? {
        guard selectedTorrentGroup == nil, let selectedTorrentHash else { return nil }
        return model.readyTorrentDetails(forHashString: selectedTorrentHash, sourceID: sourceID, including: [.files])
    }

    var body: some View {
        Group {
            if selectedTorrentHash == nil {
                ContentUnavailableView("No Torrent Selected", systemImage: "info.circle", description: Text("Select a torrent to show details."))
            } else if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = selectionError {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                        }
                        TorrentInspectorContent(model: model, platformIntegration: platformIntegration, snapshot: snapshot, fileSearchText: $fileSearchText)
                            .disabled(snapshot.sourceID != sourceID || snapshot.selectionKey != selectionKey)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectHidden(true, for: .top)
            } else if let error = selectionError {
                ContentUnavailableView("Couldn’t Load Details", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                HStack(spacing: 8) {
                    GlassActivityIndicator(label: "Loading torrent details").foregroundStyle(.secondary)
                    Text("Loading details…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: detailLoadInput) {
            guard selectedTorrentGroup == nil, let selectedTorrentHash,
                  !model.isLoadingTorrentDetails,
                  model.selectedTorrentDetails?.hashString == selectedTorrentHash else { return }
            model.setVisibleTorrentDetailSections([.files], forHashString: selectedTorrentHash, sourceID: sourceID)
            await model.loadDetailSection(.files, forHashString: selectedTorrentHash, sourceID: sourceID)
        }
        .onChange(of: readyDetails, initial: true) { _, details in
            guard let details else { return }
            snapshot = TorrentInspectorSnapshot(sourceID: sourceID, details: details, filesError: model.torrentDetailSectionErrors[.files])
        }
        .task(id: groupDetailLoadInput) {
            groupDetailsError = nil
            guard let group = selectedTorrentGroup else { return }
            do {
                let details = try await model.fetchDetails(for: group.torrents, including: [.files], sourceID: sourceID)
                guard !Task.isCancelled else { return }
                snapshot = TorrentInspectorSnapshot(sourceID: sourceID, group: group, groupDetails: Dictionary(uniqueKeysWithValues: details.map { ($0.hashString, $0) }))
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                groupDetailsError = error.localizedDescription
            }
        }
        .onChange(of: selectedTorrentHash) { _, hashString in
            if hashString == nil {
                fileSearchText = ""
                snapshot = nil
            }
        }
        .onDisappear { fileSearchText = "" }
    }

    private var selectionError: String? {
        selectedTorrentGroup == nil ? model.torrentDetailsError : groupDetailsError
    }

    private var detailLoadInput: TorrentInspectorDetailLoadInput {
        TorrentInspectorDetailLoadInput(sourceID: sourceID, hashString: selectedTorrentHash,
            detailsHash: model.selectedTorrentDetails?.hashString, isLoading: model.isLoadingTorrentDetails)
    }

    private var groupDetailLoadInput: TorrentGroupInspectorLoadInput {
        TorrentGroupInspectorLoadInput(sourceID: sourceID, groupID: selectedTorrentGroup?.id, torrents: selectedTorrentGroup?.torrents ?? [])
    }
}

private struct TorrentInspectorSnapshot {
    let sourceID: UUID
    var details: TorrentDetails? = nil
    var filesError: String? = nil
    var group: TorrentNameSequenceGroup? = nil
    var groupDetails: [String: TorrentDetails] = [:]

    var selectionKey: String {
        if let group { return "group:" + group.id }
        return "torrent:" + (details?.hashString ?? "")
    }
}

private struct TorrentInspectorContent: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let snapshot: TorrentInspectorSnapshot
    @Binding var fileSearchText: String
    private var sourceID: UUID { snapshot.sourceID }
    private var groupDetails: [String: TorrentDetails] { snapshot.groupDetails }

    private func thumbnailInput(for entry: TorrentFileBrowserEntry, details: TorrentDetails) -> TorrentThumbnailInput? {
        guard let directory = details.downloadDir,
              ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mpeg", "mpg"].contains(URL(fileURLWithPath: entry.originalPath).pathExtension.lowercased()) else { return nil }
        return TorrentThumbnailInput(sourceID: sourceID, hashString: details.hashString,
            downloadDirectory: directory, filePath: entry.originalPath, length: entry.size,
            isComplete: entry.completedBytes >= entry.size, isLocal: sourceID == model.localSourceID)
    }

    @ViewBuilder
    var body: some View {
        if let group = snapshot.group {
            groupSection(group)
        } else if let details = snapshot.details {
            VStack(alignment: .leading, spacing: 12) {
                downloadLocation(details)
                Divider()
                Text("Files")
                    .font(.headline)
                if let error = snapshot.filesError, details.files.isEmpty {
                    detailErrorView(error)
                } else {
                    filesBrowser(details)
                }
            }
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
    let detailsHash: String?
    let isLoading: Bool
}

private struct TorrentGroupInspectorLoadInput: Equatable {
    let sourceID: UUID
    let groupID: String?
    let torrents: [TorrentSummary]
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
