import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import UniformTypeIdentifiers

public struct GlassRootView: View {
    @ObservedObject private var model: RemoteAppModel

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var selectedTorrentHash: String?
    @State private var isInspectorPresented = true
    @State private var isFileImporterPresented = false
    @State private var activeSheet: ActiveSheet?
    @State private var pendingProfileDeletion: RemoteProfile?
    @State private var pendingRemoval: PendingRemoval?
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        activeSheet = .newProfile
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                    .help("Add Server")
                }
            }
        } detail: {
            detail
                .inspector(isPresented: $isInspectorPresented) {
                    TorrentInspectorView(model: model, selectedTorrent: selectedTorrent)
                }
        }
        .navigationTitle(model.selectedSourceProfile?.name ?? "Glass")
        .navigationSubtitle(navigationSubtitle)
        .toolbar(id: "glass.main") {
            ToolbarItem(id: "refresh", placement: .primaryAction, showsByDefault: true) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
            ToolbarItem(id: "add-magnet", placement: .primaryAction, showsByDefault: true) {
                Button {
                    activeSheet = .addMagnet("")
                } label: {
                    Label("Add Magnet", systemImage: "link.badge.plus")
                }
                .disabled(model.selectedSourceProfile == nil)
                .help("Add Magnet")
            }
            ToolbarItem(id: "add-torrent", placement: .primaryAction, showsByDefault: true) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Add Torrent File", systemImage: "doc.badge.plus")
                }
                .disabled(model.selectedSourceProfile == nil)
                .help("Add Torrent File")
            }
            ToolbarItem(id: "filter-downloading", placement: .primaryAction, showsByDefault: true) {
                Button {
                    toggleDownloadingFilter()
                } label: {
                    Label("Show Downloading Torrents", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show Downloading Torrents")
            }
            ToolbarItem(id: "inspector", placement: .primaryAction, showsByDefault: true) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Inspector")
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
                case let .renameTorrent(torrent):
                    RenameTorrentView(model: model, torrent: torrent)
                }
            }
        }
        .alert("Delete Server?", isPresented: deleteProfileAlertBinding, presenting: pendingProfileDeletion) { profile in
            Button("Delete", role: .destructive) {
                model.deleteProfile(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Remove \(profile.name) from Glass. Transmission data on the server is not changed.")
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
        .onAppear {
            Task { await model.refresh() }
        }
        .onChange(of: model.selectedProfileID) { _, _ in
            selectedTorrentHash = nil
            Task { await model.refresh() }
        }
        .onChange(of: selectedTorrentHash) { _, _ in
            Task { await model.loadDetails(for: selectedTorrent) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandAddMagnet)) { _ in
            activeSheet = .addMagnet("")
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandAddTorrentFile)) { _ in
            isFileImporterPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandRefresh)) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassCommandToggleDownloadingFilter)) { _ in
            toggleDownloadingFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .glassOpenURLs)) { notification in
            guard let urls = notification.object as? [URL] else { return }
            openURLs(urls)
        }
    }

    private var detail: some View {
        ZStack(alignment: .bottom) {
            TorrentListView(
                model: model,
                selection: $selectedTorrentHash,
                rename: { activeSheet = .renameTorrent($0) },
                remove: scheduleRemoval
            )
            .dropDestination(for: URL.self) { urls, _ in
                openURLs(urls)
                return true
            }
            .dropDestination(for: String.self) { strings, _ in
                for string in strings {
                    if let magnet = normalizedMagnetLink(from: string) {
                        activeSheet = .addMagnet(magnet)
                        return true
                    }
                }
                return false
            }

            if let pendingRemoval {
                RemovalUndoToast(
                    title: pendingRemoval.deleteData ? "Delete \(pendingRemoval.torrent.name)" : "Remove \(pendingRemoval.torrent.name)",
                    deleteData: pendingRemoval.deleteData
                ) {
                    pendingRemovalTask?.cancel()
                    pendingRemovalTask = nil
                    self.pendingRemoval = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: pendingRemoval?.id)
    }

    private var selectedTorrent: TorrentSummary? {
        guard let selectedTorrentHash else { return nil }
        return model.torrents.first { $0.hashString == selectedTorrentHash }
    }

    private var navigationSubtitle: String {
        guard let profile = model.selectedSourceProfile else {
            return "Select a Transmission server"
        }
        if let freeSpace = model.serverFreeSpace[profile.id]?.availableBytes {
            return "\(formatBytes(freeSpace)) free"
        }
        return profile.rpcURL.host(percentEncoded: false) ?? profile.rpcURL.absoluteString
    }

    private var deleteProfileAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingProfileDeletion != nil },
            set: { if !$0 { pendingProfileDeletion = nil } }
        )
    }

    private func toggleDownloadingFilter() {
        model.selectedTorrentGroup = model.selectedTorrentGroup == .downloading ? .all : .downloading
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

    private func scheduleRemoval(_ torrent: TorrentSummary, deleteData: Bool) {
        pendingRemovalTask?.cancel()
        pendingRemoval = PendingRemoval(torrent: torrent, deleteData: deleteData)
        pendingRemovalTask = Task {
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            await model.remove(torrent, deleteData: deleteData)
            await MainActor.run {
                pendingRemoval = nil
                pendingRemovalTask = nil
            }
        }
    }
}

private enum ActiveSheet: Identifiable {
    case newProfile
    case editProfile(RemoteProfile)
    case addMagnet(String)
    case renameTorrent(TorrentSummary)

    var id: String {
        switch self {
        case .newProfile:
            return "new-profile"
        case let .editProfile(profile):
            return "edit-profile-\(profile.id.uuidString)"
        case let .addMagnet(magnet):
            return "add-magnet-\(magnet)"
        case let .renameTorrent(torrent):
            return "rename-\(torrent.hashString)"
        }
    }
}

private struct PendingRemoval: Identifiable, Equatable {
    let id = UUID()
    let torrent: TorrentSummary
    let deleteData: Bool
}

private extension UTType {
    static var torrentFile: UTType {
        UTType(filenameExtension: "torrent") ?? .data
    }
}
