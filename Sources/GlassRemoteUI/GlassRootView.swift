import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import UniformTypeIdentifiers

public struct GlassRootView: View {
    private let model: RemoteAppModel
    private let platformIntegration: any GlassPlatformIntegrating

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("GlassRoot.inspectorPresented") private var isInspectorPresented = true
    @AppStorage("GlassRoot.selectedSourceID") private var storedSelectedSourceID = ""
    @State private var selectedTorrentID: String?
    @State private var presentation = TorrentListPresentationModel()
    @State private var openURLRegistrationID: UUID?
    @State private var pendingTorrentReveal: PendingTorrentReveal?
    @State private var torrentRevealToken = UUID()
    @State private var isFileImporterPresented = false
    @State private var activeSheet: ActiveSheet?
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
        NavigationStack {
            TorrentWorkspaceView(
                model: model,
                platformIntegration: platformIntegration,
                selection: $selectedTorrentID,
                presentation: presentation,
                torrentRevealToken: torrentRevealToken,
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
        .inspector(isPresented: $isInspectorPresented) {
            TorrentSelectionInspector(
                model: model,
                platformIntegration: platformIntegration,
                selectedID: selectedTorrentID,
                presentation: presentation
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 340)

        }
        .tint(Color.gray)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(MainWindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .newProfile:
                    ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: nil)
                case let .editProfile(profile):
                    ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: profile)
                case let .addMagnet(magnet):
                    AddMagnetView(model: model, platformIntegration: platformIntegration, magnet: magnet)
                case let .addTorrentFiles(drafts):
                    AddTorrentBatchView(
                        model: model,
                        platformIntegration: platformIntegration,
                        drafts: drafts,
                        submit: { draft, sourceID, name, downloadDirectory, fileSelection, namingPlan in
                            await submitTorrentFile(
                                draft,
                                sourceID: sourceID,
                                name: name,
                                downloadDirectory: downloadDirectory,
                                fileSelection: fileSelection,
                                namingPlan: namingPlan
                            )
                        },
                        didFinishAdding: showAddedTorrent
                    )
                case let .renameTorrent(torrent, sourceID):
                    RenameTorrentView(torrent: torrent) { newName in
                        submitRename(torrent, sourceID: sourceID, newName: newName)
                    }
                }
            }
            .toolbarVisibility(.visible, for: .windowToolbar)
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
        .onAppear {
            model.selectedTorrentGroup = .all
            persistSelectedSourceID()
            model.setApplicationActive(scenePhase == .active)
            if openURLRegistrationID == nil {
                openURLRegistrationID = GlassOpenURLRouter.shared.register { urls in
                    openURLs(urls)
                }
            }
        }
        .onDisappear {
            if let openURLRegistrationID {
                GlassOpenURLRouter.shared.unregister(openURLRegistrationID)
                self.openURLRegistrationID = nil
            }
        }
        .task(id: model.profiles) {
            await model.runAutoRefresh()
        }
        .onChange(of: model.selectedProfileID) { _, _ in
            persistSelectedSourceID()
        }
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(phase == .active)
        }
        .task(id: selectedTorrentID) {
            await loadSelectedTorrentDetails()
        }
        .focusedSceneValue(\.glassCommandActions, commandActions)
    }

    private var selectedRecord: TorrentRecord? {
        guard let selectedTorrentID else { return nil }
        return model.allTorrentRecords.first { $0.id == selectedTorrentID }
    }

    private var selectedGroup: TorrentNameSequenceGroup? {
        presentation.rows.first { $0.id == selectedTorrentID }?.selectedGroup
    }

    private var selectedTorrent: TorrentSummary? { selectedRecord?.summary }

    private var commandActions: GlassCommandActions {
        GlassCommandActions(
            addServer: { activeSheet = .newProfile },
            addMagnet: { activeSheet = .addMagnet("") },
            addTorrentFile: { isFileImporterPresented = true },
            openMagnet: { activeSheet = .addMagnet($0) },
            toggleDownloadingFilter: toggleDownloadingFilter,
            isDownloadingFilterActive: model.selectedTorrentGroup == .downloading,
            canRemoveSelectedTorrent: (selectedRecord != nil || selectedGroup != nil) && activeSheet == nil && activeAlert == nil,
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

    private func beginRename(_ torrent: TorrentSummary, sourceID: UUID) {
        activeSheet = .renameTorrent(torrent, sourceID)
    }

    private func submitRename(_ torrent: TorrentSummary, sourceID: UUID, newName proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != torrent.name else { return }

        let key = PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
        let pendingRename = PendingTorrentRename(
            key: key,
            oldName: torrent.name,
            newName: newName
        )
        withAnimation(motionAnimation(.snappy(duration: 0.22))) {
            pendingRenames[key] = pendingRename
        }

        Task {
            _ = await model.rename(torrent, to: newName, sourceID: sourceID)
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
            var drafts: [TorrentFileAddDraft] = []
            for url in torrentFileURLs {
                if let draft = await prepareTorrentFile(at: url) {
                    drafts.append(draft)
                }
            }
            if !drafts.isEmpty {
                activeSheet = .addTorrentFiles(drafts)
            }
        }
    }

    private func prepareTorrentFile(at url: URL) async -> TorrentFileAddDraft? {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            return TorrentFileAddDraft(
                data: data,
                preview: TorrentFilePreview(data: data, fallbackURL: url),
                sourceURL: url
            )
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func submitTorrentFile(
        _ draft: TorrentFileAddDraft,
        sourceID: UUID,
        name: String,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection,
        namingPlan: TorrentAddNamingPlan?
    ) async -> TorrentFileAddSubmissionResult {
        let didAccess = draft.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                draft.sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        var addedTorrent: TorrentAddResult?
        let succeeded = await model.addTorrentFile(
            draft.data,
            torrentName: name == draft.preview.name ? nil : name,
            downloadDirectory: downloadDirectory,
            fileSelection: fileSelection,
            namingPlan: namingPlan,
            sourceID: sourceID,
            sourceURL: draft.sourceURL,
            trashSourceOnSuccess: true,
            onSuccess: { addedTorrent = $0 }
        )
        return TorrentFileAddSubmissionResult(succeeded: succeeded, torrent: addedTorrent)
    }

    private func showAddedTorrent(sourceID: UUID, hashString: String?) {
        pendingTorrentReveal = PendingTorrentReveal(sourceID: sourceID, hashString: hashString)
        model.selectedTorrentGroup = .all

        model.selectedProfileID = sourceID
        Task { await refreshAndRevealPendingTorrent() }
    }

    private func refreshAndRevealPendingTorrent() async {
        guard let pendingTorrentReveal else { return }
        await model.refresh(sourceID: pendingTorrentReveal.sourceID)
        guard self.pendingTorrentReveal == pendingTorrentReveal else { return }
        if let hashString = pendingTorrentReveal.hashString {
            selectedTorrentID = TorrentRecord.identity(sourceID: pendingTorrentReveal.sourceID, hashString: hashString)
            torrentRevealToken = UUID()
        }
        self.pendingTorrentReveal = nil
    }

    private func loadSelectedTorrentDetails() async {
        guard let selectedTorrentID else {
            await model.loadDetails(for: nil)
            return
        }
        if let record = model.allTorrentRecords.first(where: { $0.id == selectedTorrentID }) {
            await model.loadDetails(for: record.summary, sourceID: record.sourceID)
            return
        }
        guard let row = presentation.rows.first(where: { $0.id == selectedTorrentID }) else {
            await model.loadDetails(for: nil)
            return
        }
        await model.loadDetails(for: row.torrentRecord?.summary, sourceID: row.sourceID)
    }

    private func removeSelectedTorrent(deleteData: Bool) {
        if let record = selectedRecord {
            scheduleRemoval(record.summary, sourceID: record.sourceID, deleteData: deleteData)
        } else if let row = presentation.rows.first(where: { $0.id == selectedTorrentID }),
                  case let .group(records, _, _) = row.kind {
            selectedTorrentID = nil
            for record in records { scheduleRemoval(record.summary, sourceID: record.sourceID, deleteData: deleteData) }
        }
    }

    private func scheduleRemoval(_ torrent: TorrentSummary, sourceID: UUID, deleteData: Bool) {
        let key = PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            pendingRemovals.removeAll { $0.key == key }
            pendingRemovals.append(PendingTorrentRemoval(sourceID: sourceID, torrent: torrent, deleteData: deleteData))
            pendingRemovalResetToken = UUID()
        }
        if selectedTorrentID == TorrentRecord.identity(sourceID: sourceID, hashString: torrent.hashString) {
            selectedTorrentID = nil
        }
        pendingRemovalTask?.cancel()
        pendingRemovalTask = Task {
            do { try await Task.sleep(for: .seconds(pendingRemovalDuration)) }
            catch { return }
            commitPendingRemovals()
        }
    }

    private var pendingRemovalDuration: TimeInterval {
        12
    }

    private func cancelPendingRemovals() {
        let restoredSelection = pendingRemovals.last.map {
            TorrentRecord.identity(sourceID: $0.sourceID, hashString: $0.torrent.hashString)
        }

        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            pendingRemovals = []
            if selectedTorrentID == nil {
                selectedTorrentID = restoredSelection
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
    let presentation: TorrentListPresentationModel
    let torrentRevealToken: UUID
    let pendingRenames: [PendingRemovalKey: PendingTorrentRename]
    let pendingRemovals: [PendingTorrentRemoval]
    let committingRemovalKeys: Set<PendingRemovalKey>
    let pendingRemovalResetToken: UUID
    let pendingRemovalDuration: TimeInterval
    let rename: (TorrentSummary, UUID) -> Void
    let remove: (TorrentSummary, UUID, Bool) -> Void
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
            presentation: presentation,
            torrentRevealToken: torrentRevealToken,
            pendingRenames: pendingRenames,
            pendingRemovals: pendingRemovals,
            committingRemovalKeys: committingRemovalKeys,
            rename: rename,
            remove: remove,
            removeSelected: removeSelected
        )
        .frame(minWidth: 360, idealWidth: 480)
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
    let presentation: TorrentListPresentationModel
    let torrentRevealToken: UUID
    let pendingRenames: [PendingRemovalKey: PendingTorrentRename]
    let pendingRemovals: [PendingTorrentRemoval]
    let committingRemovalKeys: Set<PendingRemovalKey>
    let rename: (TorrentSummary, UUID) -> Void
    let remove: (TorrentSummary, UUID, Bool) -> Void
    let removeSelected: (Bool) -> Void

    var body: some View {
        TorrentListView(
            model: model,
            platformIntegration: platformIntegration,
            records: visibleRecords,
            structureRevision: model.libraryStructureRevision,
            pendingRenameNames: pendingRenameNames,
            pendingRenameOldNames: pendingRenameOldNames,
            selection: $selection,
            presentation: presentation,
            revealSelectionToken: torrentRevealToken,
            rename: rename,
            remove: remove,
            removeSelected: removeSelected
        )
    }

    private var visibleRecords: [TorrentRecord] {
        let hiddenKeys = Set(pendingRemovals.map(\.key)).union(committingRemovalKeys)
        let available = model.allTorrentRecords.filter { record in
            !hiddenKeys.contains(PendingRemovalKey(sourceID: record.sourceID, hashString: record.hashString))
        }
        return TorrentLibraryFilter.records(available, group: model.selectedTorrentGroup, pendingRenameNames: pendingRenameNames)
    }

    private var pendingRenameNames: [String: String] {
        Dictionary(uniqueKeysWithValues: pendingRenames.values.compactMap { pendingRename in
            return (TorrentRecord.identity(sourceID: pendingRename.key.sourceID, hashString: pendingRename.key.hashString), pendingRename.newName)
        })
    }

    private var pendingRenameOldNames: [String: String] {
        Dictionary(uniqueKeysWithValues: pendingRenames.values.compactMap { pendingRename in
            return (TorrentRecord.identity(sourceID: pendingRename.key.sourceID, hashString: pendingRename.key.hashString), pendingRename.oldName)
        })
    }
}

private struct TorrentSelectionInspector: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let selectedID: String?
    let presentation: TorrentListPresentationModel

    var body: some View {
        let row = presentation.rows.first { $0.id == selectedID }
        TorrentInspectorView(
            model: model,
            platformIntegration: platformIntegration,
            sourceID: row?.sourceID ?? model.selectedSourceID,
            selectedTorrentHash: row?.torrentRecord?.hashString ?? row?.id,
            selectedTorrentGroup: row?.selectedGroup
        )
    }
}

private enum ActiveSheet: Identifiable {
    case newProfile
    case editProfile(RemoteProfile)
    case addMagnet(String)
    case addTorrentFiles([TorrentFileAddDraft])
    case renameTorrent(TorrentSummary, UUID)

    var id: String {
        switch self {
        case .newProfile:
            return "new-profile"
        case let .editProfile(profile):
            return "edit-profile-\(profile.id.uuidString)"
        case let .addMagnet(magnet):
            return "add-magnet-\(magnet)"
        case let .addTorrentFiles(drafts):
            return "add-torrent-files-\(drafts.map(\.id.uuidString).joined(separator: "-"))"
        case let .renameTorrent(torrent, sourceID):
            return "rename-torrent-\(sourceID.uuidString)-\(torrent.hashString)"
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

private struct PendingTorrentReveal: Equatable {
    let sourceID: UUID
    let hashString: String?
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
