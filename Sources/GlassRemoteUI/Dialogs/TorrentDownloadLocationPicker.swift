import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

/// Local folders are choices. A share uses its server's configured download folder.
struct TorrentDownloadLocationPicker: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Binding var sourceID: UUID
    @Binding var directory: String?
    @Binding var defaultDirectory: String?
    @Binding var errorMessage: String?
    var isDisabled = false

    @State private var isEditingServer = false
    @State private var previousProfileIDs = Set<UUID>()
    @State private var isChoosingFolder = false

    var body: some View {
        LabeledContent("Download to") {
            Menu {
                Section("On This Mac") {
                    Button("Default Folder", systemImage: sourceID == model.localSourceID && directory == nil ? "checkmark" : "folder") {
                        select(model.localSourceID, directory: nil)
                    }
                    let favorites = model.favoriteDownloadDirectories(for: model.localSourceID)
                    let recents = model.downloadDirectories(for: model.localSourceID).filter { !favorites.contains($0) }
                    if !favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(favorites, id: \.self) { path in locationButton(path) }
                        }
                    }
                    if !recents.isEmpty {
                        Section("Recent Folders") {
                            ForEach(recents, id: \.self) { path in locationButton(path) }
                        }
                    }
                    ForEach(standardFolders.filter { !favorites.contains($0) && !recents.contains($0) }, id: \.self) { path in
                        locationButton(path)
                    }
                    Button("Choose Folder…", systemImage: "folder.badge.plus") {
                        Task { await chooseMacFolder() }
                    }
                }
                if !model.profiles.isEmpty {
                    Section("Shares") {
                        ForEach(model.profiles) { profile in
                            Button(shareName(for: profile.id), systemImage: sourceID == profile.id ? "checkmark" : "externaldrive.connected.to.line.below") {
                                select(profile.id, directory: nil)
                            }
                            .help("Use the download folder configured by Transmission on \(profile.name)")
                        }
                    }
                }
                Divider()
                if sourceID == model.localSourceID, let currentDirectory {
                    Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
                        model.setDownloadDirectory(currentDirectory, isFavorite: !isFavorite, for: model.localSourceID)
                    }
                }
                Button("Add Server…", systemImage: "plus") {
                    previousProfileIDs = Set(model.profiles.map(\.id))
                    isEditingServer = true
                }
            } label: {
                HStack(spacing: 8) {
                    NativeLocationIcon(path: nativeLocationPath, sourceID: sourceID == model.localSourceID ? nil : sourceID, serverName: model.sourceName(for: sourceID), size: 22)
                    Text(locationName).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }
            .menuStyle(.borderedButton)
            .disabled(isDisabled || isChoosingFolder)
            .help(sourceID == model.localSourceID ? (currentDirectory ?? "Default download folder on this Mac") : "Transmission chooses the folder on \(model.sourceName(for: sourceID))")
        }
        .sheet(isPresented: $isEditingServer, onDismiss: {
            if let added = model.profiles.first(where: { !previousProfileIDs.contains($0.id) }) {
                select(added.id, directory: nil)
            }
        }) {
            NavigationStack {
                ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: nil)
            }
            .toolbarVisibility(.visible, for: .windowToolbar)
        }
        .task(id: sourceID) {
            let requestedSourceID = sourceID
            defaultDirectory = nil
            let path = await model.defaultDownloadDirectory(for: requestedSourceID)
            guard !Task.isCancelled, requestedSourceID == sourceID else { return }
            defaultDirectory = path
        }
        if let capacity = model.serverFreeSpace[sourceID], let bytes = capacity.availableBytes {
            LabeledContent("Free space") {
                Text(formatBytes(bytes)).foregroundStyle(.secondary)
                    .help("Available in \(capacity.path)")
            }
        }
    }

    private var standardFolders: [String] {
        [FileManager.SearchPathDirectory.moviesDirectory, .downloadsDirectory].compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first?.path
        }
    }

    private func locationButton(_ path: String) -> some View {
        Button(URL(fileURLWithPath: path).lastPathComponent,
            systemImage: sourceID == model.localSourceID && currentDirectory == path ? "checkmark" : "folder") {
            Task { await prepareMacFolder(path) }
        }
        .help(path)
    }

    private func shareName(for id: UUID) -> String {
        TorrentDownloadLocation.shareName(link: TorrentThumbnailService.shared.link(for: id), fallback: model.sourceName(for: id))
    }

    private var currentDirectory: String? { directory ?? defaultDirectory }
    private var locationName: String {
        if sourceID != model.localSourceID { return shareName(for: sourceID) }
        guard let currentDirectory else { return "Default Folder" }
        return URL(fileURLWithPath: currentDirectory).lastPathComponent
    }
    private var nativeLocationPath: String? {
        guard let currentDirectory else { return nil }
        if sourceID == model.localSourceID { return currentDirectory }
        guard let link = TorrentThumbnailService.shared.link(for: sourceID) else { return nil }
        return TorrentThumbnailFolderLink.directoryURL(remoteRoot: link.remoteRoot,
            localRoot: URL(fileURLWithPath: link.localPath, isDirectory: true), directory: currentDirectory)?.path
    }
    private var isFavorite: Bool {
        currentDirectory.map { model.favoriteDownloadDirectories(for: model.localSourceID).contains($0) } ?? false
    }

    private func select(_ id: UUID, directory path: String?) {
        if sourceID != id { defaultDirectory = nil }
        sourceID = id
        directory = path
    }

    private func prepareMacFolder(_ path: String) async {
        isChoosingFolder = true
        defer { isChoosingFolder = false }
        do {
            if let authorized = try await platformIntegration.prepareLocalDownloadDirectory(path) {
                select(model.localSourceID, directory: authorized)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseMacFolder() async {
        isChoosingFolder = true
        defer { isChoosingFolder = false }
        do {
            if let path = try await platformIntegration.chooseLocalDownloadDirectory(
                startingAt: sourceID == model.localSourceID ? currentDirectory : nil
            ) {
                select(model.localSourceID, directory: path)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
