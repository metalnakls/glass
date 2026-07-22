import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import UniformTypeIdentifiers

public struct GlassRootView: View {
    private let model: RemoteAppModel
    private let platformIntegration: any GlassPlatformIntegrating

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("GlassRoot.columnVisibility") private var storedColumnVisibility = "automatic"
    @AppStorage("GlassRoot.selectedSourceID") private var storedSelectedSourceID = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var didRestoreColumnVisibility = false
    @State private var selectedTorrentHash: String?
    @State private var isFileImporterPresented = false
    @State private var activeSheet: ActiveSheet?
    @State private var pendingTorrentFileDrafts: [TorrentFileAddDraft] = []
    @State private var pendingProfileDeletion: RemoteProfile?
    @State private var pendingRenames: [PendingRemovalKey: PendingTorrentRename] = [:]
    @State private var pendingRemovals: [PendingTorrentRemoval] = []
    @State private var pendingRemovalResetToken = UUID()
    @State private var committingRemovalKeys = Set<PendingRemovalKey>()
    @State private var pendingRemovalTask: Task<Void, Never>?

    public init(
        model: RemoteAppModel,
        platformIntegration: any GlassPlatformIntegrating = UnavailableGlassPlatformIntegration.shared
    ) {
        self.model = model
        self.platformIntegration = platformIntegration
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProfileSidebarView(
                model: model,
                selection: Binding(
                    get: { model.selectedProfileID },
                    set: { model.selectedProfileID = $0 }
                ),
                editProfile: { activeSheet = .editProfile($0) },
                deleteProfile: { pendingProfileDeletion = $0 }
            )
        } detail: {
            TorrentWorkspaceView(
                model: model,
                platformIntegration: platformIntegration,
                selection: $selectedTorrentHash,
                pendingRenames: pendingRenames,
                pendingRemovals: pendingRemovals,
                committingRemovalKeys: committingRemovalKeys,
                pendingRemovalResetToken: pendingRemovalResetToken,
                pendingRemovalDuration: pendingRemovalDuration,
                rename: beginRename,
                remove: scheduleRemoval,
                removeSelected: removeSelectedTorrent,
                openURLs: openURLs,
                openMagnet: { activeSheet = .addMagnet($0) },
                undoRemovals: cancelPendingRemovals,
                dismissRemovals: dismissPendingRemovals
            )
        }
        .toolbar(id: "Glass.main") {
            ToolbarSpacer(.flexible)

            ToolbarItem(id: "downloadingFilter", placement: .primaryAction) {
                Toggle(isOn: downloadingFilterBinding) {
                    Label(
                        isDownloadingFilterActive ? "Show All Torrents" : "Show Downloading Torrents",
                        systemImage: isDownloadingFilterActive
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .toggleStyle(.button)
                .buttonBorderShape(.circle)
                .labelStyle(.iconOnly)
                .help(isDownloadingFilterActive ? "Show All Torrents" : "Show Downloading Torrents")
            }
            .visibilityPriority(.high)
        }
        .inspector(isPresented: .constant(true)) {
            TorrentInspectorView(model: model, selectedTorrentHash: selectedTorrentHash)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
        }
        .sheet(item: $activeSheet, onDismiss: presentNextTorrentFileDraftIfNeeded) { sheet in
            NavigationStack {
                switch sheet {
                case .newProfile:
                    ProfileEditorView(model: model, profile: nil)
                case let .editProfile(profile):
                    ProfileEditorView(model: model, profile: profile)
                case let .addMagnet(magnet):
                    AddMagnetView(model: model, platformIntegration: platformIntegration, magnet: magnet)
                case let .addTorrentFile(draft):
                    AddTorrentFileView(
                        model: model,
                        platformIntegration: platformIntegration,
                        draft: draft,
                        submit: { sourceID, name, downloadDirectory, fileSelection, namingPlan in
                            await submitTorrentFile(
                                draft,
                                sourceID: sourceID,
                                name: name,
                                downloadDirectory: downloadDirectory,
                                fileSelection: fileSelection,
                                namingPlan: namingPlan
                            )
                        }
                    )
                case let .renameTorrent(torrent):
                    RenameTorrentView(torrent: torrent) { newName in
                        submitRename(torrent, newName: newName)
                    }
                }
            }
            .presentationSizing(.form)
        }
        .alert(activeAlertTitle, isPresented: activeAlertBinding, presenting: activeAlert) { alert in
            switch alert {
            case let .deleteProfile(profile):
                Button("Delete", role: .destructive) {
                    model.deleteProfile(profile)
                }
                Button("Cancel", role: .cancel) {}
            case .error:
                Button("OK") {}
            }
        } message: { alert in
            switch alert {
            case let .deleteProfile(profile):
                Text("Remove \(profile.name) from Glass. Transmission data on the server is not changed.")
            case let .error(message):
                Text(message)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.torrentFile],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                openURLs(urls)
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .task {
            restoreColumnVisibilityIfNeeded()
            persistSelectedSourceID()
            model.setApplicationActive(scenePhase == .active)
            let registrationID = GlassOpenURLRouter.shared.register { urls in
                openURLs(urls)
            }
            defer { GlassOpenURLRouter.shared.unregister(registrationID) }
            await model.runAutoRefresh()
        }
        .onChange(of: model.selectedProfileID) { _, _ in
            persistSelectedSourceID()
            selectedTorrentHash = nil
            Task { await model.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(phase == .active)
        }
        .onChange(of: columnVisibility) { _, visibility in
            storedColumnVisibility = key(for: visibility)
        }
        .onChange(of: selectedTorrentHash) { _, _ in
            Task { await loadSelectedTorrentDetails() }
        }
        .focusedSceneValue(\.glassCommandActions, commandActions)
    }

    private var selectedTorrent: TorrentSummary? {
        guard let selectedTorrentHash else { return nil }
        return model.filteredTorrents.first { $0.hashString == selectedTorrentHash }
    }

    private var commandActions: GlassCommandActions {
        GlassCommandActions(
            addServer: { activeSheet = .newProfile },
            addMagnet: { activeSheet = .addMagnet("") },
            addTorrentFile: { isFileImporterPresented = true },
            openMagnet: { activeSheet = .addMagnet($0) },
            toggleDownloadingFilter: toggleDownloadingFilter,
            isDownloadingFilterActive: model.selectedTorrentGroup == .downloading,
            canRemoveSelectedTorrent: selectedTorrentHash != nil && activeSheet == nil && activeAlert == nil,
            removeSelectedTorrent: removeSelectedTorrent
        )
    }

    private var activeAlertBinding: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { dismissActiveAlert() } }
        )
    }

