import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import UniformTypeIdentifiers

public struct GlassRootView: View {
    private let model: RemoteAppModel

    @SceneStorage("GlassRoot.columnVisibility") private var storedColumnVisibility = "automatic"
    @AppStorage("GlassRoot.selectedSourceID") private var storedSelectedSourceID = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var didRestoreColumnVisibility = false
    @State private var isInspectorPresented = true
    @State private var selectedTorrentHash: String?
    @State private var isFileImporterPresented = false
    @State private var activeSheet: ActiveSheet?
    @State private var pendingProfileDeletion: RemoteProfile?
    @State private var renamingTorrent: TorrentSummary?
    @State private var renameDraft = ""
    @State private var pendingRenames: [PendingRemovalKey: PendingTorrentRename] = [:]
    @State private var pendingRemovals: [PendingTorrentRemoval] = []
    @State private var pendingRemovalResetToken = UUID()
    @State private var committingRemovalKeys = Set<PendingRemovalKey>()
    @State private var pendingRemovalTask: Task<Void, Never>?

    public init(model: RemoteAppModel) {
        self.model = model
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
                selection: $selectedTorrentHash,
                isInspectorPresented: $isInspectorPresented,
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
            .inspector(isPresented: $isInspectorPresented) {
                TorrentInspectorView(model: model, selectedTorrentHash: selectedTorrentHash)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .newProfile:
                    ProfileEditorView(model: model, profile: nil)
                case let .editProfile(profile):
                    ProfileEditorView(model: model, profile: profile)
                case let .addMagnet(magnet):
                    AddMagnetView(model: model, magnet: magnet)
                }
            }
            .presentationSizing(.form)
        }
        .alert(activeAlertTitle, isPresented: activeAlertBinding, presenting: activeAlert) { alert in
            switch alert {
            case let .rename(torrent):
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    submitRename(torrent)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRename(torrent))
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
            case .rename:
                EmptyView()
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
            if case let .success(urls) = result {
                openURLs(urls)
            }
        }
        .task {
            restoreColumnVisibilityIfNeeded()
            persistSelectedSourceID()
            await MainActor.run {
                GlassOpenURLRouter.shared.register { urls in
                    openURLs(urls)
                }
            }
            await model.runAutoRefresh()
        }
        .onChange(of: model.selectedProfileID) { _, _ in
            persistSelectedSourceID()
            selectedTorrentHash = nil
            Task { await model.refresh() }
        }
        .onChange(of: columnVisibility) { _, visibility in
            storedColumnVisibility = key(for: visibility)
        }
        .onChange(of: selectedTorrentHash) { _, _ in
            Task { await loadSelectedTorrentDetails() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandAddServer)) { _ in
            activeSheet = .newProfile
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandAddMagnet)) { _ in
            activeSheet = .addMagnet("")
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandAddTorrentFile)) { _ in
            isFileImporterPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandToggleDownloadingFilter)) { _ in
            toggleDownloadingFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandRemoveSelectedTorrent)) { _ in
            removeSelectedTorrent(deleteData: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandRemoveSelectedTorrentAndData)) { _ in
            removeSelectedTorrent(deleteData: true)
        }
    }

    private var selectedTorrent: TorrentSummary? {
        guard let selectedTorrentHash else { return nil }
        return model.filteredTorrents.first { $0.hashString == selectedTorrentHash }
    }

    private var activeAlertBinding: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { dismissActiveAlert() } }
        )
    }

    private var activeAlert: ActiveRootAlert? {
        if let renamingTorrent {
            return .rename(renamingTorrent)
        }
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
        case .rename:
            return "Rename"
        case .deleteProfile:
            return "Delete Server?"
        case .error, nil:
            return "Glass"
        }
    }

    private func dismissActiveAlert() {
        switch activeAlert {
        case .rename:
            renamingTorrent = nil
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

    private func beginRename(_ torrent: TorrentSummary) {
        renameDraft = torrent.name
        renamingTorrent = torrent
    }

    private func canRename(_ torrent: TorrentSummary) -> Bool {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != torrent.name
    }

    private func submitRename(_ torrent: TorrentSummary) {
        let newName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != torrent.name else { return }

        let key = PendingRemovalKey(sourceID: model.selectedSourceID, hashString: torrent.hashString)
        let pendingRename = PendingTorrentRename(
            key: key,
            oldName: torrent.name,
            newName: newName
        )
        withAnimation(.snappy(duration: 0.22)) {
            pendingRenames[key] = pendingRename
        }

        Task {
            _ = await model.rename(torrent, to: newName)
            await MainActor.run {
                guard pendingRenames[key]?.id == pendingRename.id else { return }
                withAnimation(.snappy(duration: 0.22)) {
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
        for url in urls {
            if let magnet = magnetLink(from: url) {
                activeSheet = .addMagnet(magnet)
                continue
            }
            guard url.pathExtension.lowercased() == "torrent" else { continue }
            Task {
                await addTorrentFile(at: url)
            }
        }
    }

    private func addTorrentFile(at url: URL) async {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            _ = TorrentFilePreview(data: data, fallbackURL: url)
            await model.addTorrentFile(
                data,
                downloadDirectory: nil,
                sourceURL: url,
                trashSourceOnSuccess: true
            )
        } catch {
            model.errorMessage = error.localizedDescription
        }
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
        withAnimation(.snappy(duration: 0.28)) {
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
        withAnimation(.snappy(duration: 0.28)) {
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
        withAnimation(.snappy(duration: 0.28)) {
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
}

private struct TorrentWorkspaceView: View {
    let model: RemoteAppModel
    @Binding var selection: String?
    @Binding var isInspectorPresented: Bool
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
        TorrentListView(
            model: model,
            torrents: visibleTorrents,
            pendingRenameOldNames: pendingRenameOldNames,
            selection: $selection,
            rename: rename,
            remove: remove,
            removeSelected: removeSelected
        )
        .navigationTitle(model.selectedSourceName)
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    toggleDownloadingFilter()
                } label: {
                    Label("Show Downloading Torrents", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show Downloading Torrents")

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Inspector")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            openURLs(urls)
            return true
        }
        .dropDestination(for: String.self) { strings, _ in
            for string in strings {
                if let magnet = normalizedMagnetLink(from: string) {
                    openMagnet(magnet)
                    return true
                }
            }
            return false
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: pendingRemovals)
    }

    private var visibleTorrents: [TorrentSummary] {
        let sourceID = model.selectedSourceID
        let hiddenKeys = Set(pendingRemovals.map(\.key)).union(committingRemovalKeys)
        return model.filteredTorrents
            .filter { torrent in
                !hiddenKeys.contains(PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString))
            }
            .map { torrent in
                let key = PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
                guard let pendingRename = pendingRenames[key] else { return torrent }
                return torrent.renamed(to: pendingRename.newName)
            }
    }

    private var pendingRenameOldNames: [String: String] {
        let sourceID = model.selectedSourceID
        return Dictionary(uniqueKeysWithValues: pendingRenames.values.compactMap { pendingRename in
            guard pendingRename.key.sourceID == sourceID else { return nil }
            return (pendingRename.key.hashString, pendingRename.oldName)
        })
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

    private func toggleDownloadingFilter() {
        model.selectedTorrentGroup = model.selectedTorrentGroup == .downloading ? .all : .downloading
    }
}

private enum ActiveSheet: Identifiable {
    case newProfile
    case editProfile(RemoteProfile)
    case addMagnet(String)

    var id: String {
        switch self {
        case .newProfile:
            return "new-profile"
        case let .editProfile(profile):
            return "edit-profile-\(profile.id.uuidString)"
        case let .addMagnet(magnet):
            return "add-magnet-\(magnet)"
        }
    }
}

private enum ActiveRootAlert {
    case rename(TorrentSummary)
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
            queuePosition: queuePosition
        )
    }
}
