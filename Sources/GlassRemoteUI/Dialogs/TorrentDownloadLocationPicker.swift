import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

/// One location chooser, with paths kept in the filesystem of their owning source.
struct TorrentDownloadLocationPicker: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Binding var sourceID: UUID
    @Binding var directory: String?
    @Binding var defaultDirectory: String?
    @Binding var errorMessage: String?
    var isDisabled = false

    @State private var isEditingServer = false
    @State private var editingProfile: RemoteProfile?
    @State private var previousProfileIDs = Set<UUID>()
    @State private var isChoosingFolder = false
    @State private var isEnteringServerPath = false
    @State private var pathSourceID: UUID?
    @State private var serverPath = ""

    var body: some View {
        LabeledContent("Download to") {
            Menu {
                sourceMenu(model.localSourceID, image: model.localSourceSystemImage)
                ForEach(model.profiles) { profile in
                    sourceMenu(profile.id, image: "server.rack")
                }
                Divider()
                Button("Add Server…", systemImage: "plus") {
                    previousProfileIDs = Set(model.profiles.map(\.id))
                    editingProfile = nil
                    isEditingServer = true
                }
                if let currentDirectory {
                    Divider()
                    Button(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                           systemImage: isFavorite ? "star.slash" : "star") {
                        model.setDownloadDirectory(currentDirectory, isFavorite: !isFavorite, for: sourceID)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    NativeLocationIcon(path: nativeLocationPath, size: 22)
                    Text("\(model.sourceName(for: sourceID)) — \(locationName)")
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }
            .menuStyle(.borderedButton)
            .disabled(isDisabled || isChoosingFolder)
            .help(currentDirectory ?? "Default download folder")
            .popover(isPresented: $isEnteringServerPath) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Folder on \(model.sourceName(for: pathSourceID ?? sourceID))")
                        .font(.headline)
                    TextField("/path/to/downloads", text: $serverPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { useServerPath() }
                    HStack {
                        Spacer()
                        Button("Cancel") { isEnteringServerPath = false }
                        Button("Use Folder") { useServerPath() }
                            .disabled(!isServerPathValid)
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
        }
        .sheet(isPresented: $isEditingServer, onDismiss: {
            if let added = model.profiles.first(where: { !previousProfileIDs.contains($0.id) }) {
                select(added.id, directory: nil)
            }
        }) {
            NavigationStack {
                ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: editingProfile)
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
                Text(formatBytes(bytes))
                    .foregroundStyle(.secondary)
                    .help("Available in \(capacity.path)")
            }
        }
    }

    private func sourceMenu(_ id: UUID, image: String) -> some View {
        Menu(model.sourceName(for: id), systemImage: image) {
            Button("Default Folder", systemImage: sourceID == id && directory == nil ? "checkmark" : "folder") {
                select(id, directory: nil)
            }
            let favorites = model.favoriteDownloadDirectories(for: id)
            let recents = model.downloadDirectories(for: id).filter { !favorites.contains($0) }
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites, id: \.self) { path in locationButton(path, source: id) }
                }
            }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in locationButton(path, source: id) }
                }
            }
            Divider()
            if id == model.localSourceID {
                Button("Choose Folder…", systemImage: "folder.badge.plus") {
                    Task { await chooseMacFolder() }
                }
            } else {
                Button("Edit Server…", systemImage: "pencil") {
                    previousProfileIDs = Set(model.profiles.map(\.id))
                    editingProfile = model.profiles.first { $0.id == id }
                    isEditingServer = true
                }
                Button("Enter Server Path…", systemImage: "folder.badge.plus") {
                    pathSourceID = id
                    serverPath = sourceID == id ? (currentDirectory ?? "") : ""
                    isEnteringServerPath = true
                }
            }
        }
    }

    private func locationButton(_ path: String, source id: UUID) -> some View {
        Button(path, systemImage: sourceID == id && currentDirectory == path ? "checkmark" : "folder") {
            if id == model.localSourceID {
                Task { await prepareMacFolder(path) }
            } else { select(id, directory: path) }
        }
    }

    private var nativeLocationPath: String? {
        guard let currentDirectory else { return nil }
        if sourceID == model.localSourceID { return currentDirectory }
        guard let link = TorrentThumbnailService.shared.link(for: sourceID) else { return nil }
        return TorrentThumbnailFolderLink.directoryURL(remoteRoot: link.remoteRoot,
            localRoot: URL(fileURLWithPath: link.localPath, isDirectory: true), directory: currentDirectory)?.path
    }

    private var currentDirectory: String? { directory ?? defaultDirectory }
    private var locationName: String {
        guard let currentDirectory else { return "Default Folder" }
        let name = (currentDirectory as NSString).lastPathComponent
        return name.isEmpty ? currentDirectory : name
    }
    private var isFavorite: Bool {
        currentDirectory.map { model.favoriteDownloadDirectories(for: sourceID).contains($0) } ?? false
    }
    private var normalizedServerPath: String { serverPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isServerPathValid: Bool { normalizedServerPath.hasPrefix("/") }

    private func select(_ id: UUID, directory path: String?) {
        if sourceID != id { defaultDirectory = nil }
        sourceID = id
        directory = path
    }

    private func useServerPath() {
        guard isServerPathValid, let pathSourceID else { return }
        select(pathSourceID, directory: normalizedServerPath)
        isEnteringServerPath = false
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