    private var activeAlert: ActiveRootAlert? {
        if let pendingProfileDeletion {
            return .deleteProfile(pendingProfileDeletion)
        }
        if let errorMessage = model.errorMessage {
            return .error(errorMessage)
        }
        return nil
    }

    private var activeAlertTitle: String {
        switch activeAlert {
        case .deleteProfile:
            return "Delete Server?"
        case .error, nil:
            return "Glass"
        }
    }

    private func dismissActiveAlert() {
        switch activeAlert {
        case .deleteProfile:
            pendingProfileDeletion = nil
        case .error:
            model.errorMessage = nil
        case nil:
            break
        }
    }

    private func toggleDownloadingFilter() {
        model.selectedTorrentGroup = model.selectedTorrentGroup == .downloading ? .all : .downloading
    }

    private var isDownloadingFilterActive: Bool {
        model.selectedTorrentGroup == .downloading
    }

    private var downloadingFilterBinding: Binding<Bool> {
        Binding(
            get: { isDownloadingFilterActive },
            set: { model.selectedTorrentGroup = $0 ? .downloading : .all }
        )
    }

    private func beginRename(_ torrent: TorrentSummary) {
        activeSheet = .renameTorrent(torrent)
    }

    private func submitRename(_ torrent: TorrentSummary, newName proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != torrent.name else { return }

        let key = PendingRemovalKey(sourceID: model.selectedSourceID, hashString: torrent.hashString)
        let pendingRename = PendingTorrentRename(
            key: key,
            oldName: torrent.name,
            newName: newName
        )
        withAnimation(motionAnimation(.snappy(duration: 0.22))) {
            pendingRenames[key] = pendingRename
        }

        Task {
            _ = await model.rename(torrent, to: newName)
            await MainActor.run {
                guard pendingRenames[key]?.id == pendingRename.id else { return }
                withAnimation(motionAnimation(.snappy(duration: 0.22))) {
                    pendingRenames[key] = nil
                }
            }
        }
    }

    private func persistSelectedSourceID() {
        storedSelectedSourceID = model.selectedSourceID.uuidString
    }

