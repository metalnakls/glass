import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct TorrentInspectorView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let sourceID: UUID
    let selectedTorrentHash: String?
    let selectedTorrentGroup: TorrentNameSequenceGroup?
    var isVisible = true
    @State private var fileSearchText = ""
    @State private var snapshot: TorrentInspectorSnapshot?
    @State private var editSession = TorrentFileEditSession()
    @State private var groupDetailsError: String?
    @State private var snapshots: [String: TorrentInspectorSnapshot] = [:]
    @State private var waitingExpired = false
    @AppearanceStorage("GlassInspector.blurEnabled") private var blurEnabled = false
    @AppearanceStorage("GlassInspector.blurRadius") private var blurRadius = 6.0
    @AppearanceStorage("GlassInspector.blurEaseIn") private var blurEaseIn = 0.25
    @AppearanceStorage("GlassInspector.blurEaseOut") private var blurEaseOut = 0.35
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var requestKey: String { sourceID.uuidString + ":" + (selectionKey ?? "none") }
    private var waitingForSelection: Bool {
        selectionKey != nil && (snapshot?.sourceID != sourceID || snapshot?.selectionKey != selectionKey)
    }

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
                TorrentInspectorContent(model: model, platformIntegration: platformIntegration, snapshot: snapshot, fileSearchText: $fileSearchText, editSession: editSession, commandsEnabled: isVisible && !waitingForSelection, onApply: { wanted in Task { await applyFileEdits(selectionWanted: wanted) } })
                    .allowsHitTesting(snapshot.sourceID == sourceID && snapshot.selectionKey == selectionKey)
                    .accessibilityHidden(snapshot.sourceID != sourceID || snapshot.selectionKey != selectionKey)
            } else if selectionKey == nil {
                ContentUnavailableView(glassText("No Torrent Selected"), systemImage: "info.circle", description: Text(glassText("Select a torrent to show details.")))
            } else if waitingExpired, let error = selectionError {
                ContentUnavailableView(glassText("Couldn’t Load Details"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                Color.clear
            }
        }
        .blur(radius: blurEnabled && waitingForSelection && !reduceMotion ? max(0, blurRadius) : 0)
        .animation(!blurEnabled || reduceMotion ? nil : .easeInOut(duration: waitingForSelection ? max(0, blurEaseIn) : max(0, blurEaseOut)), value: waitingForSelection)
        .overlay(alignment: .topTrailing) {
            if waitingForSelection && waitingExpired {
                HStack(spacing: 8) {
                    GlassActivityIndicator(label: LocalizedStringKey(glassText("Loading torrent details")))
                    if let error = selectionError { Text(glassText(error)).font(.caption).lineLimit(2) }
                }
                .foregroundStyle(.secondary)
                .padding(18)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: snapshot?.selectionKey) { _, _ in editSession.reset() }
        .task(id: detailLoadInput) {
            guard isVisible, selectedTorrentGroup == nil, let selectedTorrentHash,
                  !model.isLoadingTorrentDetails,
                  model.selectedTorrentDetails?.hashString == selectedTorrentHash else { return }
            model.setVisibleTorrentDetailSections([.files], forHashString: selectedTorrentHash, sourceID: sourceID)
            await model.loadDetailSection(.files, forHashString: selectedTorrentHash, sourceID: sourceID)
        }
        .task(id: isVisible) {
            guard selectedTorrentGroup == nil, let selectedTorrentHash else { return }
            model.setVisibleTorrentDetailSections(isVisible ? [.files] : [], forHashString: selectedTorrentHash, sourceID: sourceID)
            if isVisible { await model.loadDetailSection(.files, forHashString: selectedTorrentHash, sourceID: sourceID) }
        }
        .onChange(of: requestKey, initial: true) { _, key in
            waitingExpired = false
            if let cached = snapshots[key] { snapshot = cached }
        }
        .onChange(of: readyDetails, initial: true) { _, details in
            guard let details, model.torrentDetailSectionErrors[.files] == nil else { return }
            confirmFileEdits(details)
            present(TorrentInspectorSnapshot(sourceID: sourceID, details: details, filesError: model.torrentDetailSectionErrors[.files]))
        }
        .task(id: groupDetailLoadInput) {
            groupDetailsError = nil
            guard isVisible, model.isApplicationActive, let group = selectedTorrentGroup else { return }
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
                        if group.torrents.allSatisfy({ byHash[$0.hashString] != nil }) {
                            present(TorrentInspectorSnapshot(sourceID: sourceID, group: group, groupDetails: byHash))
                        }
                    }
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    groupDetailsError = error.localizedDescription
                    // Keep the last complete content while the selected item is unavailable.
                }
                do { try await Task.sleep(for: model.currentAutoRefreshInterval) }
                catch { return }
            }
        }
        .task(id: requestKey) {
            waitingExpired = false
            if selectionKey == nil {
                // Ignore the brief deselection produced by a native row change.
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !Task.isCancelled else { return }
                fileSearchText = ""
                snapshot = nil
            } else {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled, waitingForSelection else { return }
                waitingExpired = true
            }
        }
        .onDisappear { fileSearchText = "" }
    }

    private func present(_ next: TorrentInspectorSnapshot) {
        guard next.sourceID == sourceID, next.selectionKey == selectionKey else { return }
        snapshots[requestKey] = next
        if snapshots.count > 16 {
            for key in snapshots.keys.sorted() where key != requestKey {
                snapshots.removeValue(forKey: key)
                if snapshots.count <= 16 { break }
            }
        }
        snapshot = next
        waitingExpired = false
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
                let indices = pending.filter { $0.value == value && !TorrentFileCompletion.isComplete(detail, index: $0.key) }.map(\.key)
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
        for index in details.files.indices where TorrentFileCompletion.isComplete(details, index: index) {
            editSession.wanted[details.hashString]?[index] = nil
            editSession.selections[details.hashString]?.remove(index)
        }
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
            revision: model.fileMutationRevision, isActive: model.isApplicationActive && isVisible)
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
    let commandsEnabled: Bool
    let onApply: (Bool?) -> Void
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let fileLayout = TorrentFileListLayout.inspector
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
        Group {
            if let details = snapshot.details, snapshot.group == nil,
               details.files.count == 1, let entry = fileEntries(for: details).first {
                    TorrentSingleFilePreview(name: entry.displayName, size: entry.size, input: thumbnailInput(for: entry, details: details), onOpen: entry.isComplete ? {
                        let row = TorrentFileTreeRow(id: entry.originalPath, name: entry.displayName, depth: 0, indices: [entry.index], size: entry.size, entry: entry)
                        performFileAction(row, details: details, action: .open)
                    } : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                filesScrollView
            }
        }
        .overlay(alignment: .topLeading) { topDock }
        .overlay(alignment: .bottom) { bottomDock }
        .focusedSceneValue(\.glassInspectorSearchPresented, commandsEnabled ? $searchPresented : nil)
        .onChange(of: supportsSearch) { _, supported in
            if !supported { searchPresented = false; fileSearchText = "" }
        }
        .onChange(of: searchPresented) { _, presented in
            searchFocused = presented
            if !presented { fileSearchText = "" }
        }
    }

    private var filesScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let group = snapshot.group {
                    ForEach(group.torrents, id: \.hashString) { torrent in
                        if let details = groupDetails[torrent.hashString] {
                            Section {
                                filesBrowser(details, showsControls: false)
                                    .padding(.bottom, 16)
                            } header: {
                                HStack {
                                    Text(groupMemberName(torrent, group: group)).textCase(nil).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(formatPercent(members.first { $0.hashString == torrent.hashString }?.percentDone ?? torrent.percentDone)).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.leading, fileLayout.textLeadingInset)
                                .padding(.trailing, fileLayout.outerInset)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .glassTextStyle()
                                .zIndex(1)
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
        .contentMargins(.top, InspectorGlassPill.height + 34, for: .scrollContent)
        .contentMargins(.bottom, footerHeight, for: .scrollContent)
        .scrollEdgeEffectHidden()
    }

    @Namespace private var footerGlassNamespace

    private var topDock: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 16) {
                if let first = members.first {
                    TorrentDownloadLocationView(directory: first.downloadDir, itemPath: first.name,
                        sourceID: sourceID, isLocal: sourceID == model.localSourceID,
                        localName: model.localSourceName, serverName: model.sourceName(for: sourceID),
                        availableBytes: model.serverFreeSpace[sourceID]?.availableBytes,
                        torrentErrors: snapshot.group.map { group in
                            TorrentNameSequenceGroup(id: group.id, displayName: group.displayName, torrents: members).locationErrors
                        } ?? members.compactMap { $0.errorString }.filter { !$0.isEmpty },
                        platformIntegration: platformIntegration, glassPills: true, showsCapacity: false)
                }
            }
            .padding(.horizontal, fileLayout.outerInset)
            .padding(.top, 18).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var supportsSearch: Bool { snapshot.group != nil || (snapshot.details?.files.count ?? 0) > 1 }

    private var footerHeight: CGFloat { InspectorGlassPill.height + 38 }

    private var bottomDock: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if editSession.hasSelection {
                    Button { onApply(true) } label: { Text(glassText("Download")).frame(maxWidth: .infinity) }
                        .buttonStyle(.plain).modifier(InspectorGlassPill(interactive: true))
                        .glassEffectID("primary", in: footerGlassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                    Button { onApply(false) } label: { Text(glassText("Skip")).frame(maxWidth: .infinity) }
                        .buttonStyle(.plain).modifier(InspectorGlassPill(interactive: true, tint: .red))
                        .glassEffectID("secondary", in: footerGlassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                } else if editSession.hasChanges {
                    Button { onApply(nil) } label: { Text(glassText("Apply")).frame(maxWidth: .infinity) }
                        .buttonStyle(.plain).modifier(InspectorGlassPill(interactive: true))
                } else {
                    if !searchPresented || !supportsSearch {
                        TorrentInspectorProgressView(progress: TorrentInspectorProgress(torrents: members))
                            .modifier(InspectorGlassPill())
                            .glassEffectID("primary", in: footerGlassNamespace)
                            .glassEffectTransition(.matchedGeometry)
                            .contextMenu { TorrentTransferInfoMenu(model: model, sourceID: sourceID, torrents: members) }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    if supportsSearch {
                        GlassSearchPill(text: $fileSearchText, isPresented: $searchPresented, transitionNamespace: footerGlassNamespace, transitionID: searchPresented ? "primary" : "secondary")
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .controlSize(.large)
            .padding(.horizontal, fileLayout.outerInset)
            .padding(.top, 22).padding(.bottom, 16)

            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: searchPresented)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: editSession.hasSelection)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: editSession.hasChanges)
            .disabled(editSession.isApplying)
        }
    }

    private func selectAllFiles() {
        for details in selectedDetails {
            editSession.selections[details.hashString] = Set(fileEntries(for: details).filter {
                !$0.isComplete && (fileSearchText.isEmpty || $0.displayName.localizedCaseInsensitiveContains(fileSearchText) || $0.originalPath.localizedCaseInsensitiveContains(fileSearchText))
            }.map(\.index))
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
            onSelectAll: { if commandsEnabled { selectAllFiles() } },
            onSetPriorities: { indices, priority in
                await model.setFilePriority(details.summaryFallback, fileIndices: indices, priority: priority, sourceID: sourceID)
            },
            sizeColumnText: widestFileSize,
            onSetWantedAsync: { index, wanted in
                await model.setFileWanted(details.summaryFallback, fileIndices: [index], wanted: wanted, sourceID: sourceID)
            }
        )
        .id(details.hashString)
        .padding(.horizontal, fileLayout.contentInset)
    }

    private var widestFileSize: String {
        selectedDetails.flatMap { fileEntries(for: $0) }.map { formatBytes($0.size) }.max {
            $0.size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width < $1.size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
        } ?? "0 KB"
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
