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
    @State private var editSession = TorrentFileEditSession()
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
            if let snapshot {
                TorrentInspectorContent(model: model, platformIntegration: platformIntegration, snapshot: snapshot, fileSearchText: $fileSearchText, editSession: editSession)
                    .allowsHitTesting(snapshot.sourceID == sourceID && snapshot.selectionKey == selectionKey)
                    .accessibilityHidden(snapshot.sourceID != sourceID || snapshot.selectionKey != selectionKey)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
            } else if selectedTorrentHash == nil {
                ContentUnavailableView("No Torrent Selected", systemImage: "info.circle", description: Text("Select a torrent to show details."))
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
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            if editSession.hasSelection || editSession.hasChanges {
                VStack(spacing: 8) {
                    if editSession.hasSelection {
                        HStack(spacing: 8) {
                            Button { Task { await applyFileEdits(selectionWanted: true) } } label: {
                                Text("Download").frame(maxWidth: .infinity)
                            }.buttonStyle(.glassProminent)
                            Button { Task { await applyFileEdits(selectionWanted: false) } } label: {
                                Text("Skip").frame(maxWidth: .infinity)
                            }.buttonStyle(.glassProminent).tint(.red)
                        }
                    } else if editSession.hasChanges {
                        Button { Task { await applyFileEdits() } } label: {
                            Text("Apply").frame(maxWidth: .infinity)
                        }.buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 16)
                .background {
                    Rectangle().fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.45),
                            .init(color: .black, location: 1)
                        ], startPoint: .top, endPoint: .bottom))
                        .padding(.top, -24)
                        .allowsHitTesting(false)
                }

                .disabled(editSession.isApplying || snapshot?.selectionKey != selectionKey)
            }
        }
        .onChange(of: snapshot?.selectionKey) { _, _ in editSession.reset() }
        .task(id: detailLoadInput) {
            guard selectedTorrentGroup == nil, let selectedTorrentHash,
                  !model.isLoadingTorrentDetails,
                  model.selectedTorrentDetails?.hashString == selectedTorrentHash else { return }
            model.setVisibleTorrentDetailSections([.files], forHashString: selectedTorrentHash, sourceID: sourceID)
            await model.loadDetailSection(.files, forHashString: selectedTorrentHash, sourceID: sourceID)
        }
        .onChange(of: selectionKey, initial: true) { _, _ in
            if let group = selectedTorrentGroup {
                snapshot = TorrentInspectorSnapshot(sourceID: sourceID, group: group)
            } else if let hash = selectedTorrentHash,
                      let summary = model.allTorrentRecords.first(where: { $0.sourceID == sourceID && $0.hashString == hash })?.summary {
                snapshot = TorrentInspectorSnapshot(sourceID: sourceID, details: TorrentDetails(
                    id: summary.id, hashString: hash, name: summary.name, percentDone: summary.percentDone,
                    sizeWhenDone: summary.sizeWhenDone, downloadDir: summary.downloadDir))
            }
        }
        .onChange(of: readyDetails, initial: true) { _, details in
            guard let details else { return }
            confirmFileEdits(details)
            snapshot = TorrentInspectorSnapshot(sourceID: sourceID, details: details, filesError: model.torrentDetailSectionErrors[.files])
        }
        .task(id: groupDetailLoadInput) {
            groupDetailsError = nil
            guard model.isApplicationActive, let group = selectedTorrentGroup else { return }
            // Live summary changes update the progress labels, not the lifetime
            // of this request. Fetch file telemetry on a deliberate cadence.
            while !Task.isCancelled {
                do {
                    let details = try await model.fetchDetails(for: group.torrents, including: [.files], sourceID: sourceID)
                    guard !Task.isCancelled else { return }
                    for detail in details { confirmFileEdits(detail) }
                    groupDetailsError = nil
                    let byHash = Dictionary(uniqueKeysWithValues: details.map { ($0.hashString, $0) })
                    if snapshot?.sourceID != sourceID || snapshot?.group?.id != group.id
                        || snapshot?.group?.displayName != group.displayName || snapshot?.groupDetails != byHash {
                        snapshot = TorrentInspectorSnapshot(sourceID: sourceID, group: group, groupDetails: byHash)
                    }
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    groupDetailsError = error.localizedDescription
                    snapshot?.filesError = error.localizedDescription
                }
                do { try await Task.sleep(for: model.currentAutoRefreshInterval) }
                catch { return }
            }
        }
        .task(id: selectionKey) {
            guard selectionKey == nil else { return }
            // A native list can briefly clear selection while moving between rows.
            // Only clear a settled deselection; a new selection cancels this task.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            fileSearchText = ""
            snapshot = nil
        }
        .onDisappear { fileSearchText = "" }
    }

    private func applyFileEdits(selectionWanted: Bool? = nil) async {
        guard let snapshot, snapshot.selectionKey == selectionKey else { return }
        let changes: [String: [Int: Bool]]
        if let selectionWanted {
            changes = editSession.selections.mapValues { indices in
                Dictionary(uniqueKeysWithValues: indices.map { ($0, selectionWanted) })
            }
        } else { changes = editSession.wanted }
        let details = snapshot.details.map { [$0] } ?? Array(snapshot.groupDetails.values)
        editSession.isApplying = true
        defer { editSession.isApplying = false }
        for detail in details {
            guard let pending = changes[detail.hashString] else { continue }
            for value in [true, false] {
                let indices = pending.filter { $0.value == value }.map(\.key)
                guard !indices.isEmpty else { continue }
                await model.setFileWanted(detail.summaryFallback, fileIndices: indices, wanted: value, sourceID: snapshot.sourceID)
                guard model.errorMessage == nil else { return }
                for index in indices { editSession.wanted[detail.hashString]?[index] = nil }
            }
        }
        if selectionWanted != nil { editSession.selections = [:] }
    }

    private func confirmFileEdits(_ details: TorrentDetails) {
        let values = Dictionary(uniqueKeysWithValues: details.fileStats.enumerated().compactMap { index, stats in
            stats.wanted.map { (index, $0) }
        })
        editSession.confirm(values, for: details.hashString)
    }

    private var selectionError: String? {
        selectedTorrentGroup == nil ? model.torrentDetailsError : groupDetailsError
    }

    private var detailLoadInput: TorrentInspectorDetailLoadInput {
        TorrentInspectorDetailLoadInput(sourceID: sourceID, hashString: selectedTorrentHash,
            detailsHash: model.selectedTorrentDetails?.hashString, isLoading: model.isLoadingTorrentDetails)
    }

    private var groupDetailLoadInput: TorrentGroupInspectorLoadInput {
        TorrentGroupInspectorLoadInput(sourceID: sourceID, group: selectedTorrentGroup,
            revision: model.fileMutationRevision, isActive: model.isApplicationActive)
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
    let editSession: TorrentFileEditSession
    private var sourceID: UUID { snapshot.sourceID }
    private var groupDetails: [String: TorrentDetails] { snapshot.groupDetails }

    private func thumbnailInput(for entry: TorrentFileBrowserEntry, details: TorrentDetails) -> TorrentThumbnailInput? {
        guard let directory = details.downloadDir,
              ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mpeg", "mpg"].contains(URL(fileURLWithPath: entry.originalPath).pathExtension.lowercased()) else { return nil }
        return TorrentThumbnailInput(sourceID: sourceID, hashString: details.hashString,
            downloadDirectory: directory, filePath: entry.originalPath, length: entry.size,
            isComplete: entry.completedBytes >= entry.size, isLocal: sourceID == model.localSourceID)
    }

    private var members: [TorrentSummary] {
        let fallback = snapshot.group?.torrents ?? snapshot.details.map { [$0.summaryFallback] } ?? []
        let live = Dictionary(uniqueKeysWithValues: model.allTorrentRecords.filter { $0.sourceID == sourceID }.map { ($0.hashString, $0.summary) })
        return fallback.map { live[$0.hashString] ?? $0 }
    }

    private var selectedDetails: [TorrentDetails] {
        if let group = snapshot.group { return group.torrents.compactMap { groupDetails[$0.hashString] } }
        return snapshot.details.map { [$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let first = members.first {
                TorrentDownloadLocationView(directory: first.downloadDir, itemPath: first.name,
                    sourceID: sourceID, isLocal: sourceID == model.localSourceID,
                    localName: model.localSourceName, serverName: model.sourceName(for: sourceID),
                    availableBytes: model.serverFreeSpace[sourceID]?.availableBytes,
                    torrentErrors: members.compactMap { $0.errorString }.filter { !$0.isEmpty },
                    platformIntegration: platformIntegration)
            }
            TorrentInspectorProgressView(progress: TorrentInspectorProgress(torrents: members))
            Divider()
            HStack(spacing: 8) {
                Toggle("Download all files", isOn: Binding(get: {
                    !selectedDetails.isEmpty && selectedDetails.allSatisfy { details in
                        !details.files.isEmpty && details.files.indices.allSatisfy { index in
                            editSession.wanted[details.hashString]?[index] ?? (details.fileStats.indices.contains(index) ? details.fileStats[index].wanted ?? true : true)
                        }
                    }
                }, set: { value in
                    for details in selectedDetails {
                        let current = Dictionary(uniqueKeysWithValues: details.files.indices.map { index in
                            (index, details.fileStats.indices.contains(index) ? details.fileStats[index].wanted ?? true : true)
                        })
                        editSession.stageAll(value, current: current, for: details.hashString)
                    }
                })).labelsHidden().toggleStyle(.checkbox).controlSize(.regular)
                TextField("Search Files", text: $fileSearchText)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .focusedValue(\.glassInspectorFileFilterFocused, true)
            }
            .padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let group = snapshot.group {
                        ForEach(group.torrents, id: \.hashString) { torrent in
                            if let details = groupDetails[torrent.hashString] {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(groupMemberName(torrent, group: group)).font(.subheadline.weight(.semibold))
                                    filesBrowser(details, showsControls: false)
                                }
                            }
                        }
                        if groupDetails.isEmpty {
                            if let error = snapshot.filesError { detailErrorView(error) }
                            else { GlassActivityIndicator(label: "Loading files") }
                        }
                    } else if let details = snapshot.details {
                        if let error = snapshot.filesError, details.files.isEmpty { detailErrorView(error) }
                        else { filesBrowser(details, showsControls: false) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)
            }
            .contentMargins(.bottom, editSession.hasSelection || editSession.hasChanges ? 84 : 0, for: .scrollContent)
            .scrollEdgeEffectHidden(true, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
    }

    private func filesBrowser(_ details: TorrentDetails, showsControls: Bool = true) -> some View {
        TorrentFilesBrowser(
            entries: fileEntries(for: details),
            searchText: $fileSearchText,
            onSetWanted: { index, wanted in setFileWanted(in: details, index: index, wanted: wanted) },
            onSetPriority: { index, priority in setFilePriority(in: details, index: index, priority: priority) },
            onSetAllWanted: { wanted in setAllFiles(in: details, wanted: wanted) },
            onFileAction: { row, action in performFileAction(row, details: details, action: action) },
            showsControls: showsControls,
            isCompact: true,
            shortEpisodeNames: true,
            stagesChanges: true,
            onApplyWanted: { changes in
                Task {
                    for wanted in [true, false] {
                        let indices = changes.filter { $0.value == wanted }.map(\.key)
                        if !indices.isEmpty {
                            await model.setFileWanted(details.summaryFallback, fileIndices: indices, wanted: wanted, sourceID: sourceID)
                        }
                    }
                }
            },
            onSmartRename: { Task { await model.smartRename(details, sourceID: sourceID) } },
            editSession: editSession,
            editID: details.hashString,
            showsActionBar: false,
            onSetPriorities: { indices, priority in
                await model.setFilePriority(details.summaryFallback, fileIndices: indices, priority: priority, sourceID: sourceID)
            }
        )
        .id(details.hashString)
    }

    private func performFileAction(_ row: TorrentFileTreeRow, details: TorrentDetails, action: TorrentFileActions.Action) {
        guard let directory = details.downloadDir else { return }
        let entries = fileEntries(for: details)
        guard let entry = row.entry ?? entries.first(where: { row.indices.contains($0.index) }) else { return }
        let path: String
        if row.isFolder {
            // Smart names are presentation-only; preserve the original disk path.
            let displayDepth = entry.displayName.split(separator: "/").count
            let original = entry.originalPath.split(separator: "/")
            let hiddenParents = max(0, original.count - displayDepth)
            path = original.prefix(hiddenParents + row.depth + 1).joined(separator: "/")
        } else { path = entry.originalPath }
        Task {
            do { try await TorrentFileActions.shared.perform(action, sourceID: sourceID, directory: directory, path: path, isLocal: sourceID == model.localSourceID) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func groupMemberName(_ torrent: TorrentSummary, group: TorrentNameSequenceGroup) -> String {
        if let season = TorrentNameCleaner.seasonDescriptor(for: TorrentBatchNamingInput(rootName: torrent.name, files: groupDetails[torrent.hashString]?.files ?? []))?.season {
            return "Season \(season)"
        }
        let suffix = torrent.name.replacingOccurrences(of: group.displayName, with: "").trimmingCharacters(in: .whitespaces)
        if let season = Int(suffix) { return "Season \(season)" }
        return torrent.name
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
        let root = TorrentFileBrowserEntry.commonRoot(paths: details.files.map(\.name)) ?? details.name
        return details.files.enumerated().map { index, file in
            let stats = details.fileStats.indices.contains(index) ? details.fileStats[index] : nil
            return TorrentFileBrowserEntry(
                index: index,
                file: file,
                rootName: root,
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

struct TorrentGroupInspectorLoadInput: Equatable {
    struct Member: Equatable {
        let hashString: String
        let name: String
        let directory: String?
    }
    let sourceID: UUID
    let groupID: String?
    let displayName: String?
    let members: [Member]
    let revision: Int
    let isActive: Bool

    init(sourceID: UUID, group: TorrentNameSequenceGroup?, revision: Int, isActive: Bool) {
        self.sourceID = sourceID
        groupID = group?.id
        displayName = group?.displayName
        members = group?.torrents.map { Member(hashString: $0.hashString, name: $0.name, directory: $0.downloadDir) } ?? []
        self.revision = revision
        self.isActive = isActive
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