    private func restoreColumnVisibilityIfNeeded() {
        guard !didRestoreColumnVisibility else { return }
        didRestoreColumnVisibility = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            columnVisibility = visibility(for: storedColumnVisibility)
        }
    }

    private func key(for visibility: NavigationSplitViewVisibility) -> String {
        switch visibility {
        case .detailOnly:
            return "detailOnly"
        case .doubleColumn:
            return "doubleColumn"
        case .all:
            return "all"
        default:
            return "automatic"
        }
    }

    private func visibility(for key: String) -> NavigationSplitViewVisibility {
        switch key {
        case "detailOnly":
            return .detailOnly
        case "doubleColumn":
            return .doubleColumn
        case "all":
            return .all
        default:
            return .automatic
        }
    }

    private func openURLs(_ urls: [URL]) {
        var torrentFileURLs: [URL] = []
        for url in urls {
            if let magnet = magnetLink(from: url) {
                activeSheet = .addMagnet(magnet)
                continue
            }
            guard url.pathExtension.lowercased() == "torrent" else { continue }
            torrentFileURLs.append(url)
        }

        guard !torrentFileURLs.isEmpty else { return }
        Task {
            for url in torrentFileURLs {
                await prepareTorrentFile(at: url)
            }
        }
    }

    private func prepareTorrentFile(at url: URL) async {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            enqueueTorrentFileDraft(
                TorrentFileAddDraft(
                    data: data,
                    preview: TorrentFilePreview(data: data, fallbackURL: url),
                    sourceURL: url
                )
            )
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func enqueueTorrentFileDraft(_ draft: TorrentFileAddDraft) {
        guard activeSheet == nil else {
            pendingTorrentFileDrafts.append(draft)
            return
        }
        activeSheet = .addTorrentFile(draft)
    }

    private func presentNextTorrentFileDraftIfNeeded() {
        guard activeSheet == nil, !pendingTorrentFileDrafts.isEmpty else { return }
        activeSheet = .addTorrentFile(pendingTorrentFileDrafts.removeFirst())
    }

    private func submitTorrentFile(
        _ draft: TorrentFileAddDraft,
        sourceID: UUID,
        name: String,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection,
        namingPlan: TorrentAddNamingPlan?
    ) async -> Bool {
        let didAccess = draft.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                draft.sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return await model.addTorrentFile(
            draft.data,
            torrentName: name == draft.preview.name ? nil : name,
            downloadDirectory: downloadDirectory,
            fileSelection: fileSelection,
            namingPlan: namingPlan,
            sourceID: sourceID,
            sourceURL: draft.sourceURL,
            trashSourceOnSuccess: true
        )
    }

    private func loadSelectedTorrentDetails() async {
        await model.loadDetails(for: selectedTorrent)
    }

    private func removeSelectedTorrent(deleteData: Bool) {
        guard let selectedTorrent else { return }
        scheduleRemoval(selectedTorrent, deleteData: deleteData)
    }

    private func scheduleRemoval(_ torrent: TorrentSummary, deleteData: Bool) {
        let sourceID = model.selectedSourceID
        let key = PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            pendingRemovals.removeAll { $0.key == key }
            pendingRemovals.append(PendingTorrentRemoval(sourceID: sourceID, torrent: torrent, deleteData: deleteData))
            pendingRemovalResetToken = UUID()
        }

        if selectedTorrentHash == torrent.hashString {
            selectedTorrentHash = nil
        }

        pendingRemovalTask?.cancel()
        pendingRemovalTask = Task {
            do {
                try await Task.sleep(for: .seconds(pendingRemovalDuration))
            } catch {
                return
            }
            await MainActor.run {
                commitPendingRemovals()
            }
        }
    }

    private var pendingRemovalDuration: TimeInterval {
        12
    }

    private func cancelPendingRemovals() {
        let restoredSelection = pendingRemovals.last {
            $0.sourceID == model.selectedSourceID
        }?.torrent.hashString

        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            pendingRemovals = []
            if selectedTorrentHash == nil {
                selectedTorrentHash = restoredSelection
            }
        }
    }

    private func dismissPendingRemovals() {
        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        commitPendingRemovals()
    }

    private func commitPendingRemovals() {
        let removals = pendingRemovals
        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        guard !removals.isEmpty else { return }

        let keys = removals.map(\.key)
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            committingRemovalKeys.formUnion(keys)
            pendingRemovals = []
        }

        Task {
            let removalsBySource = Dictionary(grouping: removals, by: \.sourceID)
            for (sourceID, sourceRemovals) in removalsBySource {
                let keepFiles = sourceRemovals.filter { !$0.deleteData }.map(\.torrent)
                let deleteData = sourceRemovals.filter(\.deleteData).map(\.torrent)

                if !keepFiles.isEmpty {
                    _ = await model.remove(keepFiles, deleteData: false, sourceID: sourceID)
                }
                if !deleteData.isEmpty {
                    _ = await model.remove(deleteData, deleteData: true, sourceID: sourceID)
                }
            }

            await MainActor.run {
                committingRemovalKeys.subtract(keys)
            }
        }
    }

    private func motionAnimation(_ animation: Animation) -> Animation? {
        accessibilityReduceMotion ? nil : animation
    }
}

private struct TorrentWorkspaceView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isURLDropTargeted = false
    @State private var isTextDropTargeted = false
    @Binding var selection: String?
    let pendingRenames: [PendingRemovalKey: PendingTorrentRename]
    let pendingRemovals: [PendingTorrentRemoval]
    let committingRemovalKeys: Set<PendingRemovalKey>
    let pendingRemovalResetToken: UUID
    let pendingRemovalDuration: TimeInterval
    let rename: (TorrentSummary) -> Void
    let remove: (TorrentSummary, Bool) -> Void
    let removeSelected: (Bool) -> Void
    let openURLs: ([URL]) -> Void
    let openMagnet: (String) -> Void
    let undoRemovals: () -> Void
    let dismissRemovals: () -> Void

    var body: some View {
        TorrentListContent(
            model: model,
            platformIntegration: platformIntegration,
            selection: $selection,
            pendingRenames: pendingRenames,
            pendingRemovals: pendingRemovals,
            committingRemovalKeys: committingRemovalKeys,
            rename: rename,
            remove: remove,
            removeSelected: removeSelected
        )
        .navigationTitle(model.selectedSourceName)
        .navigationSubtitle(navigationSubtitle)
        .dropDestination(for: URL.self) { urls, _ in
            let supportedURLs = urls.filter(isSupportedDropURL)
            guard !supportedURLs.isEmpty else { return false }
            openURLs(supportedURLs)
            return true
        } isTargeted: { setDropTargeted($0, kind: .url) }
        .dropDestination(for: String.self) { strings, _ in
            for string in strings {
                if let magnet = normalizedMagnetLink(from: string) {
                    openMagnet(magnet)
                    return true
                }
            }
            return false
        } isTargeted: { setDropTargeted($0, kind: .text) }
        .overlay {
            if isTorrentDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)

                    Label("Drop to Add Torrent", systemImage: "doc.badge.plus")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: .capsule)
                }
                .padding(12)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if !pendingRemovals.isEmpty {
                RemovalUndoToast(
                    removals: pendingRemovals,
                    resetToken: pendingRemovalResetToken,
                    duration: pendingRemovalDuration,
                    undo: undoRemovals,
                    dismiss: dismissRemovals
                )
                .padding(.horizontal, 16)
                .transition(
                    accessibilityReduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }
        }
    }

    private var navigationSubtitle: String {
        if let freeSpace = model.serverFreeSpace[model.selectedSourceID]?.availableBytes {
            return "\(formatBytes(freeSpace)) free"
        }
        if model.isLocalSourceSelected {
            return "Local downloads on this Mac"
        }
        return model.selectedSourceRPCURL.host(percentEncoded: false) ?? model.selectedSourceRPCURL.absoluteString
    }

    private func isSupportedDropURL(_ url: URL) -> Bool {
        magnetLink(from: url) != nil || url.pathExtension.localizedCaseInsensitiveCompare("torrent") == .orderedSame
    }

    private var isTorrentDropTargeted: Bool {
        isURLDropTargeted || isTextDropTargeted
    }

    private func setDropTargeted(_ isTargeted: Bool, kind: DropKind) {
        withAnimation(.easeOut(duration: 0.16)) {
            switch kind {
            case .url:
                isURLDropTargeted = isTargeted
            case .text:
                isTextDropTargeted = isTargeted
            }
        }
    }

    private enum DropKind {
        case url
        case text
    }
}

private struct TorrentListContent: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Binding var selection: String?
    let pendingRenames: [PendingRemovalKey: PendingTorrentRename]
    let pendingRemovals: [PendingTorrentRemoval]
    let committingRemovalKeys: Set<PendingRemovalKey>
    let rename: (TorrentSummary) -> Void
    let remove: (TorrentSummary, Bool) -> Void
    let removeSelected: (Bool) -> Void

    init(
        model: RemoteAppModel,
        platformIntegration: any GlassPlatformIntegrating,
        selection: Binding<String?>,
        pendingRenames: [PendingRemovalKey: PendingTorrentRename],
        pendingRemovals: [PendingTorrentRemoval],
        committingRemovalKeys: Set<PendingRemovalKey>,
        rename: @escaping (TorrentSummary) -> Void,
        remove: @escaping (TorrentSummary, Bool) -> Void,
        removeSelected: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.platformIntegration = platformIntegration
        _selection = selection
        self.pendingRenames = pendingRenames
        self.pendingRemovals = pendingRemovals
        self.committingRemovalKeys = committingRemovalKeys
        self.rename = rename
        self.remove = remove
        self.removeSelected = removeSelected
    }

    var body: some View {
        TorrentListView(
            model: model,
            platformIntegration: platformIntegration,
            sourceID: model.selectedSourceID,
            records: visibleRecords,
            structureRevision: model.torrentStructureRevision,
            pendingRenameNames: pendingRenameNames,
            pendingRenameOldNames: pendingRenameOldNames,
            selection: $selection,
            rename: rename,
            remove: remove,
            removeSelected: removeSelected
        )
    }

    private var visibleRecords: [TorrentRecord] {
        let sourceID = model.selectedSourceID
        let hiddenKeys = Set(pendingRemovals.map(\.key)).union(committingRemovalKeys)
        return model.torrentRecords.filter { record in
            let isIncluded: Bool
            switch model.selectedTorrentGroup {
            case .all:
                isIncluded = true
            case .downloading:
                isIncluded = record.isDownloading
            case .completed:
                isIncluded = record.isCompleted
            }
            guard isIncluded else { return false }
            let key = PendingRemovalKey(sourceID: sourceID, hashString: record.hashString)
            return !hiddenKeys.contains(key)
        }
    }

    private var pendingRenameNames: [String: String] {
        Dictionary(uniqueKeysWithValues: pendingRenames.values.compactMap { pendingRename in
            guard pendingRename.key.sourceID == model.selectedSourceID else { return nil }
            return (pendingRename.key.hashString, pendingRename.newName)
        })
    }

    private var pendingRenameOldNames: [String: String] {
        Dictionary(uniqueKeysWithValues: pendingRenames.values.compactMap { pendingRename in
            guard pendingRename.key.sourceID == model.selectedSourceID else { return nil }
            return (pendingRename.key.hashString, pendingRename.oldName)
        })
    }
}

private enum ActiveSheet: Identifiable {
    case newProfile
    case editProfile(RemoteProfile)
    case addMagnet(String)
    case addTorrentFile(TorrentFileAddDraft)
    case renameTorrent(TorrentSummary)

    var id: String {
        switch self {
        case .newProfile:
            return "new-profile"
        case let .editProfile(profile):
            return "edit-profile-\(profile.id.uuidString)"
        case let .addMagnet(magnet):
            return "add-magnet-\(magnet)"
        case let .addTorrentFile(draft):
            return "add-torrent-file-\(draft.id.uuidString)"
        case let .renameTorrent(torrent):
            return "rename-torrent-\(torrent.hashString)"
        }
    }
}

private enum ActiveRootAlert {
    case deleteProfile(RemoteProfile)
    case error(String)
}

struct PendingRemovalKey: Hashable {
    let sourceID: UUID
    let hashString: String
}

struct PendingTorrentRename: Identifiable, Equatable {
    let id = UUID()
    let key: PendingRemovalKey
    let oldName: String
    let newName: String
}

struct PendingTorrentRemoval: Identifiable, Equatable {
    let sourceID: UUID
    let torrent: TorrentSummary
    let deleteData: Bool

    var key: PendingRemovalKey {
        PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
    }

    var id: String {
        "\(sourceID.uuidString)-\(torrent.hashString)-\(deleteData)"
    }
}

private extension UTType {
    static var torrentFile: UTType {
        UTType(filenameExtension: "torrent") ?? .data
    }
}

private extension TorrentSummary {
    func renamed(to name: String) -> TorrentSummary {
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
            fileCount: fileCount
        )
    }
}
